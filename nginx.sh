#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# nginx.sh — Create an NGINX reverse proxy with Let's Encrypt SSL
# Usage:
#   ./nginx.sh domain=example.com upstream=http://127.0.0.1:3000 \
#              [email=you@example.com] [upload=50m]
# ---------------------------------------------------------------------------

DOMAIN=""
UPSTREAM=""
EMAIL=""
UPLOAD="20m"   # client_max_body_size (request/upload limit)

usage() {
  echo "Usage: $0 domain=<domain> upstream=<upstream_url> [email=<email>] [upload=<size>]"
  echo "  upload=<size>  Max request/upload size (nginx syntax, e.g. 10m, 100M, 1g). Default: ${UPLOAD}"
}

# Parse key=value arguments
for arg in "$@"; do
  case "$arg" in
    domain=*)   DOMAIN="${arg#domain=}" ;;
    upstream=*) UPSTREAM="${arg#upstream=}" ;;
    email=*)    EMAIL="${arg#email=}" ;;
    upload=*)   UPLOAD="${arg#upload=}" ;;
    -h|--help)  usage; exit 0 ;;
    *)
      echo "Unknown argument: $arg"
      usage
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Must run as root (apt-get, /etc/nginx writes, systemctl all require it)
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root (try: sudo $0 ...)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate required args
# ---------------------------------------------------------------------------
if [[ -z "$DOMAIN" || -z "$UPSTREAM" ]]; then
  echo "Error: 'domain' and 'upstream' are required."
  usage
  exit 1
fi

