FROM nginx:1.28.0-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

# Only the public site files, copied explicitly. Never COPY . here.
COPY index.html index-sv.html index-de.html index-fr.html dotnet-modernization.html /usr/share/nginx/html/
COPY llms.txt robots.txt sitemap.xml /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
