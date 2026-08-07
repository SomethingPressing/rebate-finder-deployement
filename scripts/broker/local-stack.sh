#!/usr/bin/env bash
# =============================================================================
# local-stack.sh — bring the whole v0.8 system up locally, under PM2
#
#   ./local-stack.sh up       build and start everything
#   ./local-stack.sh down     stop and remove the processes
#   ./local-stack.sh status   what is running, and is it healthy
#   ./local-stack.sh logs     tail everything
#
# Three processes:
#   incenva-broker            Next.js: super-admin console + /v1 wire contract
#   incenva-broker-promoter   the promoter worker (BullMQ)
#   incenva-rebate-finder     the customer site, with its drain scheduler
#
# The tenant app is started only if it has a .env; a machine that is only
# working on the broker does not need it.
#
# Environment (all optional):
#   BROKER_PORT              default 8080
#   TENANT_PORT              default 3000
#   BROKER_ADMIN_PASSWORD    default "local-dev" — the console is locked without one
#   PROMOTER_WRITE_MODE      default shadow. Leave it there while testing:
#                            the promoter writes a comparison table instead of
#                            the live queues, so nothing it does is destructive.
# =============================================================================
set -uo pipefail

ROOT="${ROOT:-$HOME/workspace/smyth}"
BROKER_DIR="$ROOT/rebate-finder-broker"
TENANT_DIR="$ROOT/rebate-finder"
BROKER_PORT="${BROKER_PORT:-8080}"
TENANT_PORT="${TENANT_PORT:-3000}"

BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
bad()  { echo -e "  ${RED}✖${NC} $*"; }
note() { echo -e "  ${DIM}$*${NC}"; }

need_pm2() {
  command -v pm2 >/dev/null || { bad "pm2 not installed — npm install -g pm2"; exit 1; }
}

check_services() {
  pg_isready -q 2>/dev/null && ok "Postgres accepting connections" || bad "Postgres is not accepting connections"
  redis-cli ping >/dev/null 2>&1 && ok "Redis answering" || warn "Redis is not answering — the promoter will pause, everything else still works"
}

up() {
  need_pm2
  log "Checking what this stack depends on"
  check_services

  [[ -f "$BROKER_DIR/.env" ]] || { bad "no $BROKER_DIR/.env — copy .env.example and point DATABASE_URL at your staging database"; exit 1; }
  ok "broker .env present"

  log "Building the broker"
  (cd "$BROKER_DIR" && pnpm install --silent && pnpm build) || { bad "broker build failed"; exit 1; }
  ok "built"

  log "Starting the broker (app + promoter worker)"
  (cd "$BROKER_DIR" && \
    PORT="$BROKER_PORT" \
    BROKER_ADMIN_PASSWORD="${BROKER_ADMIN_PASSWORD:-local-dev}" \
    PROMOTER_WRITE_MODE="${PROMOTER_WRITE_MODE:-shadow}" \
    pm2 start ecosystem.config.cjs --update-env >/dev/null) || { bad "pm2 could not start the broker"; exit 1; }
  ok "incenva-broker + incenva-broker-promoter"

  if [[ -f "$TENANT_DIR/.env" ]]; then
    log "Starting the customer site"
    (cd "$TENANT_DIR" && pm2 delete incenva-rebate-finder >/dev/null 2>&1; \
      PORT="$TENANT_PORT" pm2 start "pnpm start" --name incenva-rebate-finder --update-env >/dev/null) \
      && ok "incenva-rebate-finder on :$TENANT_PORT" \
      || warn "could not start the customer site — start it by hand if you need it"
  else
    note "no $TENANT_DIR/.env — skipping the customer site"
  fi

  pm2 save >/dev/null 2>&1
  sleep 4
  status
}

status() {
  log "Status"
  pm2 list 2>/dev/null | grep -E "incenva|name" || note "nothing running under pm2"

  echo ""
  if curl -fsS "http://localhost:${BROKER_PORT}/healthz" 2>/dev/null | grep -q '"ok":true'; then
    ok "broker healthy — console at http://localhost:${BROKER_PORT}"
  else
    bad "broker /healthz is not healthy — pm2 logs incenva-broker --lines 40"
  fi

  MODE=$(grep -E '^PROMOTER_WRITE_MODE=' "$BROKER_DIR/.env" 2>/dev/null | cut -d= -f2)
  MODE="${PROMOTER_WRITE_MODE:-${MODE:-shadow}}"
  if [[ "$MODE" == "live" ]]; then
    warn "promoter write mode is LIVE — it writes the real per-tenant queues"
  else
    ok "promoter write mode is shadow — nothing it writes can affect a tenant"
  fi

  echo ""
  note "console   http://localhost:${BROKER_PORT}"
  note "contract  http://localhost:${BROKER_PORT}/v1/queue/info  (needs a tenant bearer key)"
  note "site      http://localhost:${TENANT_PORT}"
  echo ""
  note "next:  cd $BROKER_DIR && pnpm promote        # route staged rows into queues"
  note "       cd $TENANT_DIR && pnpm feed:sync      # drain them and report"
  note "       bash scripts/broker/smoke-end-to-end.sh   # the whole path at once"
}

down() {
  need_pm2
  log "Stopping"
  pm2 delete incenva-broker incenva-broker-promoter incenva-rebate-finder >/dev/null 2>&1
  pm2 save >/dev/null 2>&1
  ok "stopped and removed"
}

case "${1:-status}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  logs)   pm2 logs incenva-broker incenva-broker-promoter incenva-rebate-finder ;;
  *)      echo "usage: $0 {up|down|status|logs}"; exit 1 ;;
esac
