# docker-nginx
linuxserver.io Nginx (without PHP) inside Docker

Inspired by https://github.com/nginxinc/docker-nginx/blob/master/stable/alpine/Dockerfile

## Overview

This image packages nginx on top of the linuxserver Alpine base image and is intended to be used as a reverse proxy for self-hosted services.

At container start, the default nginx config tree from `/defaults/nginx/` is
copied into `/config/nginx/` only when active files do not already exist. The
current shipped version of every config is refreshed alongside the active file
as `<name>.conf.sample`. Exact active/sample matches are then removed, so a
sample remains only when the persisted active config differs from the image
default. Shipped configs carry dated `## Version` headers; when an active
config's date differs from its sample, startup prints a reconciliation warning
and leaves the active file unchanged. Compare the two files in the host-mounted
`/config` directory and apply changes manually. Remaining `.conf.sample` files
are image-managed and refreshed on every startup.
The active resolver snippet is regenerated at `/run/nginx/resolver.conf` from
the nameservers in the container's `/etc/resolv.conf` on every start. To use a
persistent custom resolver, create
`/config/nginx/snippets/resolver-override.conf`.

## Reverse Proxy Example

Create a server block such as `/config/nginx/site-confs/app.subdomain.conf`:

```nginx
server {
	server_name app.example.internal;

	include /config/nginx/snippets/server-base.conf;

	location / {
		proxy_pass http://192.168.1.50:8080;
		include /config/nginx/snippets/proxy.conf;
	}
}
```

`server-base.conf` already pulls in the shared HTTPS listen, SSL, GeoIP, and
crawler policy snippets. On first startup, the image generates a self-signed
certificate at `/config/keys/cert.crt` with its key at
`/config/keys/cert.key`. Replace them with your trusted certificate and key.

The catch-all server owns the `reuseport` socket option once for each IPv4 and
IPv6 HTTPS and QUIC socket. Do not repeat `reuseport` in individual virtual
hosts.
`quic_gso` is enabled by default and requires Linux `UDP_SEGMENT` support from
the deployment host and network interface. Set it to `off` in
`/config/nginx/nginx.conf` on an environment that does not provide that feature.

If you also want plain HTTP to redirect to HTTPS, add a second server block such as `/config/nginx/http.d/redirect-http.conf`:

```nginx
server {
	listen 80;
	listen [::]:80;
	server_name app.example.internal;

	return 301 https://$host$request_uri;
}
```

Adjust or remove those shared includes in `/config/nginx/snippets/` to fit your environment.

### HTTPS upstreams

nginx does not enable upstream certificate verification or SNI by default. For
an HTTPS upstream with a certificate trusted by the system CA bundle, include
the verification policy in that location:

```nginx
location / {
	proxy_pass https://app.example.internal:8443;
	include /config/nginx/snippets/proxy.conf;
	include /config/nginx/snippets/proxy-ssl-verify.conf;
}
```

If `proxy_pass` uses an upstream group or a name different from the certificate
identity, also set `proxy_ssl_name` to the certificate's DNS name. Do not use
the verification snippet for a self-signed upstream until its CA has been
added to the container trust bundle.

### Response headers and trusted proxies

`server-base.conf` enables `X-Content-Type-Options: nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin`, HSTS, and HTTP/3 `Alt-Svc`.
The first two policies are generally safe for reverse-proxied applications,
but `nosniff` can expose an application that serves scripts or stylesheets with
an incorrect MIME type. Test applications after enabling a changed policy.

HSTS is isolated in `/config/nginx/snippets/hsts.conf`. Comment out its
`add_header` directive for internal names, self-signed certificates, or any
deployment where clients may need to return to HTTP. Browsers retain HSTS for
the advertised lifetime, so disabling it server-side does not immediately
clear previously cached policy.

nginx normally inherits parent-level `add_header` directives only when the
child context defines none. The shipped security policy uses
`add_header_inherit merge` so shared server headers remain present when a
location adds its own headers. A location can explicitly use
`add_header_inherit off` when it must replace the inherited policy.

When another reverse proxy or CDN connects to this nginx instance, declare
only that proxy's addresses as trusted, for example:

