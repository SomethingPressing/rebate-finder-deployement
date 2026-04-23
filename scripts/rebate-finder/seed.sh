#!/usr/bin/env bash
# =============================================================================
# seed.sh — Load seed data from this deployment repo into the database
#
# Runs `prisma db seed` in the main app, pointing SEED_DIR at the seeds/json
# folder inside this deployment repo. Safe to run multiple times — all writes
# use upserts so existing rows are updated, not duplicated.
#
# Usage:
#   bash scripts/rebate-finder/seed.sh
#
# Overrides:
#   APP_DIR=/custom/path bash scripts/rebate-finder/seed.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[seed]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEEDS_DIR="$DEPLOY_REPO_DIR/seeds/json"
APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"

hr
echo ""
echo -e "  ${BOLD}Incenva Rebate Finder — Database Seed${NC}"
echo "  Seed data: $SEEDS_DIR"
echo "  App dir:   $APP_DIR"
echo ""
hr

[[ -d "$SEEDS_DIR" ]] || fail "Seed data not found at $SEEDS_DIR"
[[ -d "$APP_DIR" ]]   || fail "App directory not found at $APP_DIR. Clone the app first."
[[ -f "$ENV_FILE" ]]  || fail ".env not found at $ENV_FILE. Run setup-server.sh first."

# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | grep -E '^DATABASE_URL=' | xargs)
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE"

log "Running seed…"
cd "$APP_DIR"
SEED_DIR="$SEEDS_DIR" DATABASE_URL="$DATABASE_URL" pnpm prisma db seed

hr
echo ""
ok "Seed complete. All writes were idempotent (upserts) — no duplicate rows created."
echo ""
hr
