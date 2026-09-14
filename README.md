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

Build for the local architecture:

```bash
docker build -t docker-nginx .
```

Build as CI does:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t docker-nginx .
```

The development host does not provide a usable default Docker bridge network.
Use `--network host` for ad-hoc containers that need network access, or
`--network none` for offline checks. The integration suite uses its own explicit
network and should retain that configuration.

Run the smoke and integration suites:

```bash
scripts/verify-image.sh
scripts/verify-integration.sh
```

The smoke test builds the image and runs the integration suite's `contract`
case against the basic example configuration. It waits for health, validates
nginx and the CrowdSec Lua dependencies, confirms nginx is PID 1, and checks
graceful shutdown. The full integration suite additionally covers CrowdSec
enforcement, TLS/HTTP/2, and read-only arbitrary-UID mode.
Select cases with `TEST_CASES=contract`, `TEST_CASES=enabled`, or
`TEST_CASES=nonroot`.

Fixtures are copied through the Docker API (`docker cp`) into separate,
per-run named volumes using stopped staging containers from the test image.
Workloads mount those volumes read-only. Local and remote Docker daemons use
the same transfer path; no shared job/daemon filesystem is required. Exit
cleanup removes staging and workload containers before removing fixture volumes,
including when verification fails.

## Forgejo publishing

The Forgejo `docker-publish.yml` workflow runs on relevant pushes to `main` or
manual dispatch. A single `oci-build` job requires a native arm64 Docker daemon
and builds both architectures, but never loads or runs the amd64 image. It
smoke-tests arm64 natively, runs the full integration suite on arm64, then
builds and pushes
`linux/amd64,linux/arm64` images to
`git.tacomafia.net/<owner>/<repository>` with `latest` and `sha-<12-character SHA>`
tags. After successful publishing, retention keeps the newest 10 matching
`sha-[a-f0-9]{12}` tags for the lowercase repository image, preserving `latest`,
all nonmatching tags/digests, and other packages. Cleanup errors fail the job.
Actual disk reclamation depends on Forgejo server cleanup/garbage collection,
including removal of dangling container digests.

The job explicitly uses the current Node.js LTS Alpine line, providing Node.js
for `actions/checkout`. Before checkout, a `sh` step installs Bash, Docker CLI
and Buildx, Git, OpenSSL, and Python 3. The runner must provide Docker daemon
access and support for building both architectures (including preconfigured
QEMU/binfmt emulation for non-native builds). Test fixtures are transferred
through the Docker API, not host bind mounts.
The job creates a per-run Docker context from the runner's connection settings,
including TLS certificates, and passes it explicitly to Buildx. The builder and
context are removed afterward only if their creation succeeded.
Set the repository's `REGISTRY_TOKEN` Actions secret to
a token with `write:package` scope and write permissions for the package owner.

Run the offline retention tests with
`python3 -m unittest discover -s tests`.

This deliberately simpler workflow rebuilds for publishing after arm64 passes
its native smoke and integration tests. GitHub provides the complementary
native amd64 smoke and integration coverage while only building arm64. After
publishing, each registry retains its newest 10 short-SHA releases.

## Dependency updates

The Dockerfile frontend, official Alpine base, direct Alpine packages, and
CrowdSec bouncer archive are pinned. Renovate runs weekly on the authoritative
Forgejo repository and opens pull requests for Dockerfile dependency updates.
The Alpine base and package pins are grouped so a stable-branch transition is
applied atomically. Actions in GitHub and Forgejo workflows are pinned to commit
SHAs with version comments, allowing Renovate to update them safely. Renovate
also updates pinned CI helper image digests. The Forgejo job's Node major is
updated only when the Node.js release feed marks a newer major as LTS.

`lua-resty-string` is extracted without its OpenResty dependency, so its Alpine
package is pinned and updated with the other direct APK dependencies. The
CrowdSec release version and archive checksum are updated together. Its custom
manager adds the upstream `v` prefix for release/digest lookups and removes it
when writing the Dockerfile version; digest lookups require the exact release
tag, not an extracted numeric version.
