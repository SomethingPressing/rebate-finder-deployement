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

APP_DIR="${APP_DIR:-/home/rf/apps/incenva-scraper-service}"
CONSUMER_APP_DIR="${CONSUMER_APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"

[[ -d "$APP_DIR" ]] || fail "App directory not found at $APP_DIR. Run setup-server.sh first."
[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE. Run setup-server.sh first."

cd "$APP_DIR"

export PATH="/usr/local/go/bin:$PATH"
command -v go &>/dev/null || fail "go not found in PATH. Is Go installed at /usr/local/go?"

log "1/6  git pull"
sudo -u rf git pull origin main
ok "Code updated"

log "2/6  pnpm install (Node scripts)"
command -v pnpm &>/dev/null || npm install -g pnpm
pnpm install --frozen-lockfile 2>&1 | tail -3
ok "Node dependencies up to date"

log "3/6  go mod download"
go mod download 2>&1 | tail -3
ok "Go modules up to date"

log "4/6  Build binaries"
go build -o bin/scraper ./cmd/scraper
ok "Built: bin/scraper"
go build -o bin/promoter ./cmd/promoter
ok "Built: bin/promoter"
if [[ -d "cmd/pdf-scraper" ]]; then
  go build -o bin/pdf-scraper ./cmd/pdf-scraper
  ok "Built: bin/pdf-scraper"
fi

log "5/6  Sync tenants.json → DB"
pnpm sync:tenants
ok "Tenant sync done"

log "6/6  PM2 restart"

SCRAPER_PM2_NAME="${SCRAPER_PM2_NAME:-incenva-scraper}"
PROMOTER_PM2_NAME="${PROMOTER_PM2_NAME:-incenva-promoter}"
REFRESH_PM2_NAME="${REFRESH_PM2_NAME:-incenva-refresh}"

# All PM2 operations run as the app user (rf) so processes join the correct
# PM2 daemon — not the root daemon.
PM2="sudo -u rf pm2"

# Scraper — long-running daemon; manages its own per-source schedule internally.
# SCRAPER_INTERVAL in .env controls the tick frequency (default: @every 1h).
if $PM2 list 2>/dev/null | grep -q "$SCRAPER_PM2_NAME"; then
  $PM2 restart "$SCRAPER_PM2_NAME"
  ok "Restarted '$SCRAPER_PM2_NAME'"
else
  $PM2 start "$APP_DIR/bin/scraper" \
    --name "$SCRAPER_PM2_NAME" \
    --interpreter none
  ok "Started '$SCRAPER_PM2_NAME' (ticks per SCRAPER_INTERVAL; per-source schedule from DB)"
fi

# Promoter — cron every 2 hours (promotes staged data to public.rebates)
# Uses a wrapper script so that after each promotion run, the rebate-finder
# link health check fires immediately for any published rebate whose
# program_url was just updated by the promoter.
PROMOTER_WRAPPER="$APP_DIR/bin/run-promoter.sh"
cat > "$PROMOTER_WRAPPER" << WRAPPER
#!/usr/bin/env bash
# Wrapper for PM2 cron — runs the Go promoter then triggers a link health check.
set -euo pipefail
SCRAPER_DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
CONSUMER_DIR="${CONSUMER_APP_DIR}"
STARTED_AT="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"

source "\$SCRAPER_DIR/.env" 2>/dev/null || true
export DATABASE_URL SCRAPER_DB_SCHEMA PROMOTER_SOURCE_PRIORITY

"\$SCRAPER_DIR/bin/promoter"
PROMOTER_EXIT=\$?

# Only run the link check if the promoter succeeded and the consumer app exists.
if [[ \$PROMOTER_EXIT -eq 0 && -d "\$CONSUMER_DIR" ]]; then
  echo "[promoter-wrapper] running link health check (updatedSince=\$STARTED_AT)..."
  source "\$CONSUMER_DIR/.env" 2>/dev/null || true
  cd "\$CONSUMER_DIR"
  npx --yes tsx scripts/check-program-links.ts --since="\$STARTED_AT" || \
    echo "[promoter-wrapper] link check failed (non-fatal)"
fi

exit \$PROMOTER_EXIT
WRAPPER
chmod +x "$PROMOTER_WRAPPER"
sudo chown rf:rf "$PROMOTER_WRAPPER"

if $PM2 list 2>/dev/null | grep -q "$PROMOTER_PM2_NAME"; then
  $PM2 restart "$PROMOTER_PM2_NAME" 2>/dev/null || true
  ok "Restarted '$PROMOTER_PM2_NAME' (wrapper updated)"
else
  $PM2 start "$PROMOTER_WRAPPER" \
    --name "$PROMOTER_PM2_NAME" \
    --interpreter bash \
    --cron '0 */2 * * *' \
    --no-autorestart
  ok "Registered '$PROMOTER_PM2_NAME' (runs every 2 hours, with post-promotion link check)"
fi

# Daily refresh — re-scrapes programs not updated in the last 7 days and
# resets their promotion status so the promoter pushes fresh data to live.
# Runs at 03:00 UTC daily via a wrapper script that sets RUN_ONCE=true.
REFRESH_WRAPPER="$APP_DIR/bin/run-refresh.sh"
cat > "$REFRESH_WRAPPER" << 'WRAPPER'
#!/usr/bin/env bash
# Wrapper for PM2 cron — sets RUN_ONCE so the binary exits after one pass.
cd "$(dirname "$0")/.."
source .env 2>/dev/null || true
RUN_ONCE=true ./bin/scraper --force-refresh
WRAPPER
chmod +x "$REFRESH_WRAPPER"
sudo chown rf:rf "$REFRESH_WRAPPER"

if $PM2 list 2>/dev/null | grep -q "$REFRESH_PM2_NAME"; then
  ok "Refresh cron '$REFRESH_PM2_NAME' already registered — no change needed"
else
  $PM2 start "$REFRESH_WRAPPER" \
    --name "$REFRESH_PM2_NAME" \
    --interpreter bash \
    --cron '0 3 * * *' \
    --no-autorestart
  ok "Registered '$REFRESH_PM2_NAME' (daily at 03:00 UTC, refreshes programs >7 days old)"
fi

$PM2 save >/dev/null

echo ""
echo -e "  ${GREEN}${BOLD}Deploy complete.${NC}"
echo ""
