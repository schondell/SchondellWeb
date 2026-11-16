# SchondellWeb

Static marketing site for schondell.com (`index.html`, the `index-sv/de/fr.html` translations, `dotnet-modernization.html`, `llms.txt`, `robots.txt`, `sitemap.xml`, `assets/`). No build step.

## Hosting

The site runs as an nginx container named `schondell-web` on the Ubuntu server, attached to the existing external docker network `app_default`. A Cloudflare Tunnel container routes `schondell.com` and `www.schondell.com` to `http://schondell-web:80`. TLS and http to https are handled at Cloudflare's edge, so the container speaks plain HTTP only and publishes no host ports. `www` is redirected to the apex by nginx (301, path and query preserved).

## Update

On the server:

```
cd ~/SchondellWeb && git pull && docker compose up -d --build
```

## Test

Requires Docker and bash (Git Bash on Windows). From the repo root:

```
bash test/site.test.sh
```

It builds the image, starts it on `127.0.0.1:18089` via `docker-compose.test.yml`, checks that every tracked site file and sitemap URL is served unchanged, that non-site files are not served, the www redirect, 404 behaviour and headers, then removes the container.

## What never ships

`marketing/` (prospect and lead data) and any `*.zip` must never be in the image or in git. They are listed in `.gitignore` and excluded by `.dockerignore`, and the Dockerfile copies the site files by name. The test fails if they become reachable.

## Rollback

To go back to the previous hosting: in Cloudflare DNS re-create two proxied A records, `schondell.com` and `www`, pointing to `185.82.127.97`, and remove the two tunnel routes for `schondell.com` and `www.schondell.com`.
