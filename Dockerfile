# Simple Dockerfile to add nginx-mod-http-dav-ext and nginx-mod-http-fancyindex to alpine nginx
# Inspired by https://github.com/nginxinc/docker-nginx/blob/master/stable/alpine/Dockerfile
FROM docker.io/alpine:latest

RUN \
  echo "**** configure user ****" && \
  addgroup -g 101 -S nginx && \
  adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx && \
  echo "**** install runtime packages ****" && \
  apk add --no-cache \
    bash \
    tzdata \
    nginx \
    nginx-mod-http-set-misc \
    nginx-mod-http-dav-ext \
    nginx-mod-http-fancyindex

EXPOSE 80
EXPOSE 443

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
