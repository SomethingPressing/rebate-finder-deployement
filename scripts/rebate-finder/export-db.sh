#!/usr/bin/env bash
# =============================================================================
# export-db.sh — Dump the Rebate Finder PostgreSQL database to a .sql file
#
# Usage:
#   bash scripts/rebate-finder/export-db.sh
#
# Output:
#   rebate_finder_YYYY-MM-DD_HH-MM.sql   (in the current directory)
#
# To import on another machine:
#   psql "$DATABASE_URL" < rebate_finder_YYYY-MM-DD_HH-MM.sql
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[export]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }

APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"

[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE. Set APP_DIR or run setup-server.sh first."

DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')"
[[ -n "$DATABASE_URL" ]] || fail "DATABASE_URL not set in $ENV_FILE."

TIMESTAMP="$(date '+%Y-%m-%d_%H-%M')"
OUTPUT_FILE="$OUTPUT_DIR/rebate_finder_${TIMESTAMP}.sql"

log "Exporting database to $OUTPUT_FILE …"

pg_dump \
  --no-owner \
  --no-acl \
  --clean \
  --if-exists \
  "$DATABASE_URL" \
  > "$OUTPUT_FILE"

SIZE="$(du -sh "$OUTPUT_FILE" | cut -f1)"
ok "Export complete: $OUTPUT_FILE ($SIZE)"
echo ""
echo "  To import on another machine:"
echo "    psql \"\$DATABASE_URL\" < $OUTPUT_FILE"
echo ""
