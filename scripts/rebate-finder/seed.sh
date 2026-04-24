#!/usr/bin/env bash
# =============================================================================
# seed.sh — Load seed data into the database (sysadmin task, never auto-run)
#
# Calls tsx prisma/seed.ts directly, pointing SEED_DIR at the given seed folder.
# Safe to run multiple times — all writes use upserts.
#
# Usage:
#   bash scripts/rebate-finder/seed.sh
#   bash scripts/rebate-finder/seed.sh /path/to/custom/seeds/json
#
# Overrides via env:
#   APP_DIR=/custom/path bash scripts/rebate-finder/seed.sh
#   SEED_DIR=/custom/seeds/json bash scripts/rebate-finder/seed.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[seed]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"

# Seed folder: first positional arg → SEED_DIR env var → default in deployment repo
if [[ -n "${1:-}" ]]; then
  SEED_DIR="$1"
elif [[ -n "${SEED_DIR:-}" ]]; then
  SEED_DIR="$SEED_DIR"
else
  SEED_DIR="$DEPLOY_REPO_DIR/seeds/json"
fi

hr
echo ""
echo -e "  ${BOLD}Incenva Rebate Finder — Database Seed${NC}"
echo "  Seed dir: $SEED_DIR"
echo "  App dir:  $APP_DIR"
echo ""
hr

[[ -d "$SEED_DIR" ]] || fail "Seed directory not found: $SEED_DIR"
[[ -d "$APP_DIR" ]]  || fail "App directory not found at $APP_DIR. Run setup-server.sh first."
[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE. Run setup-server.sh first."

DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
export DATABASE_URL
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE"

log "Running seed from $SEED_DIR …"
cd "$APP_DIR"
SEED_DIR="$SEED_DIR" DATABASE_URL="$DATABASE_URL" pnpm exec tsx prisma/seed.ts

hr
echo ""
ok "Seed complete. All writes were idempotent (upserts) — no duplicate rows created."
echo ""
hr
