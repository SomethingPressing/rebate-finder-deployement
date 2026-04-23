#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Pull latest code, rebuild, and restart Incenva Rebate Finder
#
# Usage (from project root, as the app user or root):
#   bash scripts/deploy.sh
#
# Safe to run multiple times.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[deploy]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
PM2_APP_NAME="${PM2_APP_NAME:-Rebate Finder}"

cd "$PROJECT_DIR"

[[ -f "$ENV_FILE" ]] || fail ".env not found. Run setup-server.sh first."
# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | grep -E '^(DATABASE_URL|JWT_SECRET)=' | xargs)

log "1/5  git pull"
git pull
ok "Code updated"

log "2/5  pnpm install"
pnpm install --frozen-lockfile 2>&1 | tail -3
ok "Dependencies up to date"

log "3/5  prisma db push (schema sync)"
pnpm prisma db push --skip-generate
ok "Schema synced"

log "4/5  Production build"
pnpm build
ok "Build complete"

log "5/5  PM2 restart"
if pm2 list 2>/dev/null | grep -q "$PM2_APP_NAME"; then
  pm2 restart "$PM2_APP_NAME"
  ok "Restarted '$PM2_APP_NAME'"
else
  warn "PM2 process '$PM2_APP_NAME' not found — start it with setup-server.sh"
fi

echo ""
echo -e "  ${GREEN}${BOLD}Deploy complete.${NC}"
echo ""
