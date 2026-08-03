#!/usr/bin/env bash
# =============================================================================
# provision-client.sh — Provision a new Incenva client deployment end-to-end.
#
# Loads secrets.local, validates all required tokens, prints a pre-flight
# summary, then hands off to scripts/provision.sh which does the actual work.
#
# Usage:
#   bash provision-client.sh
#
# Resume a failed run (skip Droplet creation, reconnect to existing server):
#   DROPLET_IP=167.x.x.x bash provision-client.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.local"

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n" >&2; exit 1; }
hr()   { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
label(){ printf "  %-28s" "$1"; }

# ── Load secrets.local ────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${BOLD}Incenva — New Client Deployment${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M %Z')"
echo ""

if [[ ! -f "$SECRETS_FILE" ]]; then
  fail "secrets.local not found.\n\n  Create it:\n    cp secrets.local.example secrets.local\n\n  Then fill in your values and run again."
fi

set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

# ── Pre-flight: validate and display configuration ────────────────────────────
hr
echo ""
echo -e "  ${BOLD}Pre-flight check${NC}"
echo ""

ERRORS=0

_check_required() {
  local name="$1" val="${!1:-}" display="${2:-}"
  label "$name"
  if [[ -n "$val" ]]; then
    # Show prefix only (first 8 chars) so you can confirm it's the right key
    local preview="${val:0:8}..."
    echo -e "${GREEN}✔${NC}  ${preview}${display:+  $display}"
  else
    echo -e "${RED}✗  not set${NC}  ← required"
    ERRORS=$((ERRORS + 1))
  fi
}

_check_optional() {
  local name="$1" val="${!1:-}" note="${2:-}"
  label "$name"
  if [[ -n "$val" ]]; then
    local preview="${val:0:8}..."
    echo -e "${GREEN}✔${NC}  ${preview}${note:+  ($note)}"
  else
    echo -e "${YELLOW}–${NC}  not set  ${note:+($note)}"
  fi
}

_check_plain() {
  local name="$1" val="${!1:-}" note="${2:-}"
  label "$name"
  if [[ -n "$val" ]]; then
    echo -e "${GREEN}✔${NC}  ${val}${note:+  $note}"
  else
    echo -e "${YELLOW}–${NC}  not set  ${note:+($note)}"
  fi
}

echo -e "  ${BOLD}Required tokens${NC}"
_check_required "DO_API_TOKEN"    "(DigitalOcean)"
_check_required "GITHUB_PAT"      "(GitHub — repo scope)"
_check_required "OPENAI_API_KEY"  "(OpenAI)"
echo ""

echo -e "  ${BOLD}Client config${NC}"
_check_plain "APP_DOMAIN"      "leave blank to use raw IP"
_check_plain "ADMIN_EMAIL"
_check_plain "ADMIN_NAME"
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  label "ADMIN_PASSWORD"; echo -e "${GREEN}✔${NC}  (set)"
else
  label "ADMIN_PASSWORD"; echo -e "${YELLOW}–${NC}  will be auto-generated"
fi
echo ""

echo -e "  ${BOLD}Fly.io scraper (Step 11)${NC}"
if [[ -n "${FLY_API_TOKEN:-}" ]]; then
  _check_required "FLY_API_TOKEN"  "(Fly.io)"
  _check_plain    "FLY_APP"        "(default: incenva-scraper)"
  _check_plain    "FLY_REGION"     "(default: iad)"
  _check_optional "REWIRING_AMERICA_API_KEY" "optional"
  if [[ -n "${SCRAPER_REPO_DIR:-}" ]]; then
    _check_plain  "SCRAPER_REPO_DIR"
  else
    label "SCRAPER_REPO_DIR"
    echo -e "${YELLOW}–${NC}  not set  (will auto-clone via GITHUB_PAT)"
  fi
  echo ""
  echo -e "  ${BLUE}→${NC}  PostgreSQL on the Droplet will be opened for external access"
  echo -e "  ${BLUE}→${NC}  DB URL sent to Fly.io: postgresql://rf:***@<DROPLET_IP>:5432/rebate_finder"
else
  label "FLY_API_TOKEN"
  echo -e "${YELLOW}–${NC}  not set  (Step 11 will be skipped)"
fi
echo ""

echo -e "  ${BOLD}Server config${NC}"
label "DO_REGION";  echo -e "${BLUE}→${NC}  ${DO_REGION:-nyc1}  (default)"
label "DO_SIZE";    echo -e "${BLUE}→${NC}  ${DO_SIZE:-s-2vcpu-4gb}  (default)"
if [[ -n "${DO_SSH_KEY_IDS:-}" ]]; then
  _check_plain "DO_SSH_KEY_IDS" "for direct SSH access after provisioning"
else
  label "DO_SSH_KEY_IDS"; echo -e "${YELLOW}–${NC}  not set  (you won't be able to SSH in directly)"
fi

if [[ -n "${DROPLET_IP:-}" ]]; then
  echo ""
  warn "DROPLET_IP=${DROPLET_IP} — skipping Droplet creation, reconnecting to existing server"
fi

echo ""

# ── Abort if required vars are missing ───────────────────────────────────────
if [[ $ERRORS -gt 0 ]]; then
  fail "$ERRORS required variable(s) not set.\nEdit secrets.local and run again."
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${BOLD}Ready to provision.${NC}"
echo -e "  This will create a live DigitalOcean server and may incur costs."
echo ""
echo -n "  Continue? [y/N] "
read -r CONFIRM < /dev/tty
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "  Aborted."
  exit 0
fi

# ── Hand off to provision.sh ──────────────────────────────────────────────────
hr
START_TIME=$(date +%s)

exec bash "$SCRIPT_DIR/scripts/provision.sh" "$@"

# (exec replaces the process — nothing below runs)
# The final timing is printed here only if provision.sh exits cleanly and this
# script regains control, which won't happen with exec. Timing is shown inside
# provision.sh's done block instead.
