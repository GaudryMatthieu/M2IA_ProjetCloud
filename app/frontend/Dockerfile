FROM nginx/nginx-unprivileged:1.30-alpine3.24
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html app.js style.css /usr/share/nginx/html/
EXPOSE 8080