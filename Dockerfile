# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

FROM docker.io/library/alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.description="nginx reverse proxy on Alpine Linux" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.authors="Kyle Hill" \
      org.opencontainers.image.vendor="Kyle Hill" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# renovate: datasource=apk depName=lua-resty-string
ARG LUA_RESTY_STRING_VERSION=0.15-r1
RUN set -eux; \
  # lua-resty-string declares an OpenResty-specific package dependency even
  # though nginx-mod-http-lua provides the same Lua runtime. Extract the
  # architecture-independent Lua files without installing a second nginx.
  apk fetch --no-cache --no-progress --match package --output /tmp \
    "lua-resty-string-${LUA_RESTY_STRING_VERSION}"; \
  apk add --no-cache --no-progress \
    "curl=8.22.0-r0" \
    "lua-resty-http=0.17.2-r0" \
    "lua-resty-openssl=1.6.1-r0" \
    "lua5.1-cjson=2.1.0-r12" \
    "nginx=1.30.4-r1" \
    "nginx-mod-http-brotli=1.30.4-r1" \
    "nginx-mod-http-geoip2=1.30.4-r1" \
    "nginx-mod-http-lua=1.30.4-r1" \
    "nginx-mod-http-zstd=1.30.4-r1" \
    "tzdata=2026d-r0"; \
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

# Install CrowdSec nginx bouncer
# renovate: datasource=github-release-attachments depName=crowdsecurity/cs-nginx-bouncer
ARG CROWDSEC_BOUNCER_VERSION=v1.2.3
ARG CROWDSEC_BOUNCER_SHA256=8cb0c176f01bda3a5fc5493d20bcd7261630c7dfbd60c00b2bff8eefc8fe84d5
LABEL io.github.kylhill.docker-nginx.crowdsec-bouncer.version="${CROWDSEC_BOUNCER_VERSION}"
RUN --mount=type=bind,source=patches/crowdsec-lua.patch,target=/tmp/crowdsec-lua.patch,ro \
    set -eux; \
    apk add --no-cache --virtual .crowdsec-build-deps \
      "patch=2.8-r0"; \
    CROWDSEC_ARCHIVE="/tmp/bouncer.tgz"; \
    CROWDSEC_DIR="/tmp/crowdsec-nginx-bouncer-${CROWDSEC_BOUNCER_VERSION}"; \
    \
    # download, verify, and extract the bouncer tarball
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
      --connect-timeout 15 -o "$CROWDSEC_ARCHIVE" \
      "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/${CROWDSEC_BOUNCER_VERSION}/crowdsec-nginx-bouncer.tgz"; \
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
    printf 'return "%s"\n' "${CROWDSEC_BOUNCER_VERSION#v}" \
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
