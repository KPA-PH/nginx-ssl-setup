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

# DNS names are case-insensitive, but Linux paths are not. Keeping the domain
# lowercase prevents certificate/config paths such as CatPriceLab.com and
# catpricelab.com from drifting apart.
DOMAIN="${DOMAIN,,}"

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

# Use /etc/nginx/conf.d/ for nginx.org packages (official nginx repo)
CONF_PATH="/etc/nginx/conf.d/${DOMAIN}.conf"
UPGRADE_CONF="/etc/nginx/conf.d/proxy_upgrade.conf"
PROXY_SNIPPET="/etc/nginx/snippets/reverse_proxy.conf"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

echo "==> Domain:   $DOMAIN"
echo "==> Upstream: $UPSTREAM"
echo "==> Email:    $EMAIL"
echo "==> Upload:   $UPLOAD"
echo ""

# ---------------------------------------------------------------------------
# 1. Install/Upgrade NGINX + Certbot (with auto-upgrade for old versions)
# ---------------------------------------------------------------------------
# Check current nginx version if installed
CURRENT_VERSION=""
NEEDS_UPGRADE=false
if command -v nginx &>/dev/null; then
  CURRENT_VERSION=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
  echo "==> Current NGINX version: ${CURRENT_VERSION:-unknown}"
  
  # Check if running old version (< 1.30)
  if [[ -n "$CURRENT_VERSION" ]]; then
    MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
    MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
    if [[ $MAJOR -eq 1 && $MINOR -lt 30 ]]; then
      NEEDS_UPGRADE=true
      echo "==> Old NGINX version detected ($CURRENT_VERSION). Will upgrade to latest stable."
      
      # Backup existing nginx configs before upgrade
      if [[ -d /etc/nginx ]]; then
        BACKUP_DIR="/etc/nginx.backup.$(date +%Y%m%d-%H%M%S)"
        echo "==> Backing up current NGINX configs to $BACKUP_DIR"
        cp -a /etc/nginx "$BACKUP_DIR"
      fi
    fi
  fi
fi

# Always ensure nginx repo is configured for latest stable version
if [[ ! -f /etc/apt/sources.list.d/nginx.list ]] || [[ "$NEEDS_UPGRADE" == true ]]; then
  echo "==> Configuring official NGINX repository for latest stable version..."
  apt-get update -y
  apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
  
  # Remove old nginx if needed for clean upgrade
  if [[ "$NEEDS_UPGRADE" == true ]]; then
    echo "==> Removing old NGINX version for clean upgrade..."
    systemctl stop nginx || true
    # Use purge to remove old packages but preserve configs
    apt-get remove --purge -y nginx nginx-common nginx-core || true
    apt-get autoremove -y || true
    # Clean up old package configs that might conflict
    rm -f /etc/apt/sources.list.d/nginx.list.save || true
  fi
  
  # Setup official nginx repo
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
  echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" > /etc/apt/preferences.d/99nginx
  
  # Force update package list
  apt-get update -y
fi

PKGS=()
# Always reinstall nginx if upgrade is needed
if [[ "$NEEDS_UPGRADE" == true ]] || ! command -v nginx &>/dev/null; then
  PKGS+=(nginx)
fi
# Check for certbot - prefer snap version (recommended by Let's Encrypt)
if ! command -v certbot &>/dev/null; then
  # Check if snap is available and use it for certbot (recommended)
  if command -v snap &>/dev/null; then
    echo "==> Installing Certbot via snap (recommended)..."
    snap install core
    snap refresh core
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
  else
    # Fallback to apt if snap not available
    PKGS+=(certbot)
  fi
fi

