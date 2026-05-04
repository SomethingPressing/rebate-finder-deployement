#!/usr/bin/env bash
# =============================================================================
# fix-portfolio.sh — Backfill the rebates.portfolio column for historical rows.
#
# Assigns the correct Utility / State / Federal label to every rebate that has
# a NULL or incorrect portfolio value (building-type labels set by old scraper
# code, e.g. "Residential", "New Construction", "Energy Efficiency").
#
# Safe to run multiple times — each UPDATE only touches rows that still need it.
#
# Usage:
#   bash scripts/rebate-finder/fix-portfolio.sh
#
# Overrides:
#   APP_DIR=/custom/path bash scripts/rebate-finder/fix-portfolio.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[fix-portfolio]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"

[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE — run setup-server.sh first"

DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
export DATABASE_URL
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE"

BACKFILL_SQL="$APP_DIR/prisma/scripts/backfill-portfolio.sql"
[[ -f "$BACKFILL_SQL" ]] || fail "Backfill script not found at $BACKFILL_SQL — ensure the app code is up to date (git pull)"

hr
echo ""
echo -e "  ${BOLD}Incenva — Portfolio Backfill${NC}"
echo "  Database: $DATABASE_URL"
echo "  Script:   $BACKFILL_SQL"
echo ""
hr

log "Running backfill..."
psql "$DATABASE_URL" -f "$BACKFILL_SQL" -v ON_ERROR_STOP=1
ok "Backfill complete"

hr
echo ""
echo -e "  ${GREEN}${BOLD}Done.${NC}  All rebates now have a valid portfolio value."
echo ""
echo "  The filter on /admin/programs → Utility / State / Federal"
echo "  should now work correctly."
echo ""
hr
