#!/usr/bin/env bash
# =============================================================================
# setup-fly.sh — First-time fly.io setup for Incenva Scraper
#
# Run this once when setting up a new fly.io app for the scraper.
# For subsequent deploys, use deploy-fly.sh.
#
# Usage:
#   bash scripts/scraper/setup-fly.sh
#
# Prerequisites:
#   - flyctl installed: https://fly.io/docs/hands-on/install-flyctl/
#   - Logged in: fly auth login
#   - rebate-finder-scrapers repo cloned locally (or on the deployment server)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[setup-fly]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

FLY_APP="${FLY_APP:-incenva-scraper}"
FLY_REGION="${FLY_REGION:-iad}"

command -v fly &>/dev/null || fail "flyctl not found. Install: https://fly.io/docs/hands-on/install-flyctl/"

hr
echo ""
echo -e "  ${BOLD}Incenva Scraper — fly.io Setup${NC}"
echo "  App: $FLY_APP   Region: $FLY_REGION"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
log "1/4  Create fly.io app (skipped if already exists)"

if fly status --app "$FLY_APP" &>/dev/null; then
  ok "App '$FLY_APP' already exists"
else
  fly apps create "$FLY_APP" --org personal
  ok "App '$FLY_APP' created"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "2/4  Set Rewiring America API key"

echo -n "  Enter REWIRING_AMERICA_API_KEY (leave blank to skip): "
read -r RA_KEY
if [[ -n "$RA_KEY" ]]; then
  fly secrets set "REWIRING_AMERICA_API_KEY=$RA_KEY" --app "$FLY_APP"
  ok "REWIRING_AMERICA_API_KEY set"
else
  warn "Skipped — set it later: fly secrets set REWIRING_AMERICA_API_KEY=<key> --app $FLY_APP"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "3/4  Add tenant DB URLs"
echo ""
echo "  For each tenant, provide the DB URL. Secret name convention: TENANT_<ID_UPPER>_DB_URL"
echo "  Example: tenant id=acme → secret name=TENANT_ACME_DB_URL"
echo "  Press Enter with no input to finish adding tenants."
echo ""

while true; do
  echo -n "  Tenant ID (e.g. acme) or blank to stop: "
  read -r TENANT_ID
  [[ -z "$TENANT_ID" ]] && break

  TENANT_ID_UPPER="${TENANT_ID^^}"
  SECRET_NAME="TENANT_${TENANT_ID_UPPER}_DB_URL"

  echo -n "  DB URL for $TENANT_ID (postgres://...): "
  read -r -s TENANT_DB_URL
  echo ""

  if [[ -z "$TENANT_DB_URL" ]]; then
    warn "Skipped $TENANT_ID — no URL provided"
    continue
  fi

  fly secrets set "${SECRET_NAME}=${TENANT_DB_URL}" --app "$FLY_APP"
  ok "Set $SECRET_NAME"

  echo ""
  echo "  Don't forget to add this tenant to config/tenants.json in the scraper repo:"
  echo '  {'
  echo "    \"id\": \"${TENANT_ID}\","
  echo "    \"name\": \"<Display Name>\","
  echo "    \"active\": true,"
  echo "    \"sources\": [\"dsireusa\", \"rewiring_america\", \"energy_star\"],"
  echo "    \"db_url_env\": \"${SECRET_NAME}\","
  echo "    \"scraper_db_schema\": \"scraper\""
  echo '  }'
  echo ""
done

# ─────────────────────────────────────────────────────────────────────────────
log "4/4  First deploy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$(dirname "$SCRIPT_DIR")/scraper/deploy-fly.sh"

if [[ -f "$DEPLOY_SCRIPT" ]]; then
  bash "$DEPLOY_SCRIPT"
else
  warn "deploy-fly.sh not found at $DEPLOY_SCRIPT — deploy manually:"
  warn "  cd <scraper-repo> && bash scripts/deploy-fly.sh"
fi

hr
echo ""
echo -e "  ${GREEN}${BOLD}fly.io setup complete!${NC}"
echo ""
echo "  Check secrets:   fly secrets list --app $FLY_APP"
echo "  Check logs:      fly logs --app $FLY_APP"
echo "  Run manually:    fly machine run --app $FLY_APP --image registry.fly.io/${FLY_APP}:latest --env RUN_ONCE=true"
echo ""
echo "  To schedule automatic runs every 6 hours:"
echo "    fly machine run --app $FLY_APP \\"
echo "      --image registry.fly.io/${FLY_APP}:latest \\"
echo "      --schedule '0 */6 * * *' \\"
echo "      --env RUN_ONCE=true --restart no"
echo ""
hr