# Validate domain (basic FQDN check; rejects junk that would break the config)
if [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
  echo "Error: '$DOMAIN' does not look like a valid domain name."
  exit 1
fi

# Validate upstream must be an http(s) URL
if [[ ! "$UPSTREAM" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "Error: upstream must be an http:// or https:// URL (got '$UPSTREAM')."
  exit 1
fi

# Validate upload size (digits + optional k/m/g unit)
if [[ ! "$UPLOAD" =~ ^[0-9]+[kKmMgG]?$ ]]; then
  echo "Error: upload must be a size like 10m, 100M or 1g (got '$UPLOAD')."
  exit 1
fi

# Default email for Let's Encrypt registration
if [[ -z "$EMAIL" ]]; then
  EMAIL="admin@${DOMAIN}"
  echo "WARNING: no email given; using '$EMAIL'. Expiry/renewal notices go there."
  echo "         Pass email=<you@example.com> to receive them at a real mailbox."
fi

CONF_PATH="/etc/nginx/sites-available/${DOMAIN}"
LINK_PATH="/etc/nginx/sites-enabled/${DOMAIN}"
UPGRADE_CONF="/etc/nginx/conf.d/proxy_upgrade.conf"
PROXY_SNIPPET="/etc/nginx/snippets/reverse_proxy.conf"

echo "==> Domain:   $DOMAIN"
echo "==> Upstream: $UPSTREAM"
echo "==> Email:    $EMAIL"
echo "==> Upload:   $UPLOAD"
echo ""

# ---------------------------------------------------------------------------
# 1. Install NGINX + Certbot (single apt update if anything is missing)
# ---------------------------------------------------------------------------
PKGS=()
command -v nginx   &>/dev/null || PKGS+=(nginx)
command -v certbot &>/dev/null || PKGS+=(certbot python3-certbot-nginx)

if [[ ${#PKGS[@]} -gt 0 ]]; then
  echo "==> Installing: ${PKGS[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${PKGS[@]}"
else
  echo "==> NGINX and Certbot already installed."
fi

# ---------------------------------------------------------------------------
# 2. DNS sanity check (non-fatal — certbot will hard-fail if this is wrong)
# ---------------------------------------------------------------------------
if command -v dig &>/dev/null; then
  RESOLVED="$(dig +short A "$DOMAIN" | tail -n1 || true)"
  if [[ -z "$RESOLVED" ]]; then
    echo "WARNING: '$DOMAIN' has no A record yet. Certbot will fail until DNS"
    echo "         points at this host. Continuing anyway..."
  else
    echo "==> $DOMAIN resolves to $RESOLVED"
  fi
fi

# ---------------------------------------------------------------------------
# 3. WebSocket upgrade map (only send Connection: upgrade when client asks)
# ---------------------------------------------------------------------------
if [[ ! -f "$UPGRADE_CONF" ]]; then
  echo "==> Writing WebSocket upgrade map to $UPGRADE_CONF..."
  cat > "$UPGRADE_CONF" <<'EOF'
# Maps Upgrade header so keepalive to upstream is preserved for normal requests
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
fi

# ---------------------------------------------------------------------------
# 3b. Shared reverse-proxy snippet (headers + timeouts), included by both the
#     HTTP bootstrap and the final HTTPS config so they can never drift.
#     Host-agnostic: proxy_pass stays in each server's location block.
# ---------------------------------------------------------------------------
echo "==> Writing reverse-proxy snippet to $PROXY_SNIPPET..."
mkdir -p "$(dirname "$PROXY_SNIPPET")"
cat > "$PROXY_SNIPPET" <<'EOF'
proxy_http_version  1.1;

# Forwarding headers — let the upstream see the real client and original request
proxy_set_header    Host              $host;
proxy_set_header    X-Real-IP         $remote_addr;
proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header    X-Forwarded-Proto $scheme;
proxy_set_header    X-Forwarded-Host  $host;
proxy_set_header    X-Forwarded-Port  $server_port;

# WebSocket / connection upgrade (see proxy_upgrade.conf map)
proxy_set_header    Upgrade           $http_upgrade;
proxy_set_header    Connection        $connection_upgrade;

# Timeouts — connect/send have sane bounds; read is long for WebSockets/SSE
proxy_connect_timeout 60s;
proxy_send_timeout    86400;
proxy_read_timeout    86400;

# Stream large uploads straight through instead of buffering to disk first
proxy_request_buffering off;
EOF

# ---------------------------------------------------------------------------
# 4. Write initial HTTP-only config (certbot needs it to pass ACME challenge)
# ---------------------------------------------------------------------------
echo "==> Writing initial NGINX config to $CONF_PATH..."

cat > "$CONF_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size ${UPLOAD};

    # Let's Encrypt ACME challenge (webroot)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass ${UPSTREAM};
        include    snippets/reverse_proxy.conf;
    }
}
EOF

# Enable the site
if [[ ! -L "$LINK_PATH" ]]; then
  ln -s "$CONF_PATH" "$LINK_PATH"
fi

# Remove default site if it exists (avoid port 80 conflict)
rm -f /etc/nginx/sites-enabled/default

# Create webroot for ACME challenge
mkdir -p /var/www/certbot

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 5. Obtain Let's Encrypt certificate (webroot — matches the config above)
# ---------------------------------------------------------------------------
echo "==> Obtaining Let's Encrypt certificate for $DOMAIN..."
certbot certonly \
  --webroot -w /var/www/certbot \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

# ---------------------------------------------------------------------------
# 6. Rewrite config with HTTPS + HTTP redirect
# ---------------------------------------------------------------------------
echo "==> Writing HTTPS NGINX config..."

cat > "$CONF_PATH" <<EOF
# Redirect HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS reverse proxy
server {
    # Combined form works on all nginx versions; newer ones (>=1.25.1) emit a
    # harmless deprecation warning. The standalone "http2 on;" only exists on
    # 1.25.1+, so avoid it for compatibility with older installs.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    client_max_body_size ${UPLOAD};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;

    # Modern SSL settings (ECDHE only — no DHE, so no dhparam needed)
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # OCSP stapling
    ssl_stapling        on;
    ssl_stapling_verify on;
    resolver            1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout    5s;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options           DENY always;
    add_header X-Content-Type-Options    nosniff always;

    location / {
        proxy_pass ${UPSTREAM};
        include    snippets/reverse_proxy.conf;
    }
}
EOF

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 7. Set up auto-renewal cron (certbot renew)
# ---------------------------------------------------------------------------
CRON_JOB="0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"
if ! crontab -l 2>/dev/null | grep -qF "certbot renew"; then
  (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
  echo "==> Auto-renewal cron job added."
else
  echo "==> Auto-renewal cron job already present."
fi

echo ""
echo "Done! https://${DOMAIN} now proxies to ${UPSTREAM} (max upload: ${UPLOAD})"
