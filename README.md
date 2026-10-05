# docker-nginx

An Alpine Linux nginx runtime for reverse-proxy deployments. The image bundles
nginx, Brotli, Zstandard, GeoIP2, Lua, and the patched CrowdSec nginx bouncer.
It does not contain an init system, a configuration generator, GeoIPUpdate, or
default site configuration.

## Runtime contract

The container runs nginx directly as PID 1:

```text
nginx -c /config/nginx/nginx.conf -e stderr -g "daemon off; pid /run/nginx.pid;"
```

A complete configuration must be mounted at `/config`; at minimum,
`/config/nginx/nginx.conf` must exist and be readable. Missing or invalid
configuration makes the container exit immediately. The image never creates
or modifies files below `/config`.

Use writable tmpfs mounts for `/run` and `/tmp` when the root filesystem is
read-only. The main nginx configuration must direct its PID, temporary files,
cache files, and Unix sockets to those writable paths.
Neither tmpfs requires executable permissions.

The image uses `SIGQUIT` as its Docker stop signal for graceful nginx shutdown.
Send `SIGHUP` to the container to reload a validated configuration.

## Health check

The image health check requests `/health` through
`/run/nginx-healthcheck.sock`. The external nginx configuration must define a
matching server. The supported basic example provides the canonical
[`healthcheck.conf`](examples/basic/config/nginx/http.d/healthcheck.conf).

## CrowdSec

The patched CrowdSec Lua library is installed below `/usr/local/lua/crowdsec`
and its ban template is installed at
`/var/lib/crowdsec/lua/templates/ban.html`. Deployments must provide both the
nginx HTTP-context Lua configuration and the bouncer configuration containing
the LAPI credentials. The image does not read CrowdSec environment variables
or generate credential files.

The local patch intentionally permits an empty captcha provider and logs AppSec
enablement at info level instead of error level. Release downloads remain
versioned and checksum-verified.

## GeoIP databases

The nginx GeoIP2 module is included, but database acquisition and refresh are
deployment responsibilities. Mount the resulting MMDB files read-only as part
of `/config` or through another deployment-specific path.

## Compose example

[`examples/basic`](examples/basic) is a complete, copy-ready configuration for
the supported hardened runtime. It listens on container port 8080 and publishes
it as host port 80. Start it from the example directory:

```bash
cd examples/basic
docker compose up -d
```

The selected UID/GID must be able to read the configuration. The root
filesystem and configuration are read-only; writable tmpfs mounts provide the
runtime paths used by nginx.

## Build and verification

Build once and run the full native suite:

```bash
scripts/verify-image.sh
```

For a focused smoke check, use `TEST_CASES=contract scripts/verify-image.sh`.
Run offline script checks with `scripts/verify-static.sh`.
The build wrapper requires Docker Buildx and accepts `IMAGE` (default
`docker-nginx:verify`), `PLATFORM` (one platform), `DOCKERFILE`, `BUILD_CONTEXT`,
`BUILD_NETWORK`, and `TEST_CASES`. Builds default to host networking for the
development daemon; set `BUILD_NETWORK=default` for a builder with a working
bridge network. Without `PLATFORM`, builds target the native architecture.

The integration script never builds and defaults to all runtime cases. Use it
directly to test an existing image, optionally selecting cases:

```bash
IMAGE=docker-nginx:verify TEST_CASES=nonroot scripts/verify-integration.sh
```

Reuse an image only while its Dockerfile, patch, and dependency inputs remain
unchanged. After a focused smoke run, use
`TEST_CASES=enabled,nonroot scripts/verify-integration.sh` to finish coverage.

The cases are `contract` (missing/invalid configuration, health, PID 1, Lua
modules, and graceful shutdown), `enabled` (CrowdSec and TLS/HTTP/2), and
`nonroot` (read-only arbitrary UID/GID operation and successful reload).
The `contract` case always loads the required Lua dependencies.
`TEST_UID` and `TEST_GID` select the arbitrary identity (defaults 12345:23456).
`WAIT_TIMEOUT` sets readiness/exit deadlines in seconds (default 30), and
`CURL_TIMEOUT` bounds each request (default 3).

The development host has no usable default Docker bridge network. Use
`--network host` for ad-hoc containers that need networking and `--network none`
for offline checks. Preserve the integration suite's explicit network.
Multi-platform build/export details live in [CI and publishing](docs/ci.md);
local runtime checks use one loaded native image.

Fixtures are copied through the Docker API (`docker cp`) into separate,
per-run named volumes using stopped staging containers from the test image.
Workloads mount those volumes read-only. Local and remote Docker daemons use
the same transfer path; no shared job/daemon filesystem is required. Exit
cleanup removes staging and workload containers before removing fixture volumes,
including when verification fails.
Test-only ports, credentials, and response values live in
[`features.env`](tests/fixtures/features.env), shared by fixture rendering and
assertions. Lua search paths are shared by the smoke and CrowdSec fixtures.

## CI and publishing

Forgejo is the authoritative repository; GitHub is the CI and reporting mirror.
Both publish manifests from already-built platform digests after native runtime
verification. See [CI and publishing](docs/ci.md) for runner requirements, cache
isolation, credentials, and retention.

## Dependency updates

The Dockerfile frontend, official Alpine base, direct Alpine packages, and
CrowdSec bouncer archive are pinned. Renovate runs weekly on the authoritative
Forgejo repository and opens pull requests for Dockerfile dependency updates.
The Alpine base and package pins are grouped so a stable-branch transition is
applied atomically. Actions in GitHub and Forgejo workflows are pinned to commit
SHAs with version comments, allowing Renovate to update them safely. Renovate
also updates pinned CI helper image digests. The standard GitHub Actions manager
updates the Forgejo job's Node container tag and digest, including major updates.

`lua-resty-string` is extracted without its OpenResty dependency, so its Alpine
package is pinned and updated with the other direct APK dependencies. The
CrowdSec release version and archive checksum are updated together. The Dockerfile stores
the exact upstream release tag, including its `v` prefix, so Renovate uses it
directly for release and checksum lookups. The image version label uses that
tag; `bouncer_version.lua` retains the numeric version expected by deployments.

Routine digest refreshes use `group:allDigest`. The explicit Alpine group
keeps coupled dependencies together. Native Dockerfile extraction manages
literal `apk add` version pins; a small custom matcher handles the separately
downloaded `lua-resty-string` archive. The Renovate workflow uses an image with native APK extraction support.

The APK registry rule must match the Alpine base branch. When upgrading that
branch, update its registry URL and package pins together, including nginx and
its dynamic modules, and verify both image architectures. For Node major
updates, verify that the image digest matches the new tag. No post-upgrade
synchronization script runs. CrowdSec updates require the selected release's
checksum; an unresolved checksum remains empty so build verification fails
rather than using the previous release's checksum.
