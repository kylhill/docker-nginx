# docker-nginx
linuxserver.io Nginx (without PHP) inside Docker

Inspired by https://github.com/nginxinc/docker-nginx/blob/master/stable/alpine/Dockerfile

## Overview

This image packages nginx on top of the linuxserver Alpine base image and is intended to be used as a reverse proxy for self-hosted services.

At container start, the default nginx config tree from `/defaults/nginx/` is copied into `/config/nginx/` only when files do not already exist there. Shipped configs carry dated `## Version` headers; when an active config’s date differs from the shipped version, startup prints a reconciliation warning and leaves the user file unchanged.

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

`server-base.conf` already pulls in the shared HTTPS listen, SSL, GeoIP, and crawler policy snippets. Certificates are expected at `/config/keys/cert.crt` and `/config/keys/cert.key` by default.

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

## Common Paths

- `/config/nginx/nginx.conf`: main nginx entrypoint used by the container
- `/config/nginx/site-confs/`: place virtual hosts and reverse proxy server blocks here
- `/config/nginx/snippets/`: reusable shared config fragments
- `/config/keys/`: TLS certificates and private keys
- `/config/geoip/`: GeoIP database download location

The image creates `/config/keys/quic_host.key` on first startup and reuses it
across reloads and container replacements. Back it up with the rest of
`/config`; changing it invalidates previously issued QUIC validation tokens.

CrowdSec and GeoIPUpdate generate credential-bearing runtime configuration
under `/run` rather than the image filesystem. To run with a read-only root,
keep `/config` writable and provide tmpfs mounts for `/run:exec` and `/tmp`:

```yaml
read_only: true
tmpfs:
  - /run:exec
  - /tmp
```

An example Compose deployment is provided in `compose.example.yml`. Its port
bindings publish HTTPS on TCP 443 and HTTP/3 on UDP 443.

## Dependency Updates

The image follows the newest upstream LinuxServer Alpine tag and resolves current Alpine packages and Lua rocks during each fresh CI build. GeoIPUpdate and the CrowdSec nginx bouncer are fixed to reviewed versions and checksums in the Dockerfile. Published images include SBOM and provenance attestations, and source/run-specific tags provide rollback targets for scheduled rebuilds.

## Notes

- `geoipupdate` runs during container initialization when `GEOIPUPDATE_ACCOUNT_ID` and `GEOIPUPDATE_LICENSE_KEY` are set.
- `GEOIPUPDATE_ACCOUNT_ID`, `GEOIPUPDATE_LICENSE_KEY`, and `CROWDSEC_NGINX_API_KEY` support Docker `_FILE` secret variables. `GEOIPUPDATE_EDITION_IDS` is a non-secret database selection setting.
- The image exposes `80/tcp`, `443/tcp`, and `443/udp`. Publish both TCP and UDP port 443 to use HTTP/3/QUIC.
- Compression defaults include gzip, Brotli, and Zstandard modules.