```nginx
set_real_ip_from 10.20.0.0/24;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

Place real-IP directives in an `http.d/*.conf` file. Never trust an arbitrary
client network or the entire Internet: clients that can connect directly could
otherwise forge their source address and bypass address-based controls.

## Common Paths

- `/config/nginx/nginx.conf`: main nginx entrypoint used by the container
- `/config/nginx/site-confs/`: place virtual hosts and reverse proxy server blocks here
- `/config/nginx/snippets/`: reusable shared config fragments
- `/config/keys/`: TLS certificates and private keys
- `/config/geoip/`: GeoIP database download location

The image creates `/config/keys/quic_host.key` on first startup and reuses it
across reloads and container replacements. Back it up with the rest of
`/config`; changing it invalidates previously issued QUIC validation tokens.

CrowdSec, GeoIPUpdate, and the generated nginx resolver configuration live
under `/run` rather than the persistent config or image filesystem. To run with
a read-only root, keep `/config` writable and provide tmpfs mounts for
`/run:exec` and `/tmp`:

```yaml
read_only: true
tmpfs:
  - /run:exec
  - /tmp
```

An example Compose deployment is provided in `compose.example.yml`. Its port
bindings publish HTTPS on TCP 443 and HTTP/3 on UDP 443.

The image inherits LinuxServer's `PUID`, `PGID`, `TZ`, and `UMASK` environment
variables. `PUID` and `PGID` control the `abc` account when the container starts
as root. For LinuxServer's non-root mode, set Compose `user: "1000:1000"`
instead; the mounted `/config` tree must already be writable by that UID/GID.
LinuxServer does not support combining its read-only and non-root modes in the
general case. This image's integration suite exercises that specific combined
profile, but upstream base-image changes may still require additional care.
The container runtime must also permit the selected UID to bind ports 80 and
443 (for example through an unprivileged-port sysctl or the appropriate
capability).

## Resource and performance tuning

The default proxy response buffers total 1 MiB per active buffered request
(`16 64k`). This is intentionally larger than LinuxServer SWAG's `32 4k`
default to reduce temporary-file writes for larger homelab assets. Those
buffers consume memory per concurrent request, so reduce them in
`snippets/proxy-common.conf` on busy or memory-constrained deployments. The
separate client request-body buffer is 128 KiB; upload locations should use
`proxy-upload.conf`, which disables request buffering.

The standard `proxy.conf` and `proxy-no-cache.conf` policies retain
LinuxServer's 240-second read/send timeout. Long uploads, streams, and
WebSockets use explicitly scoped longer-timeout snippets. Use a shorter custom
snippet for latency-sensitive APIs rather than changing streaming behavior
globally.

The static asset cache defaults to a 1 GiB maximum under `/tmp`. Change
`max_size` or disable the cache in `/config/nginx/http.d/proxy-cache.conf`.
Gzip, Brotli, and Zstandard are independently controlled by their files under
`/config/nginx/http.d/`; set an algorithm to `off` or remove its active config
to disable it.

Container limits are deployment policy rather than image defaults. For
Compose, start with measured limits and adjust from observed peak usage:

```yaml
cpus: 2.0
mem_limit: 1g
```

The image health check uses an unlogged Unix-socket request every 5 minutes.
It exercises nginx request handling without opening another port. Docker marks
the container unhealthy after three consecutive failures but does not restart
it solely because it is unhealthy; use your orchestrator or monitoring policy
for remediation.

## Dependency Updates

The image follows the newest upstream LinuxServer Alpine tag and resolves
current Alpine packages during each fresh CI build. GeoIPUpdate and the
CrowdSec nginx bouncer are fixed to reviewed versions in the Dockerfile;
downloaded release archives are checksum-verified. Published images include
SBOM and provenance attestations, and source/run-specific tags provide rollback
targets for scheduled rebuilds.

Run `scripts/check-updates.sh` to verify pinned release checksums and report
new GeoIPUpdate or CrowdSec bouncer releases. Run
`scripts/check-updates.sh --update` to update the Dockerfile versions,
checksums, and matching integration-test expectation; review the resulting
diff and run the full verification suite before publishing.

## Notes

- `geoipupdate` runs during the s6 initialization chain when `GEOIPUPDATE_ACCOUNT_ID` and `GEOIPUPDATE_LICENSE_KEY` are set.
- CrowdSec writes its generated nginx include to `/run/nginx/http.d/crowdsec.conf`.
- `GEOIPUPDATE_ACCOUNT_ID`, `GEOIPUPDATE_LICENSE_KEY`, and
  `CROWDSEC_NGINX_API_KEY` accept direct values or LinuxServer's standard
  `FILE__VARIABLE=/run/secrets/file` form.
- CrowdSec requires both `CROWDSEC_NGINX_API_KEY` and `CROWDSEC_LAPI_URL` when
  any CrowdSec setting is present. GeoIPUpdate likewise requires both its
  account ID and license key. Partial feature configuration stops startup.
- Enabled site files must end in `.subdomain.conf`; startup warns about other files in `/config/nginx/site-confs/` because nginx ignores them.
- FastCGI and PHP are unsupported. The image does not ship PHP-FPM or the
  LinuxServer FastCGI parameter customizations; use a separate application
  container behind HTTP or HTTPS instead.
- The image exposes `80/tcp`, `443/tcp`, and `443/udp`. Publish both TCP and UDP port 443 to use HTTP/3/QUIC.
- Compression defaults include gzip, Brotli, and Zstandard modules.
