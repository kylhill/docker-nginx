# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32

ARG BASE_IMAGE=docker.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
FROM ${BASE_IMAGE} AS runtime-packages

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.description="nginx reverse proxy on Alpine Linux" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.authors="Kyle Hill" \
      org.opencontainers.image.vendor="Kyle Hill" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# install packages
# Records an intentional refresh of the floating Alpine package set.
ARG APK_REFRESH_DATE=2026-08-23
ARG LUA_RESTY_STRING_VERSION=0.15-r1
RUN set -eux; \
  : "${APK_REFRESH_DATE}"; \
  # lua-resty-string declares an OpenResty-specific package dependency even
  # though nginx-mod-http-lua provides the same Lua runtime. Extract the
  # architecture-independent Lua files without installing a second nginx.
  apk fetch --no-cache --no-progress --output /tmp lua-resty-string; \
  test -f "/tmp/lua-resty-string-${LUA_RESTY_STRING_VERSION}.apk"; \
  apk add --no-cache --no-progress \
    curl \
    lua-resty-http \
    lua-resty-openssl \
    lua5.1-cjson \
    nginx \
    nginx-mod-http-brotli \
    nginx-mod-http-geoip2 \
    nginx-mod-http-lua \
    nginx-mod-http-zstd \
    tzdata; \
  tar -xzf "/tmp/lua-resty-string-${LUA_RESTY_STRING_VERSION}.apk" \
    -C / usr/share/lua/common; \
  rm -f "/tmp/lua-resty-string-${LUA_RESTY_STRING_VERSION}.apk"; \
  # Remove default config
  rm -f /etc/nginx/http.d/default.conf; \
  # Alpine stores its module symlink below this directory. Arbitrary-UID
  # operation needs traverse access to load nginx modules.
  chmod 0755 /var/lib/nginx; \
  # apk.log records build timestamps and is not useful at runtime.
  rm -f /var/log/apk.log;

FROM runtime-packages AS final

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

# Install CrowdSec nginx bouncer
ARG CROWDSEC_BOUNCER_VERSION=1.2.1
ARG CROWDSEC_BOUNCER_SHA256=10876f49e78cb7e3d03340d9f80a6586375ccd230acda2fe5e994b7ade2bd3db
LABEL io.github.kylhill.docker-nginx.crowdsec-bouncer.version="${CROWDSEC_BOUNCER_VERSION}"
RUN --mount=type=bind,source=patches/crowdsec-lua.patch,target=/tmp/crowdsec-lua.patch,ro \
    set -eux; \
    apk add --no-cache --virtual .crowdsec-build-deps \
      patch; \
    CROWDSEC_ARCHIVE="/tmp/bouncer.tgz"; \
    CROWDSEC_DIR="/tmp/crowdsec-nginx-bouncer-v${CROWDSEC_BOUNCER_VERSION}"; \
    \
    # download, verify, and extract the bouncer tarball
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
      --connect-timeout 15 -o "$CROWDSEC_ARCHIVE" \
      "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v${CROWDSEC_BOUNCER_VERSION}/crowdsec-nginx-bouncer.tgz"; \
    echo "${CROWDSEC_BOUNCER_SHA256}  ${CROWDSEC_ARCHIVE}" | sha256sum -c -; \
    tar -xzf "$CROWDSEC_ARCHIVE" -C /tmp; \
    \
    # Apply the two intentional local behavior fixes without allowing fuzzy
    # matches, so a future upstream source change fails the build.
    patch --batch --forward --fuzz=0 -p1 \
        -d "$CROWDSEC_DIR/lua-mod/lib" \
        < /tmp/crowdsec-lua.patch; \
    \
    # install Lua library files
    install -Dm 0644 "$CROWDSEC_DIR/lua-mod/lib/crowdsec.lua" \
      /usr/local/lua/crowdsec/crowdsec.lua; \
    install -d -m 0755 /usr/local/lua/crowdsec/plugins/crowdsec; \
    install -m 0644 "$CROWDSEC_DIR"/lua-mod/lib/plugins/crowdsec/*.lua \
      /usr/local/lua/crowdsec/plugins/crowdsec/; \
    printf 'return "%s"\n' "$CROWDSEC_BOUNCER_VERSION" \
        > /usr/local/lua/crowdsec/bouncer_version.lua; \
    \
    # install ban HTML template only (no captcha)
    install -Dm 0644 "$CROWDSEC_DIR/lua-mod/templates/ban.html" \
      /var/lib/crowdsec/lua/templates/ban.html; \
    \
    # cleanup
    rm -f "$CROWDSEC_ARCHIVE"; \
    rm -rf "$CROWDSEC_DIR"; \
    apk --no-network --repositories-file /dev/null \
      del .crowdsec-build-deps; \
    rm -f /var/log/apk.log

# ports
EXPOSE 80/tcp 443/tcp 443/udp

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=5m --timeout=3s --start-period=30s --start-interval=5s --retries=3 \
  CMD ["curl", "--fail", "--silent", "--show-error", "--max-time", "2", "--unix-socket", "/run/nginx-healthcheck.sock", "http://localhost/health"]

CMD ["nginx", "-c", "/config/nginx/nginx.conf", "-e", "stderr", "-g", "daemon off; pid /run/nginx.pid;"]
