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
scripts/verify-image.sh
scripts/verify-integration.sh
```

There are no unit tests. `scripts/verify-image.sh` is the core smoke test after
Dockerfile or container-runtime changes. `scripts/verify-integration.sh` covers
the required external configuration contract, CrowdSec, TLS, HTTP/2, direct
nginx PID 1 operation, graceful shutdown, read-only mode, and arbitrary UIDs.
Its `contract`, `enabled`, and `nonroot` cases can be selected with
`TEST_CASES`; all run by default.

## Architecture

The image is based directly on the official Alpine image. It packages nginx,
the required Alpine dynamic modules, and the patched CrowdSec Lua bouncer.
There is no init system or entrypoint script: Docker starts nginx directly with
`daemon off`, nginx is PID 1, and the image stop signal is `SIGQUIT`.

The image contains no nginx defaults and performs no configuration generation.
A complete `/config/nginx/nginx.conf` must be mounted before startup. The image
never writes below `/config`; read-only deployments provide writable tmpfs
mounts for `/run:exec` and `/tmp`.

The health check requests `/health` over
`/run/nginx-healthcheck.sock`. External configuration must define that Unix
socket server. The default command explicitly uses
`/config/nginx/nginx.conf`, stderr logging, and `/run/nginx.pid`.

## Key Conventions

- nginx configuration, GeoIPUpdate scheduling, TLS/QUIC material, and CrowdSec
  runtime credentials are deployment responsibilities.
- The CrowdSec Lua library is installed below `/usr/local/lua/crowdsec`; its ban
  template is at `/var/lib/crowdsec/lua/templates/ban.html`.
- Keep the local CrowdSec patch strict (`--fuzz=0`) and release archive
  checksum verification intact.
- Preserve arbitrary-UID operation. Alpine resolves relative module paths
  through `/var/lib/nginx/modules`, so `/var/lib/nginx` must remain traversable.
- Keep nginx temporary files, the PID, caches, and health socket below `/tmp`
  or `/run`, never the image filesystem or `/config`.
- FastCGI and PHP remain unsupported.

## Dockerfile

`Dockerfile` is used for local and CI builds. The Dockerfile frontend and
official Alpine stable branch are pinned by digest. Alpine packages float
within that branch; `APK_REFRESH_DATE` records deliberate refreshes.
`lua-resty-string` is extracted without installing its OpenResty dependency,
so its package version remains explicitly tracked.

## CI and Publishing

The expected workflow is local verification followed by a direct push to
`main` on the authoritative Forgejo repository; GitHub is the CI and reporting
mirror. Mirrored pushes run ShellCheck, Hadolint, Actionlint, dependency-pin
checks, amd64 integration tests, and smoke tests on native amd64 and arm64
runners. Each runner tests the exact image digest it pushes; publishing combines
only verified digests.

The weekly dependency report tracks the Dockerfile frontend, official Alpine
base, CrowdSec bouncer, GitHub Actions, CI images, and fresh Alpine package
inventories. `scripts/check-updates.sh --update` resolves dependencies before
applying queued pin and checksum changes and leaves a local diff for review.
