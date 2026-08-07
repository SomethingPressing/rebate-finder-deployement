#!/usr/bin/env bash
# =============================================================================
# deploy.sh — pull, rebuild and restart the broker on the staging host
#
# Code only. It never touches the .env, never migrates the collectors' schema
# (that belongs to the Go models), and never changes PROMOTER_WRITE_MODE —
# going live is a deliberate, separate decision, not a side effect of a deploy.
#
# Usage:
#   bash scripts/broker/deploy.sh
#
# Overrides:
#   APP_DIR=/custom/path bash scripts/broker/deploy.sh
#   BRANCH=some-branch   bash scripts/broker/deploy.sh
#
# Safe to run repeatedly.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[broker-deploy]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✖${NC} $*" >&2; exit 1; }

APP_DIR="${APP_DIR:-/opt/rebate-finder-broker}"
BRANCH="${BRANCH:-main}"

[[ -d "$APP_DIR/.git" ]] || fail "no checkout at $APP_DIR — run scripts/broker/setup-staging-host.sh first"
cd "$APP_DIR"

log "Fetching ${BRANCH}"
git fetch --quiet origin "$BRANCH"
BEFORE=$(git rev-parse --short HEAD)
git reset --hard --quiet "origin/${BRANCH}"
AFTER=$(git rev-parse --short HEAD)
if [[ "$BEFORE" == "$AFTER" ]]; then
  ok "already at ${AFTER} — redeploying anyway"
else
  ok "${BEFORE} → ${AFTER}"
fi

log "Installing dependencies"
pnpm install --frozen-lockfile --silent

log "Building"
pnpm build

# The promoter holds a Postgres advisory lock while a pass runs. Restarting
# mid-pass is safe — the lock is released with the connection and the next pass
# simply redoes the work — but stopping the worker first keeps the logs clean
# and avoids a pass being killed halfway through its writes.
log "Restarting under PM2"
if pm2 describe incenva-broker-promoter >/dev/null 2>&1; then
  pm2 stop incenva-broker-promoter >/dev/null
fi
pm2 restart ecosystem.config.cjs --update-env >/dev/null 2>&1 || pm2 start ecosystem.config.cjs >/dev/null
pm2 save >/dev/null
ok "processes restarted"

log "Checking health"
PORT=$(grep -E '^PORT=' .env 2>/dev/null | cut -d= -f2)
PORT="${PORT:-8080}"
sleep 4
if curl -fsS "http://localhost:${PORT}/healthz" | grep -q '"ok":true'; then
  ok "/healthz reports healthy"
else
  warn "/healthz is not healthy — check: pm2 logs incenva-broker --lines 50"
fi

MODE=$(grep -E '^PROMOTER_WRITE_MODE=' .env 2>/dev/null | cut -d= -f2 || echo shadow)
echo ""
ok "deployed ${AFTER} — promoter write mode: ${MODE:-shadow}"
[[ "${MODE:-shadow}" == "shadow" ]] && echo "  (shadow mode: the promoter writes a comparison table, not the live queues)"
