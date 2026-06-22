# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-alpine:3.24
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx"

# install packages
RUN set -eux; \
  apk update; \
  apk add --no-cache --no-progress \
    nginx \
    nginx-mod-http-brotli \
    nginx-mod-http-geoip2 \
    nginx-mod-http-lua \
    nginx-mod-http-zstd; \
  # Remove default config
  rm -f /etc/nginx/http.d/default.conf; \
  # Remove default /var/www content
  find /var/www -mindepth 1 ! -path /var/www/favicon.ico -exec rm -rf {} +;

# Install Lua dependencies the same way upstream's Ubuntu installer does.
# See https://github.com/crowdsecurity/cs-nginx-bouncer/blob/main/install.sh
RUN set -eux; \
    apk add --no-cache --virtual .lua-build-deps \
      build-base \
      ca-certificates \
      lua5.1-dev \
      luarocks5.1; \
    luarocks-5.1 install lua-resty-http 0.17.1-0; \
    luarocks-5.1 install lua-cjson 2.1.0.10-1; \
    apk del .lua-build-deps

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
    # cleanup
    rm -rf /tmp/*; \
    apk del .build-deps

# install latest crowdsec-nginx-bouncer Lua module from GitHub
RUN set -eux; \
    apk add --no-cache --virtual .build-deps curl jq tar ca-certificates; \
    \
    # get latest release tag from GitHub API
    BOUNCER_LATEST="$(curl -s https://api.github.com/repos/crowdsecurity/cs-nginx-bouncer/releases/latest | jq -r .tag_name)"; \
    echo "Latest crowdsec-nginx-bouncer release: $BOUNCER_LATEST"; \
    \
    # download and extract the bouncer tarball
    curl -L -o /tmp/bouncer.tgz \
      "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/${BOUNCER_LATEST}/crowdsec-nginx-bouncer.tgz"; \
    tar -xzf /tmp/bouncer.tgz -C /tmp; \
    \
    # install Lua library files
    mkdir -p /usr/local/lua/crowdsec/plugins/crowdsec; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/lib/crowdsec.lua /usr/local/lua/crowdsec/; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/lib/plugins/crowdsec/*.lua /usr/local/lua/crowdsec/plugins/crowdsec/; \
    \
    # install bouncer config template adjusted by cont-init.d/20-crowdsec-bouncer
    # at startup
    mkdir -p /etc/crowdsec/bouncers; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/config_example.conf \
        /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.template; \
    \
    # cleanup
    rm -rf /tmp/*; \
    apk del .build-deps

ENV GEOIPUPDATE_EDITION_IDS="GeoLite2-Country"

# copy local files
COPY root/ /

# ports and volumes
EXPOSE 80 443
VOLUME /config
