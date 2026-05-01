#!/usr/bin/env bash
# =============================================================================
# setup-ssl.sh — Idempotent Let's Encrypt SSL setup for Incenva Rebate Finder
#
# Installs Certbot, obtains (or renews) a certificate for the given domain,
# lets Certbot patch the Nginx config, and verifies auto-renewal.
#
# Also updates NEXT_BASE_URL in the app .env to https:// when a new cert is
# issued so the Next.js app knows it's behind HTTPS.
#
# Usage:
#   sudo bash scripts/setup-ssl.sh dev.incenva.com
#   sudo APP_DOMAIN=dev.incenva.com bash scripts/setup-ssl.sh
#
# Idempotent — if a valid certificate already exists for the domain, the
# script skips issuance and just verifies auto-renewal.
#
# Requirements:
#   - Nginx must already be configured with server_name <domain> (run setup-nginx.sh first)
#   - DNS A record for <domain> must point to this server's public IP
#   - Ports 80 and 443 must be open in the firewall
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "\n${BLUE}[ssl]${NC} ${BOLD}$*${NC}"; }
ok()    { echo -e "  ${GREEN}✔${NC}  $*"; }
skip()  { echo -e "  ${YELLOW}─${NC}  $* (skipping)"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
info()  { echo -e "  ${BLUE}→${NC}  $*"; }
fail()  { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()    { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

# ── Guards ────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0 <domain>"

APP_DOMAIN="${1:-${APP_DOMAIN:-}}"
[[ -n "$APP_DOMAIN" && "$APP_DOMAIN" != "_" ]] \
  || fail "Usage: sudo bash $0 dev.incenva.com\n       or: APP_DOMAIN=dev.incenva.com sudo bash $0"

APP_USER="${APP_USER:-rf}"
APP_DIR="/home/$APP_USER/apps/rebate-finder"
ENV_FILE="$APP_DIR/.env"

hr
echo ""
echo -e "  ${BOLD}Incenva — SSL / Let's Encrypt${NC}"
echo "  Domain:   $APP_DOMAIN"
echo "  App user: $APP_USER"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
log "1/5  Install Certbot"

if command -v certbot &>/dev/null; then
  skip "certbot $(certbot --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1) already installed"
else
  apt-get update -qq
  apt-get install -y certbot python3-certbot-nginx >/dev/null
  ok "Installed certbot + python3-certbot-nginx"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "2/5  Check DNS"

SERVER_IP="$(curl -sf --max-time 5 https://api.ipify.org || curl -sf --max-time 5 https://ifconfig.me || echo '')"
DNS_IP="$(getent hosts "$APP_DOMAIN" | awk '{print $1; exit}' || true)"

if [[ -z "$DNS_IP" ]]; then
  warn "DNS: $APP_DOMAIN does not resolve yet."
  warn "Create an A record: $APP_DOMAIN → ${SERVER_IP:-<this server's IP>}"
  warn "Let's Encrypt will fail until DNS propagates."
  echo ""
  read -rp "  Continue anyway? (y/N) " CONFIRM < /dev/tty
  [[ "${CONFIRM,,}" == "y" ]] || fail "Aborted. Re-run once DNS resolves: dig +short $APP_DOMAIN"
elif [[ -n "$SERVER_IP" && "$DNS_IP" != "$SERVER_IP" ]]; then
  warn "DNS mismatch: $APP_DOMAIN → $DNS_IP (expected $SERVER_IP)"
  warn "If this server was recently re-provisioned, DNS may be stale."
  echo ""
  read -rp "  Continue anyway? (y/N) " CONFIRM < /dev/tty
  [[ "${CONFIRM,,}" == "y" ]] || fail "Aborted. Re-run once DNS resolves: dig +short $APP_DOMAIN"
else
  ok "DNS OK: $APP_DOMAIN → $DNS_IP"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "3/5  Obtain certificate"

CERT_PATH="/etc/letsencrypt/live/$APP_DOMAIN/fullchain.pem"

if [[ -f "$CERT_PATH" ]]; then
  # Certificate already exists — check expiry
  EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "unknown")
  skip "Certificate already exists (expires: $EXPIRY)"
  info "To force-renew: certbot renew --force-renewal --nginx -d $APP_DOMAIN"
else
  info "Running: certbot --nginx --non-interactive --agree-tos --no-eff-email -d $APP_DOMAIN"
  info "(Using --register-unsafely-without-email — add --email you@example.com for expiry alerts)"
  echo ""

  # Use --register-unsafely-without-email for automated runs.
  # If you want expiry email alerts, set CERTBOT_EMAIL env var.
  CERTBOT_FLAGS=(--nginx --non-interactive --agree-tos --no-eff-email -d "$APP_DOMAIN")
  if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
    CERTBOT_FLAGS+=(--email "$CERTBOT_EMAIL")
    CERTBOT_FLAGS=("${CERTBOT_FLAGS[@]/--no-eff-email}")  # remove conflicting flag
    CERTBOT_FLAGS=(--nginx --non-interactive --agree-tos --email "$CERTBOT_EMAIL" -d "$APP_DOMAIN")
  fi

  if certbot "${CERTBOT_FLAGS[@]}"; then
    ok "Certificate issued for $APP_DOMAIN"
    CERT_ISSUED=true
  else
    fail "Certbot failed. Check:\n  - DNS: dig +short $APP_DOMAIN\n  - Port 80 open: ufw status\n  - Nginx running: systemctl status nginx\n  - Nginx config: nginx -t"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
log "4/5  Verify auto-renewal"

if certbot renew --dry-run --quiet 2>/dev/null; then
  ok "Auto-renewal dry-run succeeded"
else
  warn "Auto-renewal dry-run failed — check: systemctl status certbot.timer"
fi

if systemctl is-enabled certbot.timer &>/dev/null; then
  ok "certbot.timer is enabled (auto-renewal active)"
else
  systemctl enable certbot.timer 2>/dev/null || true
  ok "Enabled certbot.timer"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "5/5  Update app .env (NEXT_BASE_URL)"

if [[ -f "$ENV_FILE" ]]; then
  CURRENT_URL=$(grep -E '^NEXT_BASE_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
  EXPECTED_URL="https://$APP_DOMAIN"

  if [[ "$CURRENT_URL" == "$EXPECTED_URL" ]]; then
    skip "NEXT_BASE_URL already set to $EXPECTED_URL"
  else
    if grep -q '^NEXT_BASE_URL=' "$ENV_FILE"; then
      sed -i "s|^NEXT_BASE_URL=.*|NEXT_BASE_URL=$EXPECTED_URL|" "$ENV_FILE"
    else
      echo "NEXT_BASE_URL=$EXPECTED_URL" >> "$ENV_FILE"
    fi
    ok "NEXT_BASE_URL → $EXPECTED_URL"
    info "Rebuild required for this change to take effect:"
    info "  bash /home/$APP_USER/apps/deployment/scripts/rebate-finder/deploy.sh"
  fi
else
  warn ".env not found at $ENV_FILE — skipping NEXT_BASE_URL update"
  info "Set it manually: NEXT_BASE_URL=https://$APP_DOMAIN"
fi

# ─────────────────────────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${GREEN}${BOLD}SSL ready!${NC}"
echo ""
echo -e "  ${BOLD}HTTPS URL:${NC}  https://$APP_DOMAIN"
echo ""
echo -e "  ${BOLD}Certificate:${NC}"
certbot certificates --domain "$APP_DOMAIN" 2>/dev/null | grep -E "Expiry|Certificate Path" | sed 's/^/    /' || true
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    certbot certificates              # list certs + expiry"
echo "    certbot renew --dry-run           # test auto-renewal"
echo "    certbot renew --force-renewal     # force renewal now"
echo "    systemctl status certbot.timer    # renewal schedule"
echo ""
echo -e "  ${BOLD}Docs:${NC}  /home/$APP_USER/apps/deployment/docs/ssl-letsencrypt.md"
hr
echo ""
