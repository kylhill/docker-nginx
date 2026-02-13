# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
FROM ghcr.io/linuxserver/baseimage-alpine:3.23

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
  # Remove default /var/www content
  find /var/www -mindepth 1 ! -path /var/www/favicon.ico -exec rm -rf {} +; \
  # Fix logrotate
  sed -i "s#/var/log/messages {}.*# #g" \
    /etc/logrotate.conf; \
  sed -i 's#/usr/sbin/logrotate /etc/logrotate.conf#/usr/sbin/logrotate /etc/logrotate.conf -s /config/log/logrotate.status#g' \
    /etc/periodic/daily/logrotate

# install latest geoipupdate release from GitHub
RUN set -eux; \
    apk add --no-cache --virtual .build-deps curl jq tar ca-certificates; \
    \
    # detect architecture for GitHub release
    ARCH="$(apk --print-arch)"; \
    case "$ARCH" in \
      x86_64) ARCH="amd64";; \
      aarch64) ARCH="arm64";; \
      *) echo "Unsupported arch $ARCH"; exit 1;; \
    esac; \
    \
    # get latest release tag from GitHub API
    GEOIPUPDATE_LATEST="$(curl -s https://api.github.com/repos/maxmind/geoipupdate/releases/latest | jq -r .tag_name)"; \
    echo "Latest GeoIPUpdate release: $GEOIPUPDATE_LATEST"; \
    \
    # download tar.gz for the architecture
    curl -L -o /tmp/geoipupdate.tar.gz \
      "https://github.com/maxmind/geoipupdate/releases/download/${GEOIPUPDATE_LATEST}/geoipupdate_${GEOIPUPDATE_LATEST#v}_linux_${ARCH}.tar.gz"; \
    \
    # extract binary and move to /usr/local/bin
    tar -xzf /tmp/geoipupdate.tar.gz -C /tmp; \
    mv /tmp/geoipupdate_*_linux_${ARCH}/geoipupdate /usr/local/bin/geoipupdate; \
    chmod +x /usr/local/bin/geoipupdate; \
    \
    # cleanup temp files and remove build deps
    rm -rf /tmp/*; \
    apk del .build-deps

ENV GEOIPUPDATE_EDITION_IDS="GeoLite2-Country"

# copy local files
COPY root/ /

# ports and volumes
EXPOSE 80 443
VOLUME /config
