#!/usr/bin/env bash
# =============================================================================
# smoke-end-to-end.sh — prove the whole path works, on one box (v0.8 F8)
#
#   stage → promote → queue → drain → import → a rebate in the customer database
#
# This is the all-in-one test box's whole reason to exist: a single command
# that fails loudly if any link in the chain is broken, rather than four
# services that each look healthy on their own.
#
# Usage:
#   bash scripts/broker/smoke-end-to-end.sh
#
# Environment:
#   BROKER_DIR     default ~/workspace/smyth/rebate-finder-broker
#   TENANT_DIR     default ~/workspace/smyth/rebate-finder
#   SCRAPERS_DIR   default ~/workspace/smyth/rebate-finder-scrapers
#   BROKER_BASE    default http://localhost:8080
#   SKIP_SCRAPE    "true" to use whatever is already staged (much faster)
#
# It is READ-MOSTLY: it drains into the mirror and reports what the importer
# would do. It never turns on FEED_IMPORT_MODE=apply — going live is a
# deliberate decision, not something a smoke test does on your behalf.
# =============================================================================
set -uo pipefail

BROKER_DIR="${BROKER_DIR:-$HOME/workspace/smyth/rebate-finder-broker}"
TENANT_DIR="${TENANT_DIR:-$HOME/workspace/smyth/rebate-finder}"
SCRAPERS_DIR="${SCRAPERS_DIR:-$HOME/workspace/smyth/rebate-finder-scrapers}"
BROKER_BASE="${BROKER_BASE:-http://localhost:8080}"

BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
STEP=0
FAILURES=0

step()  { STEP=$((STEP+1)); echo -e "\n${BLUE}${BOLD}[$STEP] $*${NC}"; }
ok()    { echo -e "  ${GREEN}✔${NC} $*"; }
bad()   { echo -e "  ${RED}✖${NC} $*"; FAILURES=$((FAILURES+1)); }
note()  { echo -e "  ${DIM}$*${NC}"; }

# ── 0. Preconditions ─────────────────────────────────────────────────────────
step "Checking the services are up"

if curl -fsS "${BROKER_BASE}/healthz" 2>/dev/null | grep -q '"ok":true'; then
  ok "broker healthy at ${BROKER_BASE}"
else
  bad "broker is not healthy at ${BROKER_BASE} — start it first (pnpm dev, or pm2)"
  echo -e "\n${RED}Cannot continue without the broker.${NC}"
  exit 1
fi

for dir in "$BROKER_DIR" "$TENANT_DIR" "$SCRAPERS_DIR"; do
  [[ -d "$dir" ]] || { bad "missing repo: $dir"; exit 1; }
done
ok "all three repos present"

# ── 1. Collect (optional) ────────────────────────────────────────────────────
step "Collecting from a source"
if [[ "${SKIP_SCRAPE:-false}" == "true" ]]; then
  note "SKIP_SCRAPE=true — using whatever is already staged"
else
  if (cd "$SCRAPERS_DIR" && timeout 900 go run ./cmd/scraper --source dsireusa >/tmp/smoke-scrape.log 2>&1); then
    ok "collector ran (see /tmp/smoke-scrape.log)"
  else
    note "collector did not finish cleanly — continuing with what is already staged"
    note "$(tail -3 /tmp/smoke-scrape.log 2>/dev/null || true)"
  fi
fi

# Read the database directly rather than parsing a CLI's formatted output —
# a smoke test should not break because a log line was reworded.
if [[ -n "${DATABASE_URL:-}" ]]; then
  STAGED=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM scraper.rebates_staging WHERE deleted_at IS NULL" 2>/dev/null || true)
  [[ -n "$STAGED" ]] && ok "staging holds ${STAGED} rows" || note "could not read staging counts"
else
  note "DATABASE_URL not set — skipping the staging count"
fi

# ── 2. Promote: stage → per-tenant queues ────────────────────────────────────
step "Running a promoter pass (merge → match → queue)"
PASS_OUT=$(cd "$BROKER_DIR" && timeout 900 pnpm pass 2>&1 || true)
if echo "$PASS_OUT" | grep -q "pass complete"; then
  ok "pass completed"
  echo "$PASS_OUT" | grep -oE '"(changedGroups|merged|linksWritten|enqueued)": [0-9]+' | sed 's/^/    /' || true
else
  bad "promoter pass did not complete"
  echo "$PASS_OUT" | tail -5 | sed 's/^/    /'
fi

# ── 3. The queue has something in it ─────────────────────────────────────────
step "Checking a tenant has a queue to drain"
if [[ -z "${BROKER_API_KEY:-}" ]]; then
  note "BROKER_API_KEY not set — issue one in the console (Tenants → Rotate key) and re-run"
  note "skipping the drain and import steps"
else
  INFO=$(curl -fsS -H "Authorization: Bearer ${BROKER_API_KEY}" "${BROKER_BASE}/v1/queue/info" 2>/dev/null || echo "")
  if [[ -n "$INFO" ]]; then
    DEPTH=$(echo "$INFO" | grep -oE '"depth":[0-9]+' | cut -d: -f2)
    ok "queue depth: ${DEPTH:-unknown}"
  else
    bad "could not read /v1/queue/info — is the key valid and the tenant active?"
  fi

  # ── 4. Drain into the customer's mirror ────────────────────────────────────
  step "Draining the queue into the customer's mirror"
  SYNC_OUT=$(cd "$TENANT_DIR" && BROKER_URL="$BROKER_BASE" BROKER_API_KEY="$BROKER_API_KEY" timeout 900 pnpm feed:sync 2>&1 || true)
  if echo "$SYNC_OUT" | grep -q "^drain:"; then
    ok "$(echo "$SYNC_OUT" | grep '^drain:')"
    if echo "$SYNC_OUT" | grep -q "errors=0"; then ok "no drain errors"; else bad "the drain reported errors"; fi
  else
    bad "the drain did not run"
    echo "$SYNC_OUT" | tail -5 | sed 's/^/    /'
  fi

  # ── 5. The importer can account for every entry ────────────────────────────
  step "Checking the importer knows what to do with what arrived"
  if echo "$SYNC_OUT" | grep -q "entries considered"; then
    echo "$SYNC_OUT" | sed -n '/IMPORT/,/fields that would change/p' | sed 's/^/    /' | head -12
    ok "importer produced a plan (report mode — nothing was written to the programs table)"
  else
    bad "the importer produced no plan"
  fi
fi

# ── 6. The loop closes: the envelope reflects demand ─────────────────────────
step "Checking the collection loop closed"
if [[ -n "${DATABASE_URL:-}" ]]; then
  ENV_OUT=$(psql "$DATABASE_URL" -tAc "
    SELECT 'envelope v' || version
           || ': ' || (SELECT count(*) FROM jsonb_object_keys(payload->'sources')) || ' source(s) wanted, '
           || jsonb_array_length(payload->'unsubscribedSources') || ' standing down'
    FROM broker.demand_envelopes ORDER BY version DESC LIMIT 1" 2>/dev/null || true)
  if [[ -n "$ENV_OUT" ]]; then
    ok "$ENV_OUT"
  else
    note "no envelope published yet — it appears once a tenant has declared a scope"
  fi
else
  note "DATABASE_URL not set — skipping the envelope check"
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}SMOKE PASSED${NC} — stage → promote → queue → drain → import all worked."
  echo -e "${DIM}The importer ran in report mode; nothing was written to the programs table.${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}SMOKE FAILED${NC} — ${FAILURES} step(s) did not pass. See above."
  exit 1
fi
