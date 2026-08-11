#!/usr/bin/env bash
# =============================================================================
# setup-tls.sh — nginx + TLS for the broker, written explicitly
#
# Why this exists instead of scripts/setup-ssl.sh:
#
# The generic script leans on certbot's nginx plugin to both obtain and install.
# That plugin edits an existing server block by pattern-matching it, and when it
# cannot find one it expects, it succeeds without doing anything — leaving a
# valid certificate on disk and nginx still listening on port 80. From outside
# that is indistinguishable from issuance failing, and behind Cloudflare it is a
# 521 with nothing in any log on the box.
#
# So this writes the config itself. Deterministic: the same file every time, at
# a path we control, with the certificate paths we just created. certbot is used
# only for what it is reliable at — obtaining a certificate.
#
# Usage (on the broker host, as root):
#   APP_DOMAIN=broker.incenva.com CLOUDFLARE_API_TOKEN=… bash setup-tls.sh
#
# Idempotent. Safe to run repeatedly; it converges on a serving 443.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[tls]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✖${NC} $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

[[ $EUID -eq 0 ]] || fail "run as root"
APP_DOMAIN="${APP_DOMAIN:?APP_DOMAIN is required, e.g. broker.incenva.com}"
BROKER_PORT="${BROKER_PORT:-8080}"
LIVE="/etc/letsencrypt/live/${APP_DOMAIN}"

# ── 1. nginx and certbot ─────────────────────────────────────────────────────
log "1/4  Packages"
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare >/dev/null
ok "nginx + certbot"

# ── 2. A certificate ─────────────────────────────────────────────────────────
log "2/4  Certificate"
if [[ -f "$LIVE/fullchain.pem" ]]; then
  ok "already have one (expires $(openssl x509 -noout -enddate -in "$LIVE/fullchain.pem" | cut -d= -f2))"
else
  FLAGS=(certonly --non-interactive --agree-tos -d "$APP_DOMAIN")
  if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
    FLAGS+=(--email "$CERTBOT_EMAIL")
  else
    FLAGS+=(--register-unsafely-without-email)
  fi

  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    # DNS-01, because the hostname is proxied: an HTTP-01 challenge is answered
    # by Cloudflare's edge and never reaches this box.
    mkdir -p /root/.secrets
    printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > /root/.secrets/cloudflare.ini
    chmod 600 /root/.secrets/cloudflare.ini
    FLAGS+=(--dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini
            --dns-cloudflare-propagation-seconds 30)
    ok "using DNS-01 (works with the record proxied)"
  else
    # webroot rather than the nginx plugin: it only needs a directory, so it
    # cannot half-succeed the way a config rewrite can.
    mkdir -p /var/www/certbot
    FLAGS+=(--webroot -w /var/www/certbot)
    warn "no CLOUDFLARE_API_TOKEN — using HTTP-01, which FAILS if $APP_DOMAIN is proxied"
  fi

  certbot "${FLAGS[@]}" || fail "certbot could not obtain a certificate for $APP_DOMAIN"
  ok "obtained"
fi
[[ -f "$LIVE/fullchain.pem" ]] || fail "no certificate at $LIVE after certbot reported success"

# ── 3. The config, written rather than patched ───────────────────────────────
log "3/4  nginx"
CONF=/etc/nginx/sites-available/broker
cat > "$CONF" <<NGINX
# Managed by scripts/broker/setup-tls.sh — regenerated on every run.
# Edited by hand? Your changes will be overwritten; put them in a separate file.

server {
    listen 80;
    listen [::]:80;
    server_name ${APP_DOMAIN};

    # Kept reachable so an HTTP-01 renewal can be answered if the record is
    # ever un-proxied. Everything else goes to HTTPS.
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${APP_DOMAIN};

    ssl_certificate     ${LIVE}/fullchain.pem;
    ssl_certificate_key ${LIVE}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    # The wire contract carries whole pages of queue entries; the default 1 MB
    # would truncate a large drain.
    client_max_body_size 10m;

    location / {
        proxy_pass http://127.0.0.1:${BROKER_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        # Cloudflare terminates TLS at its edge and talks to us over HTTPS, so
        # the app must be told the original scheme or it will build http:// URLs.
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 300s;
    }
}
NGINX

ln -sf "$CONF" /etc/nginx/sites-enabled/broker
# The default site answers on port 80 for any hostname and can shadow ours.
rm -f /etc/nginx/sites-enabled/default

nginx -t || fail "nginx rejected the config above — it has NOT been reloaded, so the site is still up"
systemctl reload nginx
ok "config written and reloaded"

# ── 4. Prove it ──────────────────────────────────────────────────────────────
log "4/4  Verify"
sleep 1
ss -tln | grep -q ':443 ' || fail "still nothing listening on 443 — check: journalctl -u nginx -n 40"
ok "listening on 443"

if curl -fsS --max-time 10 --resolve "${APP_DOMAIN}:443:127.0.0.1" \
     "https://${APP_DOMAIN}/healthz" | grep -q '"ok":true'; then
  ok "the broker answers over TLS on this box"
else
  warn "443 is open but /healthz did not answer — is the broker running? pm2 ls"
fi

echo ""
ok "TLS ready for ${APP_DOMAIN}"
echo "  From your laptop:  curl -s https://${APP_DOMAIN}/healthz"
echo ""
echo "  If that still fails while the check above passed, the problem is between"
echo "  Cloudflare and this box, not on it. In Cloudflare set SSL/TLS mode to"
echo "  Full (strict) — Flexible makes Cloudflare talk HTTP to port 443 and fail."
