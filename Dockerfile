# syntax=docker/dockerfile:1

# Inspired by https://github.com/linuxserver/docker-baseimage-alpine-nginx/blob/master/Dockerfile
ARG BASE_IMAGE=ghcr.io/linuxserver/baseimage-alpine:3.24
FROM ${BASE_IMAGE}

LABEL maintainer="Kyle Hill" \
      org.opencontainers.image.title="docker-nginx" \
      org.opencontainers.image.description="nginx reverse proxy on linuxserver.io Alpine base image" \
      org.opencontainers.image.url="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.source="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.documentation="https://github.com/kylhill/docker-nginx" \
      org.opencontainers.image.authors="Kyle Hill" \
      org.opencontainers.image.vendor="Kyle Hill" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# install packages
RUN set -eux; \
  # lua-resty-string declares an OpenResty-specific package dependency even
  # though nginx-mod-http-lua provides the same Lua runtime. Extract the
  # architecture-independent Lua files without installing a second nginx.
  apk fetch --no-cache --no-progress --output /tmp lua-resty-string; \
  apk add --no-cache --no-progress \
    curl \
    lua-resty-http \
    lua5.1-cjson \
    nginx \
    nginx-mod-http-brotli \
    nginx-mod-http-geoip2 \
    nginx-mod-http-lua \
    nginx-mod-http-zstd \
    openssl; \
  tar -xzf /tmp/lua-resty-string-*.apk -C / usr/share/lua/common; \
  rm -f /tmp/lua-resty-string-*.apk; \
  # Remove default config
  rm -f /etc/nginx/http.d/default.conf; \
  # Alpine stores its module symlink below this directory. Arbitrary-UID
  # LinuxServer non-root mode needs traverse access to load nginx modules.
  chmod 0755 /var/lib/nginx; \
  # Remove default /var/www content
  find /var/www -mindepth 1 ! -path /var/www/favicon.ico -exec rm -rf {} +;

# Install GeoIPUpdate
ARG GEOIPUPDATE_VERSION=8.0.0
ARG GEOIPUPDATE_AMD64_SHA256=941eb4dd8c1eafb6ee1d56ccd5f4c62ffbdaca5f65a9f9cadc4008c8d805f2a2
ARG GEOIPUPDATE_ARM64_SHA256=76cedc3bad8b5f02a3ea42ac84c57d318a758377a07806f7a13189a382f16308
RUN set -eux; \
    # detect architecture for GitHub release
    case "$(apk --print-arch)" in \
      x86_64) RELEASE_ARCH="amd64"; GEOIPUPDATE_SHA256="$GEOIPUPDATE_AMD64_SHA256";; \
      aarch64) RELEASE_ARCH="arm64"; GEOIPUPDATE_SHA256="$GEOIPUPDATE_ARM64_SHA256";; \
      *) echo "Unsupported architecture"; exit 1;; \
    esac; \
    GEOIPUPDATE_ARCHIVE="/tmp/geoipupdate.tar.gz"; \
    GEOIPUPDATE_DIR="/tmp/geoipupdate_${GEOIPUPDATE_VERSION}_linux_${RELEASE_ARCH}"; \
    \
    # download and verify the tar.gz for the architecture
    curl -fsSL -o "$GEOIPUPDATE_ARCHIVE" \
      "https://github.com/maxmind/geoipupdate/releases/download/v${GEOIPUPDATE_VERSION}/geoipupdate_${GEOIPUPDATE_VERSION}_linux_${RELEASE_ARCH}.tar.gz"; \
    echo "${GEOIPUPDATE_SHA256}  ${GEOIPUPDATE_ARCHIVE}" \
      > "${GEOIPUPDATE_ARCHIVE}.sha256"; \
    sha256sum -c "${GEOIPUPDATE_ARCHIVE}.sha256"; \
    \
    # extract and install the binary
    tar -xzf "$GEOIPUPDATE_ARCHIVE" -C /tmp; \
    install -m 0755 "$GEOIPUPDATE_DIR/geoipupdate" /usr/local/bin/geoipupdate; \
    \
    # cleanup
    rm -f "$GEOIPUPDATE_ARCHIVE" "${GEOIPUPDATE_ARCHIVE}.sha256"; \
    rm -rf "$GEOIPUPDATE_DIR"

# Install CrowdSec nginx bouncer
ARG CROWDSEC_BOUNCER_VERSION=1.1.6
ARG CROWDSEC_BOUNCER_SHA256=323c6bd182cda2221d5b2d3d21b7e5e0b66ec77dd306a37299916617c3d50eea
LABEL io.github.kylhill.docker-nginx.geoipupdate.version="${GEOIPUPDATE_VERSION}" \
      io.github.kylhill.docker-nginx.crowdsec-bouncer.version="${CROWDSEC_BOUNCER_VERSION}"
COPY patches/crowdsec-lua-1.0.14.patch /tmp/crowdsec-lua.patch
RUN set -eux; \
    apk add --no-cache --virtual .crowdsec-build-deps \
      patch; \
    CROWDSEC_ARCHIVE="/tmp/bouncer.tgz"; \
    CROWDSEC_DIR="/tmp/crowdsec-nginx-bouncer-v${CROWDSEC_BOUNCER_VERSION}"; \
    \
    # download, verify, and extract the bouncer tarball
    curl -fsSL -o "$CROWDSEC_ARCHIVE" \
      "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v${CROWDSEC_BOUNCER_VERSION}/crowdsec-nginx-bouncer.tgz"; \
    echo "${CROWDSEC_BOUNCER_SHA256}  ${CROWDSEC_ARCHIVE}" \
      > "${CROWDSEC_ARCHIVE}.sha256"; \
    sha256sum -c "${CROWDSEC_ARCHIVE}.sha256"; \
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
    # install bouncer config template adjusted by the namespaced CrowdSec s6
    # service at startup
    install -Dm 0644 "$CROWDSEC_DIR/lua-mod/config_example.conf" \
        /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.template; \
    \
    # cleanup
    rm -f "$CROWDSEC_ARCHIVE" "${CROWDSEC_ARCHIVE}.sha256" \
      /tmp/crowdsec-lua.patch; \
    rm -rf "$CROWDSEC_DIR"; \
    apk del .crowdsec-build-deps

ENV GEOIPUPDATE_EDITION_IDS="GeoLite2-Country" \
    S6_BEHAVIOUR_IF_STAGE2_FAILS="2"

# copy local files
COPY root/ /

# ports
EXPOSE 80/tcp 443/tcp 443/udp

HEALTHCHECK --interval=5m --timeout=3s --start-period=30s --start-interval=5s --retries=3 \
  CMD ["curl", "--fail", "--silent", "--show-error", "--max-time", "2", "--unix-socket", "/run/nginx-healthcheck.sock", "http://localhost/health"]
