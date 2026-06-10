#!/usr/bin/env bash
# =============================================================================
# diagnose.sh — Prod diagnostic: PM2, DB state, scraper logs, binary version
#
# Usage (on the server, as root or rf):
#   bash scripts/diagnose.sh
# =============================================================================

set -uo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
section() { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "  ${RED}✖${NC}  $*"; }
info()    { echo -e "     $*"; }

SCRAPER_DIR="${SCRAPER_DIR:-/home/rf/apps/incenva-scraper-service}"
APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$SCRAPER_DIR/.env"

# Use plain pm2 if already running as rf, otherwise sudo -u rf pm2
if [[ "$(whoami)" == "rf" ]]; then
  PM2="pm2"
  GIT="git"
else
  PM2="sudo -u rf pm2"
  GIT="$GIT"
fi

# ── 1. PM2 process status ────────────────────────────────────────────────────
section "PM2 processes (rf daemon)"
$PM2 list 2>/dev/null || fail "Could not reach rf's PM2 daemon"

# ── 2. Binary version / build date ──────────────────────────────────────────
section "Scraper binary"
BINARY="$SCRAPER_DIR/bin/scraper"
if [[ -f "$BINARY" ]]; then
  ok "Binary exists"
  info "Path    : $BINARY"
  info "Modified: $(stat -c '%y' "$BINARY" | cut -d'.' -f1)"
  info "Size    : $(du -sh "$BINARY" | cut -f1)"
else
  fail "Binary NOT found at $BINARY"
fi

# ── 3. Git state ─────────────────────────────────────────────────────────────
section "Git state (scraper repo)"
if [[ -d "$SCRAPER_DIR/.git" ]]; then
  cd "$SCRAPER_DIR"
  info "Branch  : $($GIT rev-parse --abbrev-ref HEAD 2>/dev/null)"
  info "Commit  : $($GIT log -1 --format='%h %s' 2>/dev/null)"
  info "Date    : $($GIT log -1 --format='%ci' 2>/dev/null)"
  DIRTY=$($GIT status --porcelain 2>/dev/null | wc -l)
  if [[ "$DIRTY" -gt 0 ]]; then
    warn "$DIRTY uncommitted change(s)"
  else
    ok "Working tree clean"
  fi
  # Check if local is behind remote
  $GIT fetch origin main --quiet 2>/dev/null || true
  BEHIND=$($GIT rev-list HEAD..origin/main --count 2>/dev/null || echo "?")
  if [[ "$BEHIND" == "0" ]]; then
    ok "Up to date with origin/main"
  else
    warn "$BEHIND commit(s) behind origin/main — need to deploy"
  fi
  cd - >/dev/null
fi

# ── 4. Database connectivity ─────────────────────────────────────────────────
section "Database connectivity"
if [[ -f "$ENV_FILE" ]]; then
  DB_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
  if psql "$DB_URL" -c "SELECT 1" --quiet --tuples-only 2>/dev/null | grep -q 1; then
    ok "Database reachable"
  else
    fail "Cannot connect to database"
    info "DATABASE_URL: $(echo "$DB_URL" | sed 's/:\/\/[^:]*:[^@]*@/:\/\/*****:*****@/')"
  fi
else
  fail ".env not found at $ENV_FILE"
fi

# ── 5. Scraper source config state ───────────────────────────────────────────
section "scraper_source_configs (current state)"
psql "$DB_URL" --tuples-only --no-align -F' | ' 2>/dev/null <<'SQL'
SELECT
  source,
  active,
  schedule,
  last_run_status,
  to_char(last_run_at, 'YYYY-MM-DD HH24:MI:SS') AS last_run_at,
  last_run_count,
  left(last_run_error, 80) AS error_snippet
FROM scraper_source_configs
ORDER BY source;
SQL

# ── 6. Recent run logs ───────────────────────────────────────────────────────
section "scraper_run_logs (last 20 runs)"
psql "$DB_URL" --tuples-only --no-align -F' | ' 2>/dev/null <<'SQL'
SELECT
  to_char(started_at, 'MM-DD HH24:MI:SS') AS started,
  source,
  status,
  program_count    AS count,
  duration_s       AS secs,
  triggered_by     AS by,
  to_char(last_heartbeat_at, 'HH24:MI:SS') AS last_hb,
  left(error, 100) AS error
FROM scraper_run_logs
ORDER BY started_at DESC
LIMIT 20;
SQL

# ── 7. Any runs still stuck in 'running' ────────────────────────────────────
section "Stuck runs (status = running)"
STUCK=$(psql "$DB_URL" --tuples-only --no-align 2>/dev/null \
  -c "SELECT count(*) FROM scraper_run_logs WHERE status = 'running'")
if [[ "${STUCK:-0}" -gt 0 ]]; then
  warn "$STUCK run(s) still marked 'running' in DB"
  psql "$DB_URL" --tuples-only --no-align -F' | ' 2>/dev/null <<'SQL'
    SELECT id, source, to_char(started_at,'MM-DD HH24:MI:SS') AS started,
           to_char(last_heartbeat_at,'HH24:MI:SS') AS last_hb
    FROM scraper_run_logs WHERE status = 'running';
SQL
else
  ok "No stuck runs"
fi

# ── 7b. Next.js app restart count warning ───────────────────────────────────
section "Next.js app health"
RESTARTS=$($PM2 describe "incenva-rebate-finder" 2>/dev/null \
  | grep -E 'restart time' | awk '{print $NF}' | head -1)
if [[ -n "$RESTARTS" && "$RESTARTS" -gt 10 ]]; then
  warn "incenva-rebate-finder has restarted ${RESTARTS} times — likely crash-looping"
  info "Last 30 lines of Next.js error log:"
  $PM2 logs "incenva-rebate-finder" --lines 30 --err --nostream 2>/dev/null || true
else
  ok "incenva-rebate-finder restart count: ${RESTARTS:-unknown}"
fi

# ── 8. Last 60 lines of scraper PM2 logs ────────────────────────────────────
section "Recent scraper logs (last 60 lines)"
LOG_PATH=$($PM2 describe incenva-scraper 2>/dev/null \
  | grep -E 'error file|out file' | head -1 | awk '{print $NF}')
if [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]]; then
  info "Log file: $LOG_PATH"
  tail -60 "$LOG_PATH"
else
  # Fall back to pm2 logs output
  warn "Could not locate log file — using pm2 logs (last 60 lines)"
  $PM2 logs incenva-scraper --lines 60 --nostream 2>/dev/null || true
fi

# ── 9. Env sanity check (no secrets printed) ─────────────────────────────────
section "Environment sanity (.env key presence)"
for KEY in DATABASE_URL SCRAPER_INTERVAL LOG_LEVEL; do
  if grep -qE "^${KEY}=" "$ENV_FILE" 2>/dev/null; then
    ok "$KEY is set"
  else
    warn "$KEY is MISSING from .env"
  fi
done
OPENAI=$(grep -cE '^OPENAI_API_KEY=.' "$ENV_FILE" 2>/dev/null || echo 0)
[[ "$OPENAI" -gt 0 ]] && ok "OPENAI_API_KEY is set" || warn "OPENAI_API_KEY not set (AI inferrers disabled)"

echo ""
echo -e "${GREEN}${BOLD}Diagnostic complete.${NC}"
echo ""
