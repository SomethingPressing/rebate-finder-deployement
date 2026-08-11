#!/usr/bin/env bash
# =============================================================================
# connect-tenant.sh — point one customer site at the broker
#
# The step between "the staging host is up" and "this customer is being served
# by it". Run once per tenant, on the STAGING HOST.
#
# It does the parts that are easy to get wrong and stops at the parts a person
# has to decide:
#
#   · registers the tenant under an id you supply and issues its key
#   · prints the exact lines to add to that customer's .env
#   · checks whether the id it was given is one the old path already knows
#
# That last check is the one worth having. A tenant adopted under a NEW id is
# invisible to the shadow comparison forever — the comparison lines the two
# paths up BY TENANT ID, so a mismatch does not produce a wrong answer, it
# produces no answer at all, and nothing ever says why.
#
# Usage:
#   bash scripts/broker/connect-tenant.sh
#   TENANT_ID=c1ea2000-... TENANT_NAME="Acme" bash scripts/broker/connect-tenant.sh
#
# Safe to run again: re-running for an existing tenant rotates its key.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[connect-tenant]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✖${NC} $*" >&2; exit 1; }

APP_DIR="${APP_DIR:-/opt/rebate-finder-broker}"
[[ -d "$APP_DIR" ]] || fail "no broker at $APP_DIR — run scripts/broker/setup-staging-host.sh first"
cd "$APP_DIR"

DB_URL=$(grep -E '^DATABASE_URL=' .env | cut -d= -f2- | tr -d '"')
PORT=$(grep -E '^PORT=' .env | cut -d= -f2 || echo 8080)
[[ -n "$DB_URL" ]] || fail "DATABASE_URL is missing from $APP_DIR/.env"

psql_q() { psql "${DB_URL%%\?*}" -tAc "$1"; }

# ── Which tenant ─────────────────────────────────────────────────────────────
if [[ -z "${TENANT_ID:-}" ]]; then
  echo ""
  echo "Tenants the OLD direct-write path already knows:"
  psql_q "SELECT '  ' || tenant_id || '  (' || count(*) || ' rows)'
          FROM scraper.rebate_tenant_status GROUP BY tenant_id ORDER BY count(*) DESC" || true
  echo ""
  echo "Use the customer's OWN client id — the one in its scraper_source_configs."
  echo "A different id makes the shadow comparison permanently 'not comparable'."
  echo ""
  read -rp "Tenant id: " TENANT_ID
fi
[[ -n "$TENANT_ID" ]] || fail "a tenant id is required"
TENANT_NAME="${TENANT_NAME:-$TENANT_ID}"

# ── Is this id one the old path knows? ───────────────────────────────────────
KNOWN=$(psql_q "SELECT count(*) FROM scraper.rebate_tenant_status WHERE tenant_id = '${TENANT_ID//\'/\'\'}'")
if [[ "$KNOWN" == "0" ]]; then
  warn "the old path has no rows for '${TENANT_ID}'."
  warn "That is correct for a brand-new customer, and WRONG for one that already exists —"
  warn "in that case the shadow comparison will never be able to line the two paths up."
  read -rp "Continue anyway? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || fail "stopped"
else
  ok "the old path knows this id (${KNOWN} rows) — the comparison will be able to line up"
fi

# ── Register and issue a key ─────────────────────────────────────────────────
log "Registering ${TENANT_NAME}"
# stderr is shown, not swallowed: the previous version hid the real failure
# behind 2>/dev/null and reported a generic message the operator could not act
# on. Only the key comes back on stdout.
KEY=$(TENANT_ID="$TENANT_ID" TENANT_NAME="$TENANT_NAME" pnpm --silent exec tsx scripts/register-tenant.ts) \
  || fail "registration failed — see the error above, or use the console at https://${APP_DOMAIN:-localhost:$PORT}/tenants"
[[ -n "$KEY" ]] || fail "no key was issued"
ok "registered, key issued (shown once)"

BASE="https://$(hostname -f 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<SUMMARY

$(printf '\033[1;32m─── add these to the customer site'"'"'s .env ───\033[0m')

BROKER_URL=${BASE}
BROKER_API_KEY=${KEY}

$(printf '\033[1;33m  Copy the key now — only its SHA-256 hash is kept here.\033[0m')

  BROKER_URL must be https once this host has a certificate. A tenant site
  REFUSES plain HTTP to a public host unless BROKER_ALLOW_INSECURE=true, which
  exists for development and should not be used here.

  Then, on the customer's machine:
    pm2 restart "Rebate Finder"     # picks up the new .env
    pnpm feed:sync                  # declares its scope and drains once

  Back here, within a minute or two:
    console → Tenants   the site shows "online" once it starts beating
    console → Tenants → ${TENANT_ID} → Pipeline
                        watch collected → staged → routed → queued → drained

  Still shadow mode: the promoter writes a comparison table, not the live
  queues. Leave it there until console → Comparison is clean run after run.

SUMMARY
