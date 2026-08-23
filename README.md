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

## Dependency updates

The Dockerfile frontend, official Alpine base, CrowdSec bouncer, GitHub
Actions, and CI helper images are pinned. Alpine packages float within the
pinned stable branch; `APK_REFRESH_DATE` records intentional package refreshes.
`lua-resty-string` is extracted without its OpenResty dependency, so its Alpine
package version is tracked explicitly.

Check or apply dependency updates locally:

```bash
scripts/check-updates.sh --check
scripts/check-updates.sh --update
```

The weekly dependency report compares fresh amd64 and arm64 package inventories
with the published `latest` image. Publishing combines only platform digests
that passed their native smoke tests; amd64 also runs the integration suite.