if [[ ${#PKGS[@]} -gt 0 ]]; then
  echo "==> Installing/Upgrading: ${PKGS[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "${PKGS[@]}"
  
  # Ensure conf.d directory exists (should be created by nginx package)
  mkdir -p /etc/nginx/conf.d
  
  # The nginx.org package already includes /etc/nginx/conf.d/*.conf by default
  # No need to modify nginx.conf
  
  echo "==> NGINX upgraded to version:"
  nginx -v
else
  echo "==> NGINX and Certbot already installed."
  nginx -v
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

# Earlier versions accepted mixed-case domains and consequently created
# mixed-case config paths. Disable only case-variant configs for this same
# domain so a stale file cannot keep referencing a missing certificate.
for existing_conf in /etc/nginx/conf.d/*.conf; do
  [[ -e "$existing_conf" ]] || continue
  if [[ "${existing_conf,,}" == "${CONF_PATH,,}" && "$existing_conf" != "$CONF_PATH" ]]; then
    disabled_conf="${existing_conf}.disabled.$(date +%Y%m%d-%H%M%S)"
    mv "$existing_conf" "$disabled_conf"
    echo "==> Disabled case-variant config: $existing_conf"
    echo "    Backup: $disabled_conf"
  fi
done

# Migrate configs created by older versions of this script. Limit the change to
# files carrying our marker so unrelated hand-written virtual hosts are left
# untouched. The replacement is semantically equivalent on NGINX 1.25.1+.
for legacy_conf in /etc/nginx/conf.d/*.conf; do
  [[ -e "$legacy_conf" && "$legacy_conf" != "$CONF_PATH" ]] || continue
  if grep -qF '# HTTPS reverse proxy' "$legacy_conf" \
      && grep -qE '^[[:space:]]*listen (443|\[::\]:443) ssl http2;' "$legacy_conf"; then
    legacy_backup="${legacy_conf}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "$legacy_conf" "$legacy_backup"

    # Add `http2 on;` beside the first legacy listener, then remove `http2`
    # from any remaining listener in that same generated config.
    if ! awk '
      BEGIN { http2_added = 0 }
      /^[[:space:]]*listen (443|\[::\]:443) ssl http2;[[:space:]]*$/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        sub(/ssl http2;/, "ssl;")
        print
        if (!http2_added) {
          print indent "http2 on;"
          http2_added = 1
        }
        next
      }
      { print }
    ' "$legacy_backup" > "$legacy_conf"; then
      cp -p "$legacy_backup" "$legacy_conf"
      echo "Error: failed to migrate $legacy_conf; restored its backup." >&2
      exit 1
    fi
    echo "==> Migrated deprecated HTTP/2 syntax in $legacy_conf"
  fi
done

# Preserve the current site config before temporarily switching it to HTTP for
# the ACME challenge. This also makes manual recovery straightforward.
if [[ -f "$CONF_PATH" ]]; then
  cp "$CONF_PATH" "${CONF_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
fi

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

# Remove default.conf if it exists (avoid port 80 conflict)
if [[ -f /etc/nginx/conf.d/default.conf ]]; then
  mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
  echo "==> Disabled default.conf to avoid port conflicts"
fi

# Create webroot for ACME challenge
mkdir -p /var/www/certbot

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 5. Obtain Let's Encrypt certificate (webroot — matches the config above)
# ---------------------------------------------------------------------------
# A directory alone is not proof that the certificate is usable: Certbot's
# live directory contains symlinks whose targets may be missing after a restore
# or partial migration. Certbot is idempotent with --keep-until-expiring, so use
# the same command for both first-time issuance and subsequent runs.
if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" && -s "$CERT_DIR/chain.pem" ]]; then
  echo "==> Existing certificate found for $DOMAIN; keeping it unless renewal is due..."
else
  echo "==> Certificate is missing or incomplete for $DOMAIN; obtaining it..."
fi

certbot certonly \
  --webroot -w /var/www/certbot \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  --cert-name "$DOMAIN" \
  -d "$DOMAIN" \
  --keep-until-expiring

for cert_file in fullchain.pem privkey.pem chain.pem; do
  if [[ ! -s "$CERT_DIR/$cert_file" ]]; then
    echo "Error: Certbot completed without creating a usable $CERT_DIR/$cert_file." >&2
    echo "       Run 'certbot certificates' and inspect the certificate lineage." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 6. Rewrite config with HTTPS + HTTP redirect (with updated SSL/TLS settings)
# ---------------------------------------------------------------------------
echo "==> Writing HTTPS NGINX config with latest SSL/TLS standards..."

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
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    client_max_body_size ${UPLOAD};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_trusted_certificate ${CERT_DIR}/chain.pem;

    # Modern SSL/TLS settings (updated for 2024/2025 standards)
    ssl_protocols       TLSv1.2 TLSv1.3;
    
    # Updated cipher suite for better security and performance
    ssl_ciphers         TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # OCSP stapling
    ssl_stapling        on;
    ssl_stapling_verify on;
    resolver            1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout    5s;

    # Enhanced Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options           DENY always;
    add_header X-Content-Type-Options    nosniff always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass ${UPSTREAM};
        include    snippets/reverse_proxy.conf;
    }
}
EOF

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 7. Set up auto-renewal (systemd timer or cron)
# ---------------------------------------------------------------------------
# Check if Certbot was installed via snap (it includes systemd timer)
if [[ -f /snap/bin/certbot ]]; then
  # Snap version includes automatic renewal via systemd timer
  echo "==> Certbot snap includes automatic renewal via systemd timer."
  systemctl list-timers | grep -q snap.certbot.renew && echo "==> Auto-renewal timer is active."
else
  # Set up cron job for non-snap installations
  CRON_JOB="0 3 * * * certbot renew --webroot -w /var/www/certbot --quiet --post-hook 'systemctl reload nginx'"
  if ! crontab -l 2>/dev/null | grep -qF "certbot renew"; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "==> Auto-renewal cron job added."
  else
    echo "==> Auto-renewal cron job already present."
  fi
fi

# Test renewal configuration
echo "==> Testing renewal configuration..."
certbot renew --dry-run --cert-name "$DOMAIN" --webroot -w /var/www/certbot

echo ""
echo "Done! https://${DOMAIN} now proxies to ${UPSTREAM} (max upload: ${UPLOAD})"
