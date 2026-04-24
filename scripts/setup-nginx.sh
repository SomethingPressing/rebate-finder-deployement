#!/usr/bin/env bash
# =============================================================================
# setup-nginx.sh — Idempotent nginx setup for Incenva Rebate Finder
#
# Installs nginx, deploys the reverse-proxy config (port 80 → localhost:3000),
# removes the default site, and starts/reloads nginx.
#
# Usage:
#   bash scripts/setup-nginx.sh
#   bash scripts/setup-nginx.sh yourdomain.com
#   APP_DOMAIN=yourdomain.com bash scripts/setup-nginx.sh
#
# Safe to run multiple times.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[nginx]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
skip() { echo -e "  ${YELLOW}─${NC}  $* (already done)"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_TEMPLATE="$DEPLOY_DIR/nginx/rebate-finder.conf"
NGINX_AVAILABLE="/etc/nginx/sites-available/rebate-finder"
NGINX_ENABLED="/etc/nginx/sites-enabled/rebate-finder"

# Domain: first positional arg → APP_DOMAIN env var → catch-all _
APP_DOMAIN="${1:-${APP_DOMAIN:-_}}"

hr
echo ""
echo -e "  ${BOLD}Incenva — Nginx Setup${NC}"
echo "  Domain:  $APP_DOMAIN"
echo "  Config:  $NGINX_AVAILABLE"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
log "1/4  Install nginx"

if command -v nginx &>/dev/null; then
  skip "nginx $(nginx -v 2>&1 | grep -o '[0-9.]*' | head -1)"
else
  apt-get update -qq
  apt-get install -y nginx >/dev/null
  ok "Installed nginx"
fi

systemctl enable nginx >/dev/null 2>&1 || true

# ─────────────────────────────────────────────────────────────────────────────
log "2/4  Deploy config"

# Copy template and inject the domain
cp "$NGINX_TEMPLATE" "$NGINX_AVAILABLE"
if [[ "$APP_DOMAIN" != "_" ]]; then
  sed -i "s|server_name _;|server_name $APP_DOMAIN;|" "$NGINX_AVAILABLE"
fi
ok "Written $NGINX_AVAILABLE (server_name: $APP_DOMAIN)"

# ─────────────────────────────────────────────────────────────────────────────
log "3/4  Enable site"

# Remove the default site if it's still enabled
if [[ -f /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  ok "Removed default site"
fi

if [[ -L "$NGINX_ENABLED" ]]; then
  skip "Symlink already exists"
else
  ln -sf "$NGINX_AVAILABLE" "$NGINX_ENABLED"
  ok "Enabled $NGINX_ENABLED"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "4/4  Test and reload"

nginx -t
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
  ok "nginx reloaded"
else
  systemctl start nginx
  ok "nginx started"
fi

hr
echo ""
echo -e "  ${GREEN}${BOLD}nginx ready — app is available on port 80.${NC}"
echo ""
if [[ "$APP_DOMAIN" == "_" ]]; then
  warn "server_name is set to _ (catch-all)."
  warn "To set a real domain, edit $NGINX_AVAILABLE and run:"
  echo "    sudo nginx -t && sudo systemctl reload nginx"
else
  ok "Serving: http://$APP_DOMAIN"
fi
echo ""
echo -e "  ${BOLD}To add SSL (Let's Encrypt) later:${NC}"
echo "    sudo apt-get install -y certbot python3-certbot-nginx"
echo "    sudo certbot --nginx -d $APP_DOMAIN"
echo ""
hr
