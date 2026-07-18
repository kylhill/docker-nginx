# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-alpine:3.24
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx"

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
    luarocks-5.1 install lua-resty-http 0.17.1-0; \
    luarocks-5.1 install lua-cjson 2.1.0.10-1; \
    \
    # # cleanup
    rm -rf /tmp/*; \
    apk del .lua-build-deps

# install latest geoipupdate release from GitHub
RUN set -eux; \
    apk add --no-cache --virtual .geoip-build-deps \
      curl \
      jq \
      tar \
      ca-certificates; \
    \
    # detect architecture for GitHub release
    ARCH="$(apk --print-arch)"; \
    case "$ARCH" in \
      x86_64) ARCH="amd64";; \
      aarch64) ARCH="arm64";; \
      *) echo "Unsupported arch $ARCH"; exit 1;; \
    esac; \
    \
    # resolve the latest release asset and its GitHub-provided digest
    GEOIPUPDATE_RELEASE="$(curl -fsSL https://api.github.com/repos/maxmind/geoipupdate/releases/latest)"; \
    GEOIPUPDATE_LATEST="$(printf '%s' "$GEOIPUPDATE_RELEASE" | jq -er .tag_name)"; \
    GEOIPUPDATE_ASSET="geoipupdate_${GEOIPUPDATE_LATEST#v}_linux_${ARCH}.tar.gz"; \
    GEOIPUPDATE_URL="$(printf '%s' "$GEOIPUPDATE_RELEASE" | jq -er --arg asset "$GEOIPUPDATE_ASSET" '.assets[] | select(.name == $asset) | .browser_download_url')"; \
    GEOIPUPDATE_SHA256="$(printf '%s' "$GEOIPUPDATE_RELEASE" | jq -er --arg asset "$GEOIPUPDATE_ASSET" '.assets[] | select(.name == $asset) | .digest | select(startswith("sha256:")) | sub("^sha256:"; "")')"; \
    echo "Latest GeoIPUpdate release: $GEOIPUPDATE_LATEST"; \
    \
    # download and verify the tar.gz for the architecture
    curl -fsSL -o /tmp/geoipupdate.tar.gz "$GEOIPUPDATE_URL"; \
    printf '%s  %s\n' "$GEOIPUPDATE_SHA256" /tmp/geoipupdate.tar.gz | sha256sum -c -; \
    \
    # extract binary and move to /usr/local/bin
    tar -xzf /tmp/geoipupdate.tar.gz -C /tmp; \
    mv /tmp/geoipupdate_*_linux_${ARCH}/geoipupdate /usr/local/bin/geoipupdate; \
    chmod +x /usr/local/bin/geoipupdate; \
    \
    # cleanup
    rm -rf /tmp/*; \
    apk del .geoip-build-deps

# install latest crowdsec-nginx-bouncer Lua module from GitHub
RUN set -eux; \
    apk add --no-cache --virtual .crowdsec-build-deps \
      curl \
      jq \
      tar \
      ca-certificates; \
    \
    # resolve the latest release asset and its GitHub-provided digest
    BOUNCER_RELEASE="$(curl -fsSL https://api.github.com/repos/crowdsecurity/cs-nginx-bouncer/releases/latest)"; \
    BOUNCER_LATEST="$(printf '%s' "$BOUNCER_RELEASE" | jq -er .tag_name)"; \
    BOUNCER_ASSET="crowdsec-nginx-bouncer.tgz"; \
    BOUNCER_URL="$(printf '%s' "$BOUNCER_RELEASE" | jq -er --arg asset "$BOUNCER_ASSET" '.assets[] | select(.name == $asset) | .browser_download_url')"; \
    BOUNCER_SHA256="$(printf '%s' "$BOUNCER_RELEASE" | jq -er --arg asset "$BOUNCER_ASSET" '.assets[] | select(.name == $asset) | .digest | select(startswith("sha256:")) | sub("^sha256:"; "")')"; \
    echo "Latest crowdsec-nginx-bouncer release: $BOUNCER_LATEST"; \
    \
    # download, verify, and extract the bouncer tarball
    curl -fsSL -o /tmp/bouncer.tgz "$BOUNCER_URL"; \
    printf '%s  %s\n' "$BOUNCER_SHA256" /tmp/bouncer.tgz | sha256sum -c -; \
    tar -xzf /tmp/bouncer.tgz -C /tmp; \
    \
    # install Lua library files
    mkdir -p /usr/local/lua/crowdsec/plugins/crowdsec; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/lib/crowdsec.lua /usr/local/lua/crowdsec/; \
    cp /tmp/crowdsec-nginx-bouncer-*/lua-mod/lib/plugins/crowdsec/*.lua /usr/local/lua/crowdsec/plugins/crowdsec/; \
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
