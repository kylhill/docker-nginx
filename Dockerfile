# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
FROM ghcr.io/linuxserver/baseimage-alpine:3.22

LABEL org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx"

# install packages
RUN set -eux; \
  apk update; \
  apk add --no-cache --no-progress \
    logrotate \
    nginx \
    nginx-mod-http-brotli \
    nginx-mod-http-dav-ext \
    nginx-mod-http-fancyindex \
    nginx-mod-http-geoip2 \
    nginx-mod-http-zstd; \
  # Remove default config
  rm -f /etc/nginx/http.d/default.conf; \
  # Fix logrotate
  sed -i "s#/var/log/messages {}.*# #g" \
    /etc/logrotate.conf; \
  sed -i 's#/usr/sbin/logrotate /etc/logrotate.conf#/usr/sbin/logrotate /etc/logrotate.conf -s /config/log/logrotate.status#g' \
    /etc/periodic/daily/logrotate

# copy local files
COPY root/ /

# ports and volumes
EXPOSE 80 443
VOLUME /config

# healthcheck
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -q --spider http://localhost:80 || exit 1
