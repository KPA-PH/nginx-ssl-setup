# nginx-ssl-setup

A single, idempotent Bash script (`nginx.sh`) that turns a fresh Debian/Ubuntu
server into a **production-grade NGINX reverse proxy with a free Let's Encrypt
TLS certificate** — in one command.

Point a domain at your server, tell the script where your app is listening, and
it handles the rest: installing NGINX + Certbot, issuing the certificate,
writing a hardened HTTPS config, and setting up automatic certificate renewal.

---

## What it does

Given a domain and an upstream URL, the script:

1. **Installs** NGINX and Certbot (`certbot` + `python3-certbot-nginx`) if they
   aren't already present.
2. **Checks DNS** — warns (non-fatally) if the domain has no `A` record yet.
3. **Writes a WebSocket upgrade map** so WebSocket/SSE connections are proxied
   correctly while keepalive is preserved for normal requests.
4. **Writes a shared reverse-proxy snippet** (forwarding headers + timeouts +
   upload streaming) that both the HTTP and HTTPS server blocks include, so the
   two configs can never drift out of sync.
5. **Issues a Let's Encrypt certificate** using the webroot ACME challenge.
6. **Writes the final config**: HTTP → HTTPS redirect plus a hardened HTTPS
   reverse proxy (TLS 1.2/1.3, OCSP stapling, HSTS, modern ciphers).
7. **Schedules auto-renewal** via a daily `certbot renew` cron job that reloads
   NGINX after a successful renewal.

The script is **idempotent** — running it again for the same domain re-applies
the config and renews the certificate without creating duplicates.

---

## Requirements

- **OS:** Debian or Ubuntu (uses `apt-get`, `systemctl`, and `/etc/nginx/sites-*`).
- **Privileges:** must run as **root** (installs packages, writes to
  `/etc/nginx`, reloads the service).
