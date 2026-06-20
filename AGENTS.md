# Repository Agent Instructions

## Build Commands

```bash
# Build for local architecture
docker build -t docker-nginx .

# Build multi-platform (as CI does)
docker buildx build --platform linux/amd64,linux/arm64 -t docker-nginx .
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

Pushes to `main` trigger `.github/workflows/docker-publish.yml`, which builds and pushes a multi-platform manifest to `ghcr.io/kylhill/docker-nginx` tagged as both `latest` and the commit SHA.


<!-- headroom:rtk-instructions -->
# RTK (Rust Token Killer) - Token-Optimized Commands

When running shell commands, **always prefix with `rtk`**. This reduces context
usage by 60-90% with zero behavior change. If rtk has no filter for a command,
it passes through unchanged — so it is always safe to use.

## Key Commands
```bash
# Git (59-80% savings)
rtk git status          rtk git diff            rtk git log

# Files & Search (60-75% savings)
rtk ls <path>           rtk read <file>         rtk grep <pattern>
rtk find <pattern>      rtk diff <file>

# Test (90-99% savings) — shows failures only
rtk pytest tests/       rtk cargo test          rtk test <cmd>

# Build & Lint (80-90% savings) — shows errors only
rtk tsc                 rtk lint                rtk cargo build
rtk prettier --check    rtk mypy                rtk ruff check

# Analysis (70-90% savings)
rtk err <cmd>           rtk log <file>          rtk json <file>
rtk summary <cmd>       rtk deps                rtk env

# GitHub (26-87% savings)
rtk gh pr view <n>      rtk gh run list         rtk gh issue list

# Infrastructure (85% savings)
rtk docker ps           rtk kubectl get         rtk docker logs <c>

# Package managers (70-90% savings)
rtk pip list            rtk pnpm install        rtk npm run <script>
```

## Rules
- In command chains, prefix each segment: `rtk git add . && rtk git commit -m "msg"`
- For debugging, use raw command without rtk prefix
- `rtk proxy <cmd>` runs command without filtering but tracks usage
<!-- /headroom:rtk-instructions -->
