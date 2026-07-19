# Repository Agent Instructions

## Build Commands

```bash
# Build for local architecture
docker build -t docker-nginx .

# Build multi-platform (as CI does)
docker buildx build --platform linux/amd64,linux/arm64 -t docker-nginx .
```

## Verification

```bash
# Build the image, start a temporary container, run nginx validation, and scan logs
scripts/verify-image.sh
```

There are no unit tests. `scripts/verify-image.sh` is the smoke test to run after Dockerfile, nginx config, or container startup changes. It builds the image, starts it with a temporary `/config` Docker volume, runs `nginx -t`, checks the CrowdSec Lua modules can be loaded by nginx, and fails if startup logs contain error-level patterns.

## Architecture

This is a Docker image that packages nginx on top of the [linuxserver.io Alpine base image](https://github.com/linuxserver/docker-baseimage-alpine). It uses **s6-overlay** for process supervision (inherited from the base image).

### `root/` overlay

Everything under `root/` is copied directly onto the container filesystem at `/` by the `COPY root/ /` instruction. Two subtrees matter:

- **`root/defaults/nginx/`** — Shipped default nginx config. Merged into `/config/nginx/` at container startup via `cp -ru`; a shipped file can replace an older destination file based on modification time, so config migration behavior must be reviewed carefully.
- **`root/etc/s6-overlay/s6-rc.d/`** — s6 service and init definitions.

### s6 init chain

Services run in dependency order:

```
init-folders → init-nginx → init-permissions → init-nginx-end
                                                      ↓
                                               svc-nginx (long-running)
```

- `init-folders`: creates `/config/geoip`, `/config/keys`, `/config/nginx/site-confs`
- `init-nginx`: runs `cp -ru /defaults/nginx/ /config/` and validates config with `nginx -t`
- `init-permissions`: sets ownership of `/config/**` to `abc:abc`
- `svc-nginx`: kills any zombie nginx processes then execs `nginx -e stderr`

Container initialization (`root/etc/cont-init.d/10-geoipupdate`) runs `geoipupdate` to download GeoIP databases if credentials are provided.

### nginx config loading

The entrypoint is `/etc/nginx/nginx.conf`, which simply includes `/config/nginx/nginx.conf`. That file includes:

- `/config/nginx/http.d/*.conf` — http-context config blocks (compression, caching, etc.)
- `/config/nginx/site-confs/*.subdomain.conf` — virtual host/reverse proxy server blocks (**must match `*.subdomain.conf`**)

## Key Conventions

### Snippet composition for server blocks

The `snippets/server-base.conf` is the canonical single include for HTTPS server blocks. It pulls in:

```
listen-https.conf  →  port 443 listen directives (including HTTP/2 & HTTP/3/QUIC)
ssl.conf           →  TLS config (certs from /config/keys/cert.crt + cert.key)
geoip-block.conf   →  returns 403 if $access_allowed = no
no-robots.conf     →  X-Robots-Tag header
security-headers.conf → security headers
```

Use `proxy.conf` for upstream proxy locations — it includes `proxy-common.conf` and `static-assets.conf`.

### Site conf naming requirement

Files placed in `/config/nginx/site-confs/` **must be named `*.subdomain.conf`** to be picked up by the nginx include glob. Files named otherwise are silently ignored.

### GeoIP environment variables

| Variable | Purpose |
|---|---|
| `GEOIPUPDATE_ACCOUNT_ID` | MaxMind account ID |
| `GEOIPUPDATE_LICENSE_KEY` | MaxMind license key |
| `GEOIPUPDATE_EDITION_IDS` | Database editions (default: `GeoLite2-Country`) |

All three support the `_FILE` suffix pattern for Docker secrets (e.g., `GEOIPUPDATE_LICENSE_KEY_FILE=/run/secrets/maxmind_key`).

### Dockerfile

`Dockerfile` is used for both local and CI builds. CI builds a multi-platform image for amd64 and arm64 via buildx, and the Dockerfile cleans up default `/var/www` content for all platforms.

### CI / Publishing

Pushes to `main` always trigger a fresh smoke-tested multi-platform publish. Daily scheduled runs compare the current upstream LinuxServer manifest digest with the digest recorded on `latest` and build only when it changed. Alpine packages and Lua rocks float at build time; GeoIPUpdate and the CrowdSec bouncer are fixed and checksum-verified. GitHub Actions remain pinned to immutable commit SHAs. Images are tagged as both `latest` and a source/run-specific rollback tag, with SBOM and provenance attestations attached.
