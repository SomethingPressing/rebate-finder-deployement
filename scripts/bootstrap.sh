#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Single entry point. Sets up everything on a blank Ubuntu server.
#
# What it does (each step is skipped if already complete):
#   1.  Install system packages (git, curl, nginx, ufw, etc.)
#   2.  Create the rf system user
#   3.  Generate GitHub SSH deploy keys
#   4.  Write SSH config
#   5.  Print public keys — PAUSE for you to add them to GitHub
#   6.  Verify all three GitHub connections
#   7.  Clone this deployment repo
#   8.  Run Next.js app setup   (Node, pnpm, PM2, Postgres, build, start)
#   9.  Run Go scraper setup    (Go, build binaries)
#   10. Configure nginx reverse proxy (port 80 → localhost:3000)
#   11. Obtain SSL certificate via Let's Encrypt (Certbot) — skipped if no domain
#
# Usage (run as root on a fresh Ubuntu 22.04 VPS):
#   APP_DOMAIN=dev.incenva.com curl -fsSL https://raw.githubusercontent.com/SomethingPressing/rebate-finder-deployement/main/scripts/bootstrap.sh | sudo bash
#
#   OR after copying this file manually:
#   sudo bash bootstrap.sh dev.incenva.com
#
# Idempotent — safe to re-run. Already-completed steps are skipped.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "\n${BLUE}━━━${NC} ${BOLD}$*${NC}"; }
ok()    { echo -e "  ${GREEN}✔${NC}  $*"; }
skip()  { echo -e "  ${YELLOW}─${NC}  $* (already done, skipping)"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
info()  { echo -e "  ${BLUE}→${NC}  $*"; }
fail()  { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()    { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
pause() { echo -e "\n${YELLOW}${BOLD}$*${NC}"; read -rp "  Press Enter when done... " < /dev/tty; }

# ── Root guard ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0"

# ── Domain ────────────────────────────────────────────────────────────────────
# Accept as: first positional arg, APP_DOMAIN env var, or interactive prompt.
APP_DOMAIN="${1:-${APP_DOMAIN:-}}"
if [[ -z "$APP_DOMAIN" ]]; then
  read -rp "  App domain (e.g. dev.incenva.com) — press Enter to use catch-all: " APP_DOMAIN < /dev/tty
fi
APP_DOMAIN="${APP_DOMAIN:-_}"

# ── Config ────────────────────────────────────────────────────────────────────
APP_USER="${APP_USER:-rf}"
SSH_DIR="/home/$APP_USER/.ssh"
APPS_DIR="/home/$APP_USER/apps"
DEPLOY_DIR="$APPS_DIR/deployment"
APP_DIR="$APPS_DIR/rebate-finder"
SCRAPER_DIR="$APPS_DIR/incenva-scraper-service"

DEPLOY_REPO="git@github-rebate-finder-deployement:SomethingPressing/rebate-finder-deployement.git"
APP_REPO="git@github-rebate-finder:SomethingPressing/rebate-finder.git"
SCRAPER_REPO="git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git"

hr
echo ""
echo -e "  ${BOLD}Incenva — Full Server Setup${NC}"
echo -e "  Ubuntu $(lsb_release -rs 2>/dev/null || echo '?')  •  $(date '+%Y-%m-%d %H:%M')"
echo -e "  App user:  ${BOLD}$APP_USER${NC}"
echo -e "  Domain:    ${BOLD}$APP_DOMAIN${NC}"
echo ""
echo -e "  This script is idempotent — already-completed steps are skipped."
hr

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — System packages
# ═════════════════════════════════════════════════════════════════════════════
log "Step 1/11 — System packages"

apt-get update -qq
PACKAGES=(git curl wget unzip openssh-client ufw ca-certificates gnupg
          lsb-release software-properties-common nginx)

MISSING=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  skip "All packages already installed"
else
  info "Installing: ${MISSING[*]}"
  apt-get install -y "${MISSING[@]}" >/dev/null
  ok "Packages installed"
fi

ok "git $(git --version | awk '{print $3}')"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — System user
# ═════════════════════════════════════════════════════════════════════════════
log "Step 2/11 — System user '$APP_USER'"

if getent group "$APP_USER" &>/dev/null; then
  skip "Group '$APP_USER'"
else
  groupadd --system "$APP_USER"
  ok "Created group '$APP_USER'"
fi

if id "$APP_USER" &>/dev/null; then
  skip "User '$APP_USER'"
else
  useradd \
    --system \
    --gid "$APP_USER" \
    --shell /bin/bash \
    --home-dir "/home/$APP_USER" \
    --create-home \
    "$APP_USER"
  ok "Created user '$APP_USER'"
fi

mkdir -p "$APPS_DIR"
chown "$APP_USER:$APP_USER" "$APPS_DIR"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — SSH deploy keys
# ═════════════════════════════════════════════════════════════════════════════
log "Step 3/11 — GitHub SSH deploy keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$APP_USER:$APP_USER" "$SSH_DIR"

KEYS_NEW=0   # incremented each time a key is freshly generated

_gen_key() {
  local name="$1" label="$2"
  local key_file="$SSH_DIR/id_ed25519_${name}"
  if [[ -f "$key_file" ]]; then
    skip "Key: $label"
  else
    ssh-keygen -t ed25519 -C "$APP_USER@$(hostname):$label" -f "$key_file" -N "" >/dev/null 2>&1
    ok "Generated: $label"
    KEYS_NEW=$((KEYS_NEW + 1))
  fi
  chown "$APP_USER:$APP_USER" "$key_file" "${key_file}.pub"
  chmod 600 "$key_file"
  chmod 644 "${key_file}.pub"
}

_gen_key "rebate_finder"             "rebate-finder"
_gen_key "rebate_finder_scrapers"    "rebate-finder-scrapers"
_gen_key "rebate_finder_deployement" "rebate-finder-deployement"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — SSH config
# ═════════════════════════════════════════════════════════════════════════════
log "Step 4/11 — SSH config"

cat > "$SSH_DIR/config" << EOF
# Auto-generated by bootstrap.sh

Host github-rebate-finder
    HostName github.com
    User git
    IdentityFile $SSH_DIR/id_ed25519_rebate_finder
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host github-rebate-finder-scrapers
    HostName github.com
    User git
    IdentityFile $SSH_DIR/id_ed25519_rebate_finder_scrapers
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host github-rebate-finder-deployement
    HostName github.com
    User git
    IdentityFile $SSH_DIR/id_ed25519_rebate_finder_deployement
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF

chown "$APP_USER:$APP_USER" "$SSH_DIR/config"
chmod 600 "$SSH_DIR/config"
ok "Written $SSH_DIR/config"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — Print public keys and wait for GitHub (only if new keys were created)
# ═════════════════════════════════════════════════════════════════════════════
log "Step 5/11 — Add public keys to GitHub"

declare -a KEY_NAMES=("rebate_finder" "rebate_finder_scrapers" "rebate_finder_deployement")
declare -a REPO_SLUGS=("rebate-finder" "rebate-finder-scrapers" "rebate-finder-deployement")

if [[ $KEYS_NEW -eq 0 ]]; then
  skip "All keys already existed — skipping GitHub upload step"
else
  echo ""
  echo -e "  For each repo below:"
  echo -e "  1. Open the GitHub link"
  echo -e "  2. Click  ${BOLD}Add deploy key${NC}"
  echo -e "  3. Title: ${BOLD}rf@$(hostname)${NC}"
  echo -e "  4. Paste the public key"
  echo -e "  5. Leave 'Allow write access' ${BOLD}unchecked${NC}"
  echo -e "  6. Click  ${BOLD}Add key${NC}"
  echo ""

  for i in 0 1 2; do
    slug="${REPO_SLUGS[$i]}"
    key_file="$SSH_DIR/id_ed25519_${KEY_NAMES[$i]}.pub"
    echo -e "  ${BOLD}▸ $slug${NC}"
    echo -e "  ${BLUE}https://github.com/SomethingPressing/$slug/settings/keys${NC}"
    echo ""
    echo "    $(cat "$key_file")"
    echo ""
  done

  pause "Add all three keys to GitHub, then press Enter to continue."
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — Verify GitHub connections
# ═════════════════════════════════════════════════════════════════════════════
log "Step 6/11 — Verify GitHub connections"

_test_key() {
  local alias="$1" label="$2"
  local out
  out=$(sudo -u "$APP_USER" ssh -T "$alias" </dev/null 2>&1 || true)
  if echo "$out" | grep -q "successfully authenticated"; then
    ok "$label"
    return 0
  else
    return 1
  fi
}

RETRIES=3
for attempt in $(seq 1 $RETRIES); do
  FAILED=0
  _test_key "github-rebate-finder"             "rebate-finder"             || FAILED=$((FAILED+1))
  _test_key "github-rebate-finder-scrapers"    "rebate-finder-scrapers"    || FAILED=$((FAILED+1))
  _test_key "github-rebate-finder-deployement" "rebate-finder-deployement" || FAILED=$((FAILED+1))

  if [[ $FAILED -eq 0 ]]; then
    break
  fi

  if [[ $attempt -lt $RETRIES ]]; then
    warn "$FAILED connection(s) failed. Make sure all keys are added on GitHub."
    pause "Fix the keys on GitHub, then press Enter to try again."
  else
    fail "$FAILED GitHub connection(s) still failing after $RETRIES attempts.\nSee docs/github-deploy-keys.md for troubleshooting."
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 — Clone deployment repo
# ═════════════════════════════════════════════════════════════════════════════
log "Step 7/11 — Clone deployment repo"

if [[ -d "$DEPLOY_DIR/.git" ]]; then
  skip "Deployment repo already at $DEPLOY_DIR"
  sudo -u "$APP_USER" git -C "$DEPLOY_DIR" pull --ff-only
  ok "git pull done"
else
  sudo -u "$APP_USER" git clone "$DEPLOY_REPO" "$DEPLOY_DIR"
  ok "Cloned → $DEPLOY_DIR"
fi

SCRIPT_DIR="$DEPLOY_DIR/scripts"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 — Next.js app setup
# ═════════════════════════════════════════════════════════════════════════════
log "Step 8/11 — Next.js app (Node, pnpm, PM2, PostgreSQL, build)"

APP_REPO_URL="$APP_REPO" APP_DOMAIN="$APP_DOMAIN" bash "$SCRIPT_DIR/rebate-finder/setup-server.sh"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 9 — Go scraper setup
# ═════════════════════════════════════════════════════════════════════════════
log "Step 9/11 — Go scraper service"

APP_REPO_URL="$SCRAPER_REPO" bash "$SCRIPT_DIR/scraper/setup-server.sh"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 10 — Nginx reverse proxy
# ═════════════════════════════════════════════════════════════════════════════
log "Step 10/11 — Nginx reverse proxy (port 80 → localhost:3000)"

# SKIP_SSL=true — bootstrap handles SSL itself in step 11
APP_DOMAIN="$APP_DOMAIN" SKIP_SSL=true bash "$SCRIPT_DIR/setup-nginx.sh"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 11 — SSL / Let's Encrypt
# ═════════════════════════════════════════════════════════════════════════════
log "Step 11/11 — SSL / Let's Encrypt"

if [[ "$APP_DOMAIN" == "_" ]]; then
  warn "No domain set — skipping SSL setup."
  warn "To add SSL later: sudo APP_DOMAIN=dev.incenva.com bash $SCRIPT_DIR/setup-ssl.sh"
else
  APP_DOMAIN="$APP_DOMAIN" APP_USER="$APP_USER" bash "$SCRIPT_DIR/setup-ssl.sh"
fi

# ═════════════════════════════════════════════════════════════════════════════
# DONE — Print next steps
# ═════════════════════════════════════════════════════════════════════════════
hr
echo ""
echo -e "  ${GREEN}${BOLD}Server setup complete!${NC}"
echo ""
if [[ "$APP_DOMAIN" != "_" ]]; then
  echo -e "  ${BOLD}App URL:${NC}  https://$APP_DOMAIN"
else
  echo -e "  ${BOLD}App URL:${NC}  http://<server-ip>  (no domain set)"
fi
echo ""
echo -e "  ${BOLD}Check app status:${NC}"
echo -e "    pm2 status"
echo -e "    pm2 logs incenva-rebate-finder"
echo ""
echo -e "  ${BOLD}Fill in remaining .env values:${NC}"
echo -e "    nano $APP_DIR/.env"
echo -e "    # Required: NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY,"
echo -e "    #           SUPABASE_SERVICE_KEY, OPENAI_API_KEY"
echo ""
echo -e "    nano $SCRAPER_DIR/.env"
echo -e "    # Required: REWIRING_AMERICA_API_KEY"
echo ""
echo -e "  ${BOLD}Rebuild after editing .env:${NC}"
echo -e "    bash $SCRIPT_DIR/rebate-finder/deploy.sh"
echo ""
echo -e "  ${BOLD}Load seed data (run once as sysadmin when ready):${NC}"
echo -e "    bash $SCRIPT_DIR/rebate-finder/seed.sh"
echo ""
echo -e "  ${BOLD}Add an admin user:${NC}"
echo -e "    bash $SCRIPT_DIR/rebate-finder/create-admin.sh email@example.com Pass123! \"Name\" super_admin"
hr
echo ""
