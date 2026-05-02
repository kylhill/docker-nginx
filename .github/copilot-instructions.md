# Copilot Instructions

## Build Commands

```bash
# Build for local architecture
docker build -t docker-nginx .

# Build multi-platform (as CI does)
docker buildx build --platform linux/amd64,linux/arm64 -t docker-nginx .

# Build explicit aarch64 image
docker build -f Dockerfile.aarch64 -t docker-nginx:aarch64 .
```

There are no automated tests. Nginx config validation runs at container startup via `nginx -t`.

## Architecture

This is a Docker image that packages nginx on top of the [linuxserver.io Alpine base image](https://github.com/linuxserver/docker-baseimage-alpine). It uses **s6-overlay** for process supervision (inherited from the base image).

### `root/` overlay

Everything under `root/` is copied directly onto the container filesystem at `/` by the `COPY root/ /` instruction. Two subtrees matter:

- **`root/defaults/nginx/`** — Shipped default nginx config. Copied non-destructively into `/config/nginx/` at container startup via `cp -ru`, so user-modified files in `/config/` are never overwritten on upgrade.
- **`root/etc/s6-overlay/s6-rc.d/`** — s6 service and init definitions.

### s6 init chain

Services run in dependency order:

```
init-folders → init-nginx → init-permissions → init-nginx-end
                                                      ↓
                                               svc-nginx (long-running)
```

- `init-folders`: creates `/config/geoip`, `/config/keys`, `/config/log/nginx`, `/config/nginx/site-confs`
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

### Two Dockerfiles

- `Dockerfile` — used by CI for multi-platform builds (amd64 + arm64 via buildx). Also cleans up `/var/www` default content.
- `Dockerfile.aarch64` — explicit arm64 base image; does **not** remove `/var/www` content.

### CI / Publishing

Pushes to `main` trigger `.github/workflows/docker-publish.yml`, which builds and pushes a multi-platform manifest to `ghcr.io/kylhill/docker-nginx` tagged as both `latest` and the commit SHA.
