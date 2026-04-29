#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Pull latest app code, rebuild, and restart Incenva Rebate Finder
#
# This script deploys code changes only. Seed data is managed separately via
# seed.sh — it is NOT run here to keep data changes decoupled from code deploys.
#
# Usage:
#   bash scripts/rebate-finder/deploy.sh
#
# Overrides:
#   APP_DIR=/custom/path bash scripts/rebate-finder/deploy.sh
#
# Safe to run multiple times.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[deploy]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"
PM2_APP_NAME="${PM2_APP_NAME:-incenva-rebate-finder}"

[[ -d "$APP_DIR" ]]  || fail "App directory not found at $APP_DIR. Run setup-server.sh first."
[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE. Run setup-server.sh first."

DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
SCRAPER_DB_SCHEMA="$(grep -E '^SCRAPER_DB_SCHEMA=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
PROMOTER_SOURCE_PRIORITY="$(grep -E '^PROMOTER_SOURCE_PRIORITY=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
export DATABASE_URL SCRAPER_DB_SCHEMA PROMOTER_SOURCE_PRIORITY
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE."

cd "$APP_DIR"

log "1/5  git pull"
git pull
ok "Code updated"

log "2/5  pnpm install"
pnpm install --frozen-lockfile 2>&1 | tail -3
ok "Dependencies up to date"

log "3/5  prisma db push (schema sync)"
pnpm prisma db push --skip-generate --accept-data-loss
ok "Schema synced"

log "4/5  Production build"
pnpm build
ok "Build complete"

log "5/5  PM2 restart"
if pm2 list 2>/dev/null | grep -q "$PM2_APP_NAME"; then
  pm2 restart "$PM2_APP_NAME"
  ok "Restarted '$PM2_APP_NAME'"
else
  warn "PM2 process '$PM2_APP_NAME' not found — run setup-server.sh first"
fi

PROMOTER_NAME="incenva-promoter"
if pm2 list 2>/dev/null | grep -q "$PROMOTER_NAME"; then
  ok "Promoter cron '$PROMOTER_NAME' already registered — no change needed"
else
  pm2 start 'node scripts/run-promoter.mjs' \
    --name "$PROMOTER_NAME" \
    --cron '0 * * * *' \
    --no-autorestart
  ok "Registered '$PROMOTER_NAME' (runs every hour)"
fi

pm2 save >/dev/null

hr
echo ""
echo -e "  ${GREEN}${BOLD}Deploy complete.${NC}"
echo ""
echo "  Note: seed data was NOT touched. To update seed data separately:"
echo "    bash scripts/rebate-finder/seed.sh"
echo ""
hr
