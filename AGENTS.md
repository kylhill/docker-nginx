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

There are no unit tests. `scripts/verify-image.sh` is the core smoke test to run after Dockerfile, nginx config, or container startup changes. `scripts/verify-integration.sh` covers enabled CrowdSec, secret-file conventions, resolver generation, immutable defaults and overrides, read-only and arbitrary-UID modes, persistence, TLS, and HTTP/2. The smoke test builds the image, starts it with a temporary `/config` Docker volume, waits for health, runs nginx validation, checks the CrowdSec Lua modules during nginx startup, and fails if startup logs contain error-level patterns.

## Architecture

This is a Docker image that packages nginx on top of the [linuxserver.io Alpine base image](https://github.com/linuxserver/docker-baseimage-alpine). It uses **s6-overlay** for process supervision (inherited from the base image).

### `root/` overlay

Everything under `root/` is copied directly onto the container filesystem at `/` by the `COPY root/ /` instruction. Three subtrees matter:

- **`root/defaults/nginx/`** — Immutable shipped nginx config. Missing paths under `/config/nginx/` are created as symlinks to these defaults, while regular files at the same paths are preserved as explicit user overrides.
- **`root/defaults/runtime/`** — Immutable internal templates used to generate ephemeral files under `/run`; these are never copied into `/config`.
- **`root/etc/s6-overlay/s6-rc.d/`** — s6 service and init definitions.

### s6 init chain

Services run in dependency order:

```
init-docker-nginx-bootstrap → init-docker-nginx-config
→ init-docker-nginx-resolver → init-docker-nginx-geoipupdate → init-docker-nginx-crowdsec
→ init-docker-nginx-permissions → init-docker-nginx-validate → init-docker-nginx-end
                                              ├→ svc-docker-nginx
                                              └→ svc-docker-nginx-geoipupdate
```

- `init-docker-nginx-bootstrap`: creates `/config/geoip`, `/config/keys`, `/config/nginx/site-confs`, generates the persistent `/config/keys/quic_host.key`, and generates fallback TLS credentials when absent
- `init-docker-nginx-config`: symlinks missing config paths to immutable files under `/defaults/nginx/` while preserving regular-file overrides
- `init-docker-nginx-resolver`: generates a missing resolver snippet from `/etc/resolv.conf`
- `init-docker-nginx-geoipupdate`: validates GeoIPUpdate credentials, writes its runtime configuration, and bootstraps any missing configured database
- `init-docker-nginx-crowdsec`: generates the enabled CrowdSec runtime and nginx configuration
- `init-docker-nginx-permissions`: makes nginx configuration group-writable and sets root-mode ownership of `/config/**` to `abc:abc`
- `init-docker-nginx-validate`: validates the completed configuration with `nginx -t`
- `svc-docker-nginx`: execs nginx in the foreground with its PID under `/run`
- `svc-docker-nginx-geoipupdate`: skips a redundant refresh after synchronous bootstrap; otherwise refreshes immediately and then every 24 hours

### nginx config loading

The entrypoint is `/etc/nginx/nginx.conf`, which includes
`/config/nginx/nginx.conf`. The default main config includes:

- `/run/nginx/http.d/*.conf` — generated runtime http-context config blocks
- `/config/nginx/http.d/*.conf` — default symlinks, overrides, and custom http-context config blocks
- `/config/nginx/site-confs/*.conf` — virtual host/reverse proxy server blocks

## Key Conventions

### Snippet composition for server blocks

The `snippets/server-base.conf` is the canonical single include for HTTPS server blocks. It pulls in:

```
listen-https.conf  →  port 443 listen directives (including HTTP/2 & HTTP/3/QUIC)
hsts.conf          →  configurable Strict-Transport-Security header
geoip-block.conf   →  returns 403 if $access_allowed = no
no-robots.conf     →  X-Robots-Tag header
```

Use `proxy.conf` for upstream proxy locations — it includes `proxy-common.conf` and `static-assets.conf`. HTTPS upstream locations should also include `proxy-ssl-verify.conf` when their certificates chain to the system trust bundle.

### Site conf naming requirement

Files placed in `/config/nginx/site-confs/` must end in `.conf` to be picked up
by the nginx include glob.

### GeoIP environment variables

| Variable | Purpose |
|---|---|
| `GEOIPUPDATE_ACCOUNT_ID` | MaxMind account ID |
| `GEOIPUPDATE_LICENSE_KEY` | MaxMind license key |
| `GEOIPUPDATE_EDITION_IDS` | Database editions (default: `GeoLite2-Country`) |

`GEOIPUPDATE_ACCOUNT_ID`, `GEOIPUPDATE_LICENSE_KEY`, and `CROWDSEC_NGINX_API_KEY` support LinuxServer's `FILE__VARIABLE` convention (e.g., `FILE__GEOIPUPDATE_LICENSE_KEY=/run/secrets/maxmind_key`). `GEOIPUPDATE_EDITION_IDS` is a non-secret database selection setting.

Generated GeoIPUpdate and CrowdSec credential files live under `/run`; read-only deployments require writable `/config` plus tmpfs mounts for `/run:exec` and `/tmp`.

The LinuxServer base image supplies `PUID`, `PGID`, `TZ`, and `UMASK`. Explicit
non-root operation uses the container runtime's `user` setting and requires a
pre-writable `/config`; do not assume `PUID`/`PGID` change ownership in that
mode. LinuxServer does not generally support combining read-only and non-root
modes, but this image's integration suite tests its documented combined
hardening profile.

### Dockerfile

`Dockerfile` is used for both local and CI builds. CI builds a multi-platform
image for amd64 and arm64 via buildx; architecture-specific downloads select
their artifact and checksum from the target Alpine architecture. The base image
and Dockerfile frontend are pinned by digest. The Dockerfile cleans up default
`/var/www` content for all platforms.

### CI / Publishing

The expected workflow is local verification followed by a direct push to `main` on the authoritative Forgejo repository; GitHub is the CI and reporting mirror. Mirrored main pushes run ShellCheck, Hadolint, amd64 integration tests, and core smoke tests on native amd64 and arm64 runners before publishing. The weekly dependency-report workflow audits pins with Renovate, reports actionable source updates in one GitHub issue, and compares fresh amd64 and arm64 Alpine package inventories with `latest`; it never publishes or opens pull requests. `scripts/check-updates.sh --update` applies all available pin and checksum updates and bumps `APK_REFRESH_DATE` when floating Alpine packages changed, leaving a local diff for review. GeoIPUpdate and the CrowdSec bouncer are fixed and checksum-verified. GitHub Actions remain pinned to immutable commit SHAs. Published images are tagged as both `latest` and a source/run-specific rollback tag, with SBOM and provenance attestations attached.
