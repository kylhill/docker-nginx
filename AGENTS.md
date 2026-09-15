# Repository Agent Instructions

## Build Commands

```bash
# Build for local architecture
docker build -t docker-nginx .

# Build multi-platform (as CI does)
docker buildx build --platform linux/amd64,linux/arm64 -t docker-nginx .
```

The development host has no usable default Docker bridge network. Prefer
`--network host` for ad-hoc containers that need networking, and `--network none`
for offline checks. The integration suite's explicit, user-defined network is
separate; preserve it for container-to-container DNS and isolation.

## Verification

```bash
scripts/verify-image.sh
scripts/verify-integration.sh
```

`scripts/verify-image.sh` is the core smoke test after
Dockerfile or container-runtime changes. `scripts/verify-integration.sh` covers
the required external configuration contract, CrowdSec, TLS, HTTP/2, direct
nginx PID 1 operation, graceful shutdown, read-only mode, and arbitrary UIDs.
Its `contract`, `enabled`, and `nonroot` cases can be selected with
`TEST_CASES`; all run by default.

Test fixtures use separate per-run named volumes populated with `docker cp`
through stopped staging containers from `IMAGE`, without starting nginx.
Keep workload configuration mounts read-only and preserve fixture permissions.
No fixture paths need to be shared with the Docker daemon. Register created
volumes and staging containers for EXIT cleanup; remove all staging/workload
containers before volumes on both success and failure.

## Architecture

The image is based directly on the official Alpine image. It packages nginx,
the required Alpine dynamic modules, and the patched CrowdSec Lua bouncer.
There is no init system or entrypoint script: Docker starts nginx directly with
`daemon off`, nginx is PID 1, and the image stop signal is `SIGQUIT`.

The image contains no nginx defaults and performs no configuration generation.
A complete `/config/nginx/nginx.conf` must be mounted before startup. The image
never writes below `/config`; read-only deployments provide writable, noexec
tmpfs mounts for `/run` and `/tmp`.

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
official Alpine stable branch are pinned by digest. Direct Alpine packages are
version-pinned and managed by Renovate. `lua-resty-string` is extracted without
installing its OpenResty dependency.

## CI and Publishing

The expected workflow is local verification followed by a direct push to
`main` on the authoritative Forgejo repository; GitHub is the CI and reporting
mirror. Mirrored pushes run one GitHub job that builds both architectures,
smoke-tests amd64 natively, runs the integration suite on amd64, rebuilds and
publishes the multi-platform image to GHCR with `latest` and short-SHA tags,
then retains the newest 10 matching SHA releases.

Forgejo also runs a deliberately simpler single-job publishing workflow on the
`oci-build` runner. It requires a native arm64 Docker daemon, builds amd64 to a
cache-only output without loading or running it, smoke-tests arm64 natively,
runs the full integration suite on arm64, then rebuilds and pushes amd64/arm64
images to the registry with `latest` and short-SHA tags. It requires the
`REGISTRY_TOKEN` secret with `write:package` scope and package-owner write
permissions, Docker daemon access, and support for building both architectures
(preconfigured emulation for non-native builds).
The job uses the current Node.js LTS Alpine line and installs Bash, Docker CLI/Buildx, Git, OpenSSL,
and Python 3 with `sh` before checkout. API-based fixture copying supports
remote Docker daemons without shared filesystem paths.
Before creating Buildx, the job snapshots the runner's Docker endpoint and TLS
settings into a per-run Docker context and passes that context to the builder.
Keep context and builder names distinct: Buildx also exposes contexts as builders.
Cleanup removes only successfully created builders and contexts.
After publishing, retention keeps the newest 10 matching `sha-[a-f0-9]{12}`
tags, preserving `latest`, nonmatching tags/digests, and other packages.
Actual disk reclamation requires Forgejo server cleanup/GC, including dangling
container digests.

The weekly Forgejo Renovate workflow tracks the Dockerfile frontend, official
Alpine base, direct Alpine packages, the CrowdSec bouncer version and archive
checksum, and action references in GitHub and Forgejo workflows. CI helper
image digests are pinned and updated automatically. Pin actions to full commit
SHAs with version comments so Renovate can update them. Update the Forgejo
job's Node major only after the Node.js release feed marks that major as LTS.
