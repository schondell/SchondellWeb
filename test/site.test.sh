#!/usr/bin/env bash
# Builds the site image, runs it on 127.0.0.1:18089 and verifies what is (and is not) served.
set -euo pipefail

cd "$(dirname "$0")/.."
BASE="http://127.0.0.1:18089"
COMPOSE=(docker compose -f docker-compose.test.yml -p schondell-web-test)
PASSED=0
TMP="$(mktemp -d)"

cleanup() {
  "${COMPOSE[@]}" down --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { PASSED=$((PASSED + 1)); }

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

expect_status() { # expected path [extra curl args...]
  local expected="$1" path="$2"; shift 2
  local actual
  actual="$(status "$@" "$BASE$path")"
  [ "$actual" = "$expected" ] || fail "GET $path expected HTTP $expected but got $actual"
  pass
}

echo "Building and starting test container..."
"${COMPOSE[@]}" up -d --build

for _ in $(seq 1 30); do
  [ "$(status "$BASE/healthz" || true)" = "200" ] && break
  sleep 1
done
[ "$(status "$BASE/healthz")" = "200" ] || fail "container did not become healthy on $BASE/healthz"

# 1. Every tracked site file is served and identical to the committed content.
# The comparison source is `git show HEAD:<path>` (LF), not the working tree, because the Windows
# checkout may have CRLF. Text files are compared with CR removed on both sides (the image is built
# from the working tree); binary files (png) are compared byte for byte.
is_infra() {
  case "$1" in
    .gitignore|.dockerignore|Dockerfile|docker-compose*.yml|nginx.conf|README.md|test/*) return 0 ;;
    *) return 1 ;;
  esac
}
while IFS= read -r f; do
  is_infra "$f" && continue
  url_path="/$f"
  [ "$f" = "index.html" ] && url_path="/" # the home page lives at /; /index.html redirects (section 8)
  curl -s -o "$TMP/served" -w '%{http_code}' "$BASE$url_path" > "$TMP/code"
  [ "$(cat "$TMP/code")" = "200" ] || fail "tracked site file /$f expected HTTP 200 but got $(cat "$TMP/code")"
  git show "HEAD:$f" > "$TMP/expected"
  case "$f" in
    *.html|*.txt|*.xml)
      tr -d '\r' < "$TMP/expected" > "$TMP/expected.n"
      tr -d '\r' < "$TMP/served" > "$TMP/served.n"
      cmp -s "$TMP/expected.n" "$TMP/served.n" || fail "/$f differs from HEAD:$f" ;;
    *)
      cmp -s "$TMP/expected" "$TMP/served" || fail "/$f differs from HEAD:$f" ;;
  esac
  pass
done < <(git ls-files)

# 2. Every sitemap URL resolves.
locs="$(grep -o '<loc>[^<]*</loc>' sitemap.xml | sed -e 's#<loc>##' -e 's#</loc>##')"
[ -n "$locs" ] || fail "no <loc> entries found in sitemap.xml"
while IFS= read -r url; do
  path="${url#https://schondell.com}"
  [ "$path" != "$url" ] || fail "sitemap URL $url does not start with https://schondell.com"
  expect_status 200 "$path"
done <<< "$locs"

# 3. Things that must never be served.
expect_status 404 /marketing/
if [ -d marketing ]; then
  m="$(ls marketing | head -n 1)"
  [ -n "$m" ] && expect_status 404 "/marketing/$m"
fi
for p in /schondell-site.zip /Dockerfile /docker-compose.yml /nginx.conf /.git/config /README.md /test/site.test.sh /.dockerignore; do
  expect_status 404 "$p"
done

# 4. www redirects to the apex, preserving path and query.
headers="$(curl -s -o /dev/null -D - -H 'Host: www.schondell.com' "$BASE/index-sv.html?x=1")"
echo "$headers" | head -n 1 | grep -q ' 301 ' || fail "www host did not return 301: $(echo "$headers" | head -n 1)"
echo "$headers" | tr -d '\r' | grep -qi '^location: https://schondell.com/index-sv.html?x=1$' \
  || fail "www redirect Location wrong: $(echo "$headers" | grep -i '^location' || echo none)"
pass

# 4b. http->https redirect, driven by the X-Forwarded-Proto header set by the Cloudflare Tunnel.
headers="$(curl -s -o /dev/null -D - -H 'X-Forwarded-Proto: http' "$BASE/index-sv.html?x=1")"
echo "$headers" | head -n 1 | grep -q ' 301 ' || fail "X-Forwarded-Proto http did not return 301: $(echo "$headers" | head -n 1)"
echo "$headers" | tr -d '' | grep -qi '^location: https://schondell.com/index-sv.html?x=1$'   || fail "http->https Location wrong: $(echo "$headers" | grep -i '^location' || echo none)"
pass
expect_status 301 /index-sv.html -H 'X-Forwarded-Proto: http'
expect_status 200 /healthz -H 'X-Forwarded-Proto: http'
expect_status 200 / -H 'X-Forwarded-Proto: https'
expect_status 404 /no-such-page -H 'X-Forwarded-Proto: https'
expect_status 200 / # no header: direct in-network request, served as is
headers="$(curl -s -o /dev/null -D - -H 'Host: www.schondell.com' -H 'X-Forwarded-Proto: http' "$BASE/index-sv.html?x=1")"
echo "$headers" | head -n 1 | grep -q ' 301 ' || fail "www with X-Forwarded-Proto http did not return 301: $(echo "$headers" | head -n 1)"
echo "$headers" | tr -d '' | grep -qi '^location: https://schondell.com/index-sv.html?x=1$'   || fail "www http Location wrong (must be a single hop to the apex): $(echo "$headers" | grep -i '^location' || echo none)"
pass

# 5. Unknown path is a real 404 (no SPA rewrite).
expect_status 404 /no-such-page

# 6. No nginx version leaks.
server="$(curl -s -o /dev/null -D - "$BASE/" | tr -d '\r' | grep -i '^server:' || true)"
echo "$server" | grep -q '[0-9]' && fail "Server header leaks a version: $server"
pass

# 7. Cache headers.
curl -s -o /dev/null -D - "$BASE/" | tr -d '\r' | grep -qi '^cache-control:.*no-cache' || fail "html lacks Cache-Control: no-cache"
pass

# 8. The home page has one URL: /index.html redirects to / in a single hop (Search Console reported
# /index.html as an alternate page), and no page links to index.html.
expect_redirect() { # description location [curl args...] url
  local what="$1" expected="$2"; shift 2
  local headers
  headers="$(curl -s -o /dev/null -D - "$@" | tr -d '\r')"
  echo "$headers" | head -n 1 | grep -q ' 301 ' || fail "$what did not return 301: $(echo "$headers" | head -n 1)"
  echo "$headers" | grep -qix "location: $expected" \
    || fail "$what Location wrong, expected $expected: $(echo "$headers" | grep -i '^location' || echo none)"
  pass
}
expect_redirect "/index.html" "https://schondell.com/" "$BASE/index.html"
expect_redirect "/index.html?x=1" "https://schondell.com/?x=1" "$BASE/index.html?x=1"
expect_redirect "www /index.html" "https://schondell.com/" -H 'Host: www.schondell.com' "$BASE/index.html"
expect_redirect "http /index.html" "https://schondell.com/" -H 'X-Forwarded-Proto: http' "$BASE/index.html"
expect_redirect "www http /index.html?x=1" "https://schondell.com/?x=1" -H 'Host: www.schondell.com' -H 'X-Forwarded-Proto: http' "$BASE/index.html?x=1"
expect_status 200 /index-sv.html -H 'X-Forwarded-Proto: https'
if git ls-files '*.html' | xargs grep -l 'href="\(\./\)\?index\.html' ; then
  fail "a page links to index.html instead of /"
fi
pass

echo "PASS: $PASSED checks passed"