- **DNS:** the domain's `A`/`AAAA` record must point at this server's public IP
  **before** running (Let's Encrypt validates by reaching the domain over HTTP).
- **Ports:** **80** and **443** must be open and free (the script removes the
  default NGINX site to avoid a port-80 conflict).
- A running **upstream application** for NGINX to proxy to (e.g. a Node, Python,
  or Go app listening on `127.0.0.1:3000`).

---

## Usage

```bash
sudo ./nginx.sh domain=<domain> upstream=<upstream_url> [email=<email>] [upload=<size>]
```

### Arguments

| Argument   | Required | Default            | Description |
|------------|----------|--------------------|-------------|
| `domain`   | **Yes**  | —                  | Fully-qualified domain name to serve (e.g. `app.example.com`). Validated as a real FQDN. |
| `upstream` | **Yes**  | —                  | Where NGINX forwards traffic. Must be an `http://` or `https://` URL (e.g. `http://127.0.0.1:3000`). |
| `email`    | No       | `admin@<domain>`   | Email for Let's Encrypt registration and expiry/renewal notices. **Strongly recommended** — set a real mailbox so you're warned before a cert expires. |
| `upload`   | No       | `20m`              | Max request/upload size (`client_max_body_size`). NGINX size syntax: `10m`, `100M`, `1g`. |

Arguments use `key=value` form and may appear in any order. Use `-h` / `--help`
to print usage.

### Examples

Minimal — proxy a local app on port 3000:

```bash
sudo ./nginx.sh domain=app.example.com upstream=http://127.0.0.1:3000
```

With a real notification email and a larger upload limit:

```bash
sudo ./nginx.sh \
  domain=app.example.com \
  upstream=http://127.0.0.1:8080 \
  email=you@example.com \
  upload=100m
```

Proxy to an upstream that itself speaks HTTPS:

```bash
sudo ./nginx.sh domain=api.example.com upstream=https://10.0.0.5:8443
```

### First run

```bash
git clone <this-repo> && cd nginx-ssl-setup
chmod +x nginx.sh
sudo ./nginx.sh domain=app.example.com upstream=http://127.0.0.1:3000 email=you@example.com
```

When it finishes you'll see:

```
Done! https://app.example.com now proxies to http://127.0.0.1:3000 (max upload: 20m)
```

---

## Production behavior in detail

### TLS / SSL hardening

- **Protocols:** TLS 1.2 and TLS 1.3 only.
- **Ciphers:** ECDHE-only (forward secrecy; no DHE, so no `dhparam` file needed).
- **OCSP stapling** enabled and verified, using Cloudflare/Google resolvers.
- **Session resumption** via shared cache; session tickets disabled.
- **HSTS:** `max-age=63072000; includeSubDomains` — browsers force HTTPS for two
  years. ⚠️ `includeSubDomains` applies to **all** subdomains; don't use this on
  an apex domain whose subdomains aren't all HTTPS-ready.
- **Extra headers:** `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`.

### Forwarding headers (so your app sees the real client)

The shared snippet at `/etc/nginx/snippets/reverse_proxy.conf` sends:

| Header              | Value                       | Purpose |
|---------------------|-----------------------------|---------|
| `Host`              | `$host`                     | Original requested host |
| `X-Real-IP`         | `$remote_addr`              | Client IP |
| `X-Forwarded-For`   | `$proxy_add_x_forwarded_for`| Client IP chain |
| `X-Forwarded-Proto` | `$scheme`                   | `http` or `https` (so the app knows it's behind TLS) |
| `X-Forwarded-Host`  | `$host`                     | Original host for absolute-URL generation |
| `X-Forwarded-Port`  | `$server_port`              | Original port |

> Make sure your framework **trusts these proxy headers** (e.g. `trust proxy` in
> Express, `ProxyFix` in Flask, `ForwardedHeaders` in ASP.NET). Otherwise the app
> may log NGINX's IP or build `http://` URLs.

### Timeouts

| Directive               | Value    | Why |
|-------------------------|----------|-----|
| `proxy_connect_timeout` | `60s`    | Bound on how long to wait for the upstream to accept the connection. |
| `proxy_send_timeout`    | `86400`  | Long, to support slow/large request bodies and long-lived streams. |
| `proxy_read_timeout`    | `86400`  | 24h — keeps **WebSockets / Server-Sent Events** alive. |

> **Trade-off:** the long 24-hour read timeout applies to every route. A hung
> upstream can therefore hold a worker connection for up to 24h. This is a
> deliberate choice to support WebSockets without a separate location block. If
> you don't use WebSockets/SSE, you can lower `proxy_read_timeout` in the snippet.

### Uploads

- `client_max_body_size` is set from `upload=` (default `20m`).
- `proxy_request_buffering off` streams large uploads straight to the upstream
  instead of buffering the whole body to disk first.

### WebSockets / SSE

Handled automatically via the `$connection_upgrade` map — no extra flags needed.
`Upgrade` and `Connection` headers are forwarded only when the client requests
an upgrade.

### Certificate auto-renewal

A cron job is installed:

```cron
0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'
```

It runs daily at 03:00; Certbot only renews certs within 30 days of expiry, then
reloads NGINX. (On modern Debian/Ubuntu, Certbot also ships a `systemd` timer
that renews independently — both are harmless.)

---

## Files the script creates / modifies

| Path | Purpose |
|------|---------|
| `/etc/nginx/sites-available/<domain>` | The site's server config (HTTP→HTTPS + HTTPS proxy). |
| `/etc/nginx/sites-enabled/<domain>`   | Symlink enabling the site. |
| `/etc/nginx/conf.d/proxy_upgrade.conf`| WebSocket upgrade `map` (written once). |
| `/etc/nginx/snippets/reverse_proxy.conf` | Shared forwarding headers + timeouts. |
| `/var/www/certbot/`                   | Webroot for ACME HTTP-01 challenges. |
| `/etc/letsencrypt/live/<domain>/`     | Issued certificate and key (managed by Certbot). |
| `/etc/nginx/sites-enabled/default`    | **Removed** to free port 80. |
| root crontab                          | Daily renewal job (added once). |

---

## Verifying the result

```bash
# Test the config and check the running service
sudo nginx -t
systemctl status nginx

# Confirm HTTPS works and HTTP redirects
curl -I https://app.example.com
curl -I http://app.example.com        # expect 301 → https

# Inspect the certificate
sudo certbot certificates

# Dry-run a renewal
sudo certbot renew --dry-run
```

---

## Updating settings later

Re-run the script with new values to change the upstream or upload limit:

```bash
sudo ./nginx.sh domain=app.example.com upstream=http://127.0.0.1:4000 upload=200m
```

To tune proxy headers or timeouts for **all** sites at once, edit
`/etc/nginx/snippets/reverse_proxy.conf`, then `sudo nginx -t && sudo systemctl reload nginx`.
(Note: re-running the script rewrites this snippet.)

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `must be run as root` | Prefix with `sudo`. |
| `does not look like a valid domain name` | Pass a full FQDN, e.g. `app.example.com`, not a bare hostname or URL. |
| `upstream must be an http:// or https:// URL` | Include the scheme: `upstream=http://127.0.0.1:3000`. |
| Certbot fails to issue | DNS `A` record isn't pointing at this server yet, or port 80 is blocked/firewalled. Fix DNS/firewall and re-run. |
| `WARNING: '<domain>' has no A record yet` | DNS hasn't propagated. Wait, then re-run. |
| `502 Bad Gateway` | The upstream app isn't running or isn't listening on the URL you gave. |
| Cert near expiry / no renewal | Check `sudo certbot renew --dry-run` and that the cron job exists (`crontab -l`). |

---

## Notes & limitations

- Targets **Debian/Ubuntu** with `apt`. Not intended for RHEL/Alpine/macOS as-is.
- Issues a certificate for the **single** domain passed. To cover `www` or
  multiple hostnames, extend the `certbot ... -d` line and `server_name`.
- Run on a host you control with ports 80/443 reachable from the public internet
  (Let's Encrypt must reach the domain to validate it).
