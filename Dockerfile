# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-alpine:3.24
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.description="nginx reverse proxy on linuxserver.io Alpine base image" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# install packages
RUN set -eux; \
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
      gcc \
      lua5.1-dev \
      luarocks5.1 \
      musl-dev; \
    \
    # install Lua dependencies for crowdsec-nginx-bouncer
    luarocks-5.1 install lua-resty-string; \
    luarocks-5.1 install lua-resty-openssl; \
    luarocks-5.1 install lua-resty-http; \
    luarocks-5.1 install lua-cjson; \
    \
    # # cleanup
    rm -rf /tmp/*; \
    apk del .lua-build-deps

# Install GeoIPUpdate
ARG GEOIPUPDATE_VERSION=8.0.0
ARG GEOIPUPDATE_AMD64_SHA256=941eb4dd8c1eafb6ee1d56ccd5f4c62ffbdaca5f65a9f9cadc4008c8d805f2a2
ARG GEOIPUPDATE_ARM64_SHA256=76cedc3bad8b5f02a3ea42ac84c57d318a758377a07806f7a13189a382f16308
RUN set -eux; \
    apk add --no-cache --virtual .geoip-build-deps \
      curl \
      tar \
      ca-certificates; \
    \
    # detect architecture for GitHub release
    case "$(apk --print-arch)" in \
      x86_64) RELEASE_ARCH="amd64"; GEOIPUPDATE_SHA256="$GEOIPUPDATE_AMD64_SHA256";; \
      aarch64) RELEASE_ARCH="arm64"; GEOIPUPDATE_SHA256="$GEOIPUPDATE_ARM64_SHA256";; \
      *) echo "Unsupported architecture"; exit 1;; \
    esac; \
    \
    # download and verify the tar.gz for the architecture
    curl -fsSL -o /tmp/geoipupdate.tar.gz \
      "https://github.com/maxmind/geoipupdate/releases/download/v${GEOIPUPDATE_VERSION}/geoipupdate_${GEOIPUPDATE_VERSION}_linux_${RELEASE_ARCH}.tar.gz"; \
    printf '%s  %s\n' "$GEOIPUPDATE_SHA256" /tmp/geoipupdate.tar.gz | sha256sum -c -; \
    \
    # extract binary and move to /usr/local/bin
    tar -xzf /tmp/geoipupdate.tar.gz -C /tmp; \
    mv /tmp/geoipupdate_${GEOIPUPDATE_VERSION}_linux_${RELEASE_ARCH}/geoipupdate /usr/local/bin/geoipupdate; \
    chmod +x /usr/local/bin/geoipupdate; \
    \
    # cleanup
    rm -rf /tmp/*; \
    apk del .geoip-build-deps

# Install CrowdSec nginx bouncer
ARG CROWDSEC_BOUNCER_VERSION=1.1.6
ARG CROWDSEC_BOUNCER_SHA256=323c6bd182cda2221d5b2d3d21b7e5e0b66ec77dd306a37299916617c3d50eea
LABEL io.github.kylhill.docker-nginx.geoipupdate.version="${GEOIPUPDATE_VERSION}" \
      io.github.kylhill.docker-nginx.crowdsec-bouncer.version="${CROWDSEC_BOUNCER_VERSION}"
RUN set -eux; \
    apk add --no-cache --virtual .crowdsec-build-deps \
      curl \
      tar \
      ca-certificates; \
    \
    # download, verify, and extract the bouncer tarball
    curl -fsSL -o /tmp/bouncer.tgz \
      "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v${CROWDSEC_BOUNCER_VERSION}/crowdsec-nginx-bouncer.tgz"; \
    printf '%s  %s\n' "$CROWDSEC_BOUNCER_SHA256" /tmp/bouncer.tgz | sha256sum -c -; \
    tar -xzf /tmp/bouncer.tgz -C /tmp; \
    \
    # install Lua library files
    mkdir -p /usr/local/lua/crowdsec/plugins/crowdsec; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/lib/crowdsec.lua /usr/local/lua/crowdsec/; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/lib/plugins/crowdsec/*.lua /usr/local/lua/crowdsec/plugins/crowdsec/; \
    printf 'return "%s"\n' "$CROWDSEC_BOUNCER_VERSION" \
        > /usr/local/lua/crowdsec/bouncer_version.lua; \
    \
    # patch captcha plugin to return gracefully (no error) when no provider is configured,
    # so nginx starts cleanly without the "no recaptcha site key" error log
    grep -q 'function M.New(siteKey, secretKey, TemplateFilePath, captcha_provider, ret_code)' \
        /usr/local/lua/crowdsec/plugins/crowdsec/captcha.lua; \
    sed -i 's|function M.New(siteKey, secretKey, TemplateFilePath, captcha_provider, ret_code)|function M.New(siteKey, secretKey, TemplateFilePath, captcha_provider, ret_code)\n    if captcha_provider == nil or captcha_provider == "" then\n        return\n    end|' \
        /usr/local/lua/crowdsec/plugins/crowdsec/captcha.lua; \
    \
    # downgrade "APPSEC is enabled" from ERR to INFO - it's an informational startup message
    grep -q 'ngx.log(ngx.ERR, "APPSEC is enabled' \
        /usr/local/lua/crowdsec/crowdsec.lua; \
    sed -i 's|ngx.log(ngx.ERR, "APPSEC is enabled|ngx.log(ngx.INFO, "APPSEC is enabled|' \
        /usr/local/lua/crowdsec/crowdsec.lua; \
    \
    # install ban HTML template only (no captcha)
    mkdir -p /var/lib/crowdsec/lua/templates; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/templates/ban.html /var/lib/crowdsec/lua/templates/; \
    \
    # install bouncer config template adjusted by cont-init.d/20-crowdsec-bouncer
    # at startup
    mkdir -p /etc/crowdsec/bouncers; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/config_example.conf \
        /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.template; \
    \
    # cleanup
    rm -rf /tmp/*; \
    apk del .crowdsec-build-deps

ENV GEOIPUPDATE_EDITION_IDS="GeoLite2-Country"

# copy local files
COPY root/ /

# ports and volumes
EXPOSE 80/tcp 443/tcp 443/udp
VOLUME /config
