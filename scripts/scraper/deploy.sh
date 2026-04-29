#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Pull latest code, rebuild binaries, and restart Incenva Scraper
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
PM2_APP_NAME="${PM2_APP_NAME:-Incenva Scraper}"

cd "$PROJECT_DIR"

[[ -f "$ENV_FILE" ]] || fail ".env not found. Run setup-server.sh first."

export PATH="$PATH:/usr/local/go/bin"
command -v go &>/dev/null || fail "go not found in PATH. Is Go installed at /usr/local/go?"

log "1/4  git pull"
git pull
ok "Code updated"

log "2/4  go mod download"
go mod download 2>&1 | tail -3
ok "Modules up to date"

log "3/4  Build binaries"
go build -o bin/scraper ./cmd/scraper
ok "Built: bin/scraper"
go build -o bin/promoter ./cmd/promoter
ok "Built: bin/promoter"
if [[ -d "cmd/pdf-scraper" ]]; then
  go build -o bin/pdf-scraper ./cmd/pdf-scraper
  ok "Built: bin/pdf-scraper"
fi

log "4/4  PM2 restart"

SCRAPER_PM2_NAME="${SCRAPER_PM2_NAME:-incenva-scraper}"
PROMOTER_PM2_NAME="${PROMOTER_PM2_NAME:-incenva-promoter}"

if pm2 list 2>/dev/null | grep -q "$SCRAPER_PM2_NAME"; then
  pm2 restart "$SCRAPER_PM2_NAME"
  ok "Restarted '$SCRAPER_PM2_NAME'"
else
  warn "PM2 process '$SCRAPER_PM2_NAME' not found — run setup-server.sh first"
fi

if pm2 list 2>/dev/null | grep -q "$PROMOTER_PM2_NAME"; then
  ok "Promoter cron '$PROMOTER_PM2_NAME' already registered — no change needed"
else
  pm2 start bin/promoter \
    --name "$PROMOTER_PM2_NAME" \
    --interpreter none \
    --cron '0 */2 * * *' \
    --no-autorestart
  ok "Registered '$PROMOTER_PM2_NAME' (runs every 2 hours)"
fi

pm2 save >/dev/null

echo ""
echo -e "  ${GREEN}${BOLD}Deploy complete.${NC}"
echo ""
