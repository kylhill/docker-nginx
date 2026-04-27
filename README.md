# docker-nginx
linuxserver.io Nginx (without PHP) inside Docker

Inspired by https://github.com/nginxinc/docker-nginx/blob/master/stable/alpine/Dockerfile

## Overview

This image packages nginx on top of the linuxserver Alpine base image and is intended to be used as a reverse proxy for self-hosted services.

At container start, the default nginx config tree from `/defaults/nginx/` is copied into `/config/nginx/` if files do not already exist there. That lets you keep persistent config under `/config` while still receiving sane defaults on first boot.

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
- `/config/log/nginx/`: access and error logs
- `/config/geoip/`: GeoIP database download location

## Notes

- `geoipupdate` runs during container initialization when `GEOIPUPDATE_ACCOUNT_ID` and `GEOIPUPDATE_LICENSE_KEY` are set.
- The image exposes ports `80` and `443`.
- Compression defaults include gzip, Brotli, and Zstandard modules.
