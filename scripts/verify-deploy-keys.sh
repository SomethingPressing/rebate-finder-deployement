#!/usr/bin/env bash
# =============================================================================
# verify-deploy-keys.sh — Test GitHub SSH connections for all three repos
#
# Run this after adding public keys in GitHub to confirm everything works.
#
# Usage (run as root or rf user):
#   bash scripts/verify-deploy-keys.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*"; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

APP_USER="${APP_USER:-rf}"

hr
echo ""
echo -e "  ${BOLD}Verifying GitHub deploy key connections...${NC}"
echo ""

PASS=0
FAIL=0

test_key() {
  local alias="$1"
  local label="$2"

  # ssh -T returns exit code 1 even on success (GitHub quirk), so capture output
  local output
  output=$(sudo -u "$APP_USER" ssh -T "$alias" 2>&1 || true)

  if echo "$output" | grep -q "successfully authenticated"; then
    ok "$label → authenticated"
    PASS=$((PASS + 1))
  else
    fail "$label → FAILED"
    echo -e "       ${RED}$output${NC}"
    FAIL=$((FAIL + 1))
  fi
}

test_key "github-rebate-finder"             "rebate-finder"
test_key "github-rebate-finder-scrapers"    "rebate-finder-scrapers"
test_key "github-rebate-finder-deployement" "rebate-finder-deployement"

echo ""
hr
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All $PASS connections successful.${NC}"
  echo ""
  echo -e "  ${YELLOW}Next step:${NC}"
  echo -e "  ${BOLD}  bash scripts/setup-server.sh${NC}"
else
  echo -e "  ${RED}${BOLD}$FAIL connection(s) failed. $PASS passed.${NC}"
  echo ""
  echo -e "  Troubleshooting:"
  echo -e "  • Did you add the public key to GitHub? (Repo → Settings → Deploy keys)"
  echo -e "  • Check key permissions:  ls -la /home/$APP_USER/.ssh/"
  echo -e "  • Verbose test:           sudo -u $APP_USER ssh -vT github-rebate-finder"
  echo -e "  • Full guide:             docs/github-deploy-keys.md"
  exit 1
fi

echo ""
hr
