# Repository Agent Instructions

## Validation loop

Use the scripts as the canonical entry points; do not build manually first.

```bash
scripts/verify-static.sh                                  # offline checks
scripts/verify-image.sh                                   # build + smoke
TEST_CASES=contract,enabled,nonroot scripts/verify-image.sh # build + full suite
```

| Changed inputs | Required checks |
| --- | --- |
| Guidance/prose only | Review the diff and `git diff --check`; no Docker build |
| Test scripts | `scripts/verify-static.sh` and affected runtime cases |
| Fixtures/example config | Affected runtime cases against a current image |
| Dockerfile/packages/CrowdSec patch | Build once and run the full native suite |
| Architecture-sensitive dependencies | Both architecture builds and native runtime coverage through CI |
| CI workflows | Offline checks and review platform, cache, export, and cleanup behavior; CI verifies runner-specific execution |

`verify-image.sh` defaults to `TEST_CASES=contract` and image
`docker-nginx:verify`. It accepts `IMAGE`, `SKIP_BUILD=1`, `PLATFORM` (one
platform), `DOCKERFILE`, `BUILD_CONTEXT`, and `BUILD_NETWORK` (default `host`
for this development daemon; use `default` for builders with a working bridge).
`verify-integration.sh` never
builds and defaults to all cases. Both enable Lua dependency checks for the
contract case. Reuse an image only while its build inputs remain unchanged.
After smoke passes, use `TEST_CASES=enabled,nonroot scripts/verify-integration.sh`
to complete coverage without repeating the contract case.

Run affected cases during iteration and the required coverage once after the
final relevant edit. Repeat passed checks only after relevant input changes or
when a failure leaves a concern unresolved. Report what ran and any checks
that could not run. No repository-specific skill is needed for this loop.

The development host has no usable default Docker bridge network. Prefer
`--network host` for ad-hoc containers that need networking and `--network none`
for offline checks. Preserve the integration suite's explicit network.

Test fixtures use separate per-run named volumes populated with `docker cp`
through stopped staging containers from `IMAGE`, without starting nginx.
Keep workload configuration mounts read-only and preserve fixture permissions.
No fixture paths need to be shared with the Docker daemon. Register created
volumes and staging containers for EXIT cleanup; remove all staging/workload
containers before volumes on both success and failure.
Keep public runtime contract paths explicit in assertions. Put test-only feature
values in `tests/fixtures/features.env` and render templates from those values;
avoid duplicating ports, credentials, and response text in shell assertions.
Prefer observable behavior over nginx log wording or upstream source line numbers.

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
`main` on authoritative Forgejo; GitHub is the CI and reporting mirror.
GitHub tests amd64 natively; Forgejo tests arm64 natively. Both publish tagged
manifests from the already-built platform digests.

See [CI and publishing](docs/ci.md) for runner requirements and registry
retention. Keep PR and credentialed publishing cache/state isolated. Forgejo
uses separate persistent builders with fixed names and `--keep-state` cleanup;
the runner must serialize jobs using those names. Keep ephemeral context names
distinct from builder names and clean up only successfully created resources.
Use the persistent builder state as the sole Forgejo build cache; do not add
local or registry cache exports. Forgejo retention uses the package owner's
built-in cleanup rule documented in `docs/ci.md`; GitHub retention runs in CI.

The weekly Forgejo Renovate workflow tracks the Dockerfile frontend, official
Alpine base, direct Alpine packages, the CrowdSec bouncer version and archive
checksum, and action references in GitHub and Forgejo workflows. CI helper
image digests are pinned and updated automatically. Pin actions to full commit
SHAs with version comments so Renovate can update them. Renovate updates the Forgejo
job's Node container tag and digest through the standard GitHub Actions manager.
