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

There are no unit tests. `scripts/verify-image.sh` is the core smoke test to run after Dockerfile, nginx config, or container startup changes. `scripts/verify-integration.sh` adds enabled-CrowdSec, secret-file conventions, resolver generation, config naming and permissions, read-only and non-root modes, persistence, TLS/HTTP2/HTTP3, GeoIP failure, and graceful-shutdown coverage. The smoke test builds the image, starts it with a temporary `/config` Docker volume, runs nginx validation, checks the CrowdSec Lua modules during nginx startup, and fails if startup logs contain error-level patterns.

## Architecture

This is a Docker image that packages nginx on top of the [linuxserver.io Alpine base image](https://github.com/linuxserver/docker-baseimage-alpine). It uses **s6-overlay** for process supervision (inherited from the base image).

### `root/` overlay

Everything under `root/` is copied directly onto the container filesystem at `/` by the `COPY root/ /` instruction. Three subtrees matter:

- **`root/defaults/nginx/`** — Shipped default nginx config. Active files are copied into `/config/nginx/` only when absent, while current defaults are refreshed on every start as adjacent `.conf.sample` files. Exact active/sample matches are removed after comparison, leaving samples only for differing persisted configs. Each shipped config has a `## Version YYYY/MM/DD` header; startup compares active files with their samples and warns when reconciliation is needed.
- **`root/defaults/runtime/`** — Immutable internal templates used to generate ephemeral files under `/run`; these are never copied into `/config`.
- **`root/etc/s6-overlay/s6-rc.d/`** — s6 service and init definitions.

### s6 init chain

Services run in dependency order:

```
init-docker-nginx-bootstrap → init-docker-nginx-samples → init-docker-nginx-config
→ init-docker-nginx-resolver → init-docker-nginx-geoipupdate → init-docker-nginx-crowdsec
→ init-docker-nginx-permissions → init-docker-nginx-version-checks
→ init-docker-nginx-validate → init-docker-nginx-end
                                              ├→ svc-docker-nginx
                                              └→ svc-docker-nginx-geoipupdate
```

- `init-docker-nginx-bootstrap`: creates `/config/geoip`, `/config/keys`, `/config/nginx/site-confs`, generates the persistent `/config/keys/quic_host.key`, and generates fallback TLS credentials when absent
- `init-docker-nginx-samples`: removes the previous image-managed `*.conf.sample` set and refreshes samples beside active configs for host-side comparison
- `init-docker-nginx-config`: copies missing active files from `/defaults/nginx/` without replacing user files
- `init-docker-nginx-resolver`: generates a missing resolver snippet from `/etc/resolv.conf`
- `init-docker-nginx-geoipupdate`: validates GeoIPUpdate credentials, writes its runtime configuration, and bootstraps any missing configured database
- `init-docker-nginx-crowdsec`: generates the enabled CrowdSec runtime and nginx configuration
- `init-docker-nginx-permissions`: makes nginx configuration group-writable and sets root-mode ownership of `/config/**` to `abc:abc`
- `init-docker-nginx-version-checks`: removes exact active/sample matches, warns about remaining version mismatches, and reports ignored site-conf filenames
- `init-docker-nginx-validate`: validates the completed configuration with `nginx -t`
- `svc-docker-nginx`: kills any zombie nginx processes then execs `nginx -e stderr`
- `svc-docker-nginx-geoipupdate`: refreshes configured GeoIP databases immediately and every 24 hours without blocking nginx startup

### nginx config loading

The entrypoint is `/etc/nginx/nginx.conf`, which simply includes `/config/nginx/nginx.conf`. That file includes:

- `/config/nginx/http.d/*.conf` — http-context config blocks (compression, caching, etc.)
- `/config/nginx/site-confs/*.subdomain.conf` — virtual host/reverse proxy server blocks (**must match `*.subdomain.conf`**)

## Key Conventions

### Shipped config version headers

Every shipped nginx `.conf` under `root/defaults/nginx/` must begin with a
`## Version YYYY/MM/DD` header. Whenever a shipped config is changed, update
that file's version date as part of the same change. This is required even for
small configuration changes so persisted `/config` users receive the startup
warning and know to manually compare and reconcile the new default.

Use the date of the change. If a version with that date has already been
published, advance the header again before publishing; never ship different
config contents under a previously published version string.

### Snippet composition for server blocks

The `snippets/server-base.conf` is the canonical single include for HTTPS server blocks. It pulls in:

```
listen-https.conf  →  port 443 listen directives (including HTTP/2 & HTTP/3/QUIC)
hsts.conf          →  configurable Strict-Transport-Security header
geoip-block.conf   →  returns 403 if $access_allowed = no
no-robots.conf     →  X-Robots-Tag header
security-headers.conf → security headers
```

Use `proxy.conf` for upstream proxy locations — it includes `proxy-common.conf` and `static-assets.conf`. HTTPS upstream locations should also include `proxy-ssl-verify.conf` when their certificates chain to the system trust bundle.

### Site conf naming requirement

Files placed in `/config/nginx/site-confs/` **must be named `*.subdomain.conf`** to be picked up by the nginx include glob. Startup warns when other non-sample files are silently ignored by nginx.

### GeoIP environment variables

| Variable | Purpose |
|---|---|
| `GEOIPUPDATE_ACCOUNT_ID` | MaxMind account ID |
| `GEOIPUPDATE_LICENSE_KEY` | MaxMind license key |
| `GEOIPUPDATE_EDITION_IDS` | Database editions (default: `GeoLite2-Country`) |

`GEOIPUPDATE_ACCOUNT_ID`, `GEOIPUPDATE_LICENSE_KEY`, and `CROWDSEC_NGINX_API_KEY` support both the `_FILE` suffix pattern (e.g., `GEOIPUPDATE_LICENSE_KEY_FILE=/run/secrets/maxmind_key`) and LinuxServer's `FILE__VARIABLE` convention (e.g., `FILE__GEOIPUPDATE_LICENSE_KEY=/run/secrets/maxmind_key`). `GEOIPUPDATE_EDITION_IDS` is a non-secret database selection setting.

Generated GeoIPUpdate and CrowdSec credential files live under `/run`; read-only deployments require writable `/config` plus tmpfs mounts for `/run:exec` and `/tmp`.

The LinuxServer base image supplies `PUID`, `PGID`, `TZ`, and `UMASK`. Explicit
non-root operation uses the container runtime's `user` setting and requires a
pre-writable `/config`; do not assume `PUID`/`PGID` change ownership in that
mode. LinuxServer does not generally support combining read-only and non-root
modes, but this image's integration suite tests its documented combined
hardening profile.

### Dockerfile

`Dockerfile` is used for both local and CI builds. CI builds a multi-platform image for amd64 and arm64 via buildx, and the Dockerfile cleans up default `/var/www` content for all platforms.

### CI / Publishing

Pull requests run ShellCheck, Hadolint, amd64 integration tests, and core smoke tests on both amd64 and arm64 under QEMU. Pushes to `main` and scheduled publishing reuse those checks before publishing. Daily scheduled runs compare the current upstream LinuxServer manifest digest with the digest recorded on `latest` and build only when it changed. Alpine packages and Lua rocks float at build time; GeoIPUpdate and the CrowdSec bouncer are fixed and checksum-verified. GitHub Actions remain pinned to immutable commit SHAs. Images are tagged as both `latest` and a source/run-specific rollback tag, with SBOM and provenance attestations attached.
