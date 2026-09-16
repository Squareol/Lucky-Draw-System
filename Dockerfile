# Serves the Lucky Draw static frontend (index.html, admin.html, assets/,
# sql/, config.js, etc.) on Railway. Railway has no one-click "static site"
# host like Vercel, so this wraps the files in a tiny nginx container.
#
# Put this Dockerfile and nginx.conf.template in the ROOT of your
# Lucky-Draw-System repo (next to index.html), then deploy that repo on
# Railway as a normal Docker service. Nothing else to configure — Railway
# sets $PORT automatically and nginx's official image substitutes it in.

FROM nginx:alpine

RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY . /usr/share/nginx/html

ENV PORT=8080
EXPOSE 8080
