# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
FROM ghcr.io/linuxserver/baseimage-alpine:3.22

LABEL org.opencontainers.image.source=https://github.com/kylhill/docker-nginx
LABEL org.opencontainers.image.description="linuxserver.io Nginx (without PHP) inside Docker"
LABEL org.opencontainers.image.licenses=GPL-3.0-or-later

# install packages
RUN \
  echo "**** install build packages ****" && \
  apk add --no-cache \
    apache2-utils \
    git \
    logrotate \
    nginx \
    nginx-mod-http-dav-ext \
    nginx-mod-http-fancyindex \
    nginx-mod-http-geoip2 \
    openssl && \
  echo "**** configure nginx ****" && \
  rm -f /etc/nginx/http.d/default.conf && \
  echo "**** fix logrotate ****" && \
  sed -i "s#/var/log/messages {}.*# #g" \
    /etc/logrotate.conf && \
  sed -i 's#/usr/sbin/logrotate /etc/logrotate.conf#/usr/sbin/logrotate /etc/logrotate.conf -s /config/log/logrotate.status#g' \
    /etc/periodic/daily/logrotate

# copy local files
COPY root/ /

# ports and volumes
EXPOSE 80 443
VOLUME /config

# healthcheck
HEALTHCHECK CMD curl --fail http://localhost:80
