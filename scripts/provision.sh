#!/usr/bin/env bash
# =============================================================================
# provision.sh — End-to-end Incenva deployment orchestrator
#
# Creates a DigitalOcean Droplet, waits for it to come online, runs the full
# bootstrap with automatic GitHub deploy key registration, injects env vars,
# seeds the database, and creates the first admin user.
#
# ── Required env vars ──────────────────────────────────────────────────────────
#   DO_API_TOKEN      DigitalOcean API token
#                     → https://cloud.digitalocean.com/account/api/tokens
#   GITHUB_PAT        GitHub personal access token
#                     Needs: repo scope (classic) — used to register deploy keys
#                     → https://github.com/settings/tokens
#   OPENAI_API_KEY    OpenAI API key for AI features
#
# ── Optional env vars ─────────────────────────────────────────────────────────
#   APP_DOMAIN        Client domain (e.g. acme.incenva.com). DNS must already
#                     point at the Droplet IP before bootstrap can obtain SSL.
#                     If omitted, app starts on HTTP at the raw IP.
#   CLIENT_NAME       Short slug for the Droplet name (default: derived from APP_DOMAIN)
#   DO_REGION         DigitalOcean region slug (default: nyc1)
#   DO_SIZE           Droplet size slug (default: s-2vcpu-4gb)
#   DO_SSH_KEY_IDS    Comma-separated DO SSH key IDs to add to the Droplet
#                     so you can SSH in directly after provisioning.
#                     Find yours: doctl compute ssh-key list
#   BREVO_API_KEY     Email service API key (for notification emails)
#   BREVO_SENDER_EMAIL  From address for notification emails
#   GTM_ID            Google Tag Manager ID (e.g. GTM-XXXXXXX)
#   ADMIN_EMAIL       First admin user email     (default: admin@incenva.com)
#   ADMIN_PASSWORD    First admin user password  (default: auto-generated)
#   ADMIN_NAME        First admin user full name (default: Admin User)
#   SKIP_SEED         Set to "true" to skip seeding the database
#   BOOTSTRAP_URL     Override the bootstrap script URL (for testing)
#
# ── Fly.io scraper (Step 11 — all optional) ───────────────────────────────────
#   FLY_API_TOKEN     Fly.io API token — enables automated scraper deployment
#                     → https://fly.io/user/personal_access_tokens
#   FLY_APP           Fly.io app name (default: incenva-scraper)
#   FLY_REGION        Fly.io region (default: iad)
#   REWIRING_AMERICA_API_KEY  Optional — Rewiring America scraper API key
#   SCRAPER_REPO_DIR  Path to local rebate-finder-scrapers clone.
#                     If not set, the repo is auto-cloned via GITHUB_PAT.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   export DO_API_TOKEN=dop_v1_...
#   export GITHUB_PAT=ghp_...
#   export OPENAI_API_KEY=sk-...
#   export APP_DOMAIN=acme.incenva.com
#   export FLY_API_TOKEN=fo1_...        # optional — enables Step 11
#   bash scripts/provision.sh
#
# ── Notes ─────────────────────────────────────────────────────────────────────
#   • The script is idempotent within a run: if it fails partway, re-running
#     with the same DROPLET_IP env var will skip already-completed steps.
#   • A temporary SSH key is generated for this run and deleted from your DO
#     account when the script exits (success or failure).
#   • Set DROPLET_IP to skip Droplet creation and connect to an existing server.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "\n${BLUE}━━━${NC} ${BOLD}$*${NC}"; }
ok()    { echo -e "  ${GREEN}✔${NC}  $*"; }
info()  { echo -e "  ${BLUE}→${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail()  { echo -e "\n${RED}[error]${NC} $*\n" >&2; exit 1; }
hr()    { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Configuration ─────────────────────────────────────────────────────────────
DO_API_TOKEN="${DO_API_TOKEN:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
APP_DOMAIN="${APP_DOMAIN:-}"
CLIENT_NAME="${CLIENT_NAME:-}"
DO_REGION="${DO_REGION:-nyc1}"
DO_SIZE="${DO_SIZE:-s-2vcpu-4gb}"
DO_IMAGE="${DO_IMAGE:-ubuntu-22-04-x64}"
DO_SSH_KEY_IDS="${DO_SSH_KEY_IDS:-}"
BREVO_API_KEY="${BREVO_API_KEY:-}"
BREVO_SENDER_EMAIL="${BREVO_SENDER_EMAIL:-}"
GTM_ID="${GTM_ID:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@incenva.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_NAME="${ADMIN_NAME:-Admin User}"
SKIP_SEED="${SKIP_SEED:-false}"
DROPLET_IP="${DROPLET_IP:-}"  # skip creation if already have a server

# Fly.io scraper (all optional — Step 11 is skipped if FLY_API_TOKEN is not set)
FLY_API_TOKEN="${FLY_API_TOKEN:-}"
FLY_APP="${FLY_APP:-incenva-scraper}"
FLY_REGION="${FLY_REGION:-iad}"
REWIRING_AMERICA_API_KEY="${REWIRING_AMERICA_API_KEY:-}"
SCRAPER_REPO_DIR="${SCRAPER_REPO_DIR:-}"  # path to local clone; auto-cloned if empty

BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/SomethingPressing/rebate-finder-deployement/main/scripts/bootstrap.sh}"

GITHUB_ORG="${GITHUB_ORG:-SomethingPressing}"
DO_API="https://api.digitalocean.com/v2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# State tracking
TEMP_KEY_ID=""       # DO SSH key ID for the temp key (cleaned up on exit)
TEMP_KEY_FILE=""     # path to the temp private key file
DROPLET_ID=""        # created Droplet ID
SCRAPER_CLONE_DIR="" # auto-cloned scrapers repo (cleaned up on exit)

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_KEY_ID" ]]; then
    info "Removing temporary SSH key from DigitalOcean..."
    curl -s -X DELETE \
      -H "Authorization: Bearer $DO_API_TOKEN" \
      "$DO_API/account/keys/$TEMP_KEY_ID" >/dev/null || true
    ok "Temporary SSH key removed"
  fi
  if [[ -n "$TEMP_KEY_FILE" ]]; then
    rm -f "$TEMP_KEY_FILE" "${TEMP_KEY_FILE}.pub"
  fi
  if [[ -n "$SCRAPER_CLONE_DIR" ]]; then
    rm -rf "$SCRAPER_CLONE_DIR"
  fi
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    warn "Provisioning failed (exit $exit_code)."
    if [[ -n "$DROPLET_IP" ]]; then
      echo -e "  The server at ${BOLD}$DROPLET_IP${NC} may be partially set up."
      echo -e "  You can SSH in and check the state: ssh root@$DROPLET_IP"
      echo -e "  Re-run with DROPLET_IP=$DROPLET_IP to skip Droplet creation."
    fi
  fi
}
trap cleanup EXIT

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl ssh jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required tools: ${missing[*]}\nInstall with: brew install ${missing[*]}  (macOS)  or  apt-get install -y ${missing[*]}  (Linux)"
  fi
}

# ── DO API helpers ────────────────────────────────────────────────────────────
do_get()  { curl -s -H "Authorization: Bearer $DO_API_TOKEN" "$DO_API/$1"; }
do_post() { curl -s -X POST -H "Authorization: Bearer $DO_API_TOKEN" \
              -H "Content-Type: application/json" "$DO_API/$1" -d "$2"; }
do_del()  { curl -s -X DELETE -H "Authorization: Bearer $DO_API_TOKEN" "$DO_API/$1"; }

do_check() {
  local response="$1" context="${2:-API call}"
  if echo "$response" | jq -e '.id == "unauthorized"' &>/dev/null; then
    fail "DigitalOcean API: unauthorized. Check DO_API_TOKEN."
  fi
  if echo "$response" | jq -e '.id == "unprocessable_entity"' &>/dev/null; then
    fail "DigitalOcean API error ($context): $(echo "$response" | jq -r '.message')"
  fi
}

# ── SSH helpers ───────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

ssh_run() {
  local ip="$1"; shift
  ssh $SSH_OPTS -i "$TEMP_KEY_FILE" root@"$ip" "$@"
}

ssh_run_heredoc() {
  local ip="$1"; shift
  ssh $SSH_OPTS -i "$TEMP_KEY_FILE" root@"$ip" bash -s
}

wait_for_ssh() {
  local ip="$1"
  local elapsed=0 timeout=300
  info "Waiting for SSH on $ip..."
  while ! ssh $SSH_OPTS -i "$TEMP_KEY_FILE" root@"$ip" true 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    [[ $elapsed -lt $timeout ]] || fail "SSH not reachable after ${timeout}s. Server may still be booting."
    printf "."
  done
  echo ""
  ok "SSH ready"
}

# ── Main ──────────────────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${BOLD}Incenva — Provisioning Orchestrator${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M %Z')"
echo ""
hr

# ── Step 0: Validate ──────────────────────────────────────────────────────────
log "Step 0 — Validate"

check_deps
ok "Dependencies: curl, ssh, jq"

[[ -n "$DO_API_TOKEN" ]]  || fail "DO_API_TOKEN is required.\nGet one at: https://cloud.digitalocean.com/account/api/tokens"
[[ -n "$GITHUB_PAT" ]]    || fail "GITHUB_PAT is required (repo scope).\nGet one at: https://github.com/settings/tokens"
[[ -n "$OPENAI_API_KEY" ]] || fail "OPENAI_API_KEY is required."

# Derive client name from domain if not set
if [[ -z "$CLIENT_NAME" && -n "$APP_DOMAIN" ]]; then
  CLIENT_NAME="incenva-$(echo "$APP_DOMAIN" | cut -d. -f1)"
elif [[ -z "$CLIENT_NAME" ]]; then
  CLIENT_NAME="incenva-$(date +%Y%m%d%H%M)"
fi

# Auto-generate admin password if not set
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#' | head -c 16)1aA!"
fi

ok "Client: $CLIENT_NAME"
ok "Domain: ${APP_DOMAIN:-<none — will use raw IP>}"
ok "Region: $DO_REGION / Size: $DO_SIZE"

# Verify DO token
ACCOUNT=$(do_get "account")
do_check "$ACCOUNT" "account lookup"
ok "DigitalOcean account: $(echo "$ACCOUNT" | jq -r '.account.email')"

# Verify GitHub PAT
GH_USER=$(curl -s -H "Authorization: token $GITHUB_PAT" https://api.github.com/user)
if echo "$GH_USER" | jq -e '.login' &>/dev/null; then
  ok "GitHub token valid: $(echo "$GH_USER" | jq -r '.login')"
else
  fail "GITHUB_PAT is invalid or lacks required scope.\nNeeded: repo scope (classic PAT)."
fi

# ── Step 1: Temporary SSH key ─────────────────────────────────────────────────
log "Step 1 — Create temporary SSH key for this provisioning session"

if [[ -z "$DROPLET_IP" ]]; then
  TEMP_KEY_FILE="$(mktemp /tmp/incenva_provision_XXXXXX)"
  chmod 600 "$TEMP_KEY_FILE"
  ssh-keygen -t ed25519 -f "$TEMP_KEY_FILE" -N "" -C "incenva-provision-tmp" >/dev/null 2>&1
  ok "Generated temporary key: $TEMP_KEY_FILE"

  KEY_NAME="incenva-provision-tmp-$(date +%s)"
  PUB_KEY="$(cat "${TEMP_KEY_FILE}.pub")"
  REGISTER_RESP=$(do_post "account/keys" "{\"name\":\"$KEY_NAME\",\"public_key\":\"$PUB_KEY\"}")
  do_check "$REGISTER_RESP" "register SSH key"
  TEMP_KEY_ID=$(echo "$REGISTER_RESP" | jq -r '.ssh_key.id')
  ok "Registered temp key with DigitalOcean (id: $TEMP_KEY_ID)"
else
  # Connecting to an existing server — need to use caller's existing key
  # Detect the default SSH key from ssh-agent or ~/.ssh/id_*
  TEMP_KEY_FILE="$(ls ~/.ssh/id_ed25519 ~/.ssh/id_rsa 2>/dev/null | head -1 || echo '')"
  [[ -n "$TEMP_KEY_FILE" ]] || fail "No SSH key found. Set DROPLET_IP only when you have a key that can reach root@$DROPLET_IP."
  warn "Reusing existing server at $DROPLET_IP — skipping Droplet creation."
fi

# ── Step 2: Create Droplet ────────────────────────────────────────────────────
if [[ -z "$DROPLET_IP" ]]; then
  log "Step 2 — Create Droplet"

  # Build SSH keys array: always include the temp key
  KEY_IDS="[$TEMP_KEY_ID"
  if [[ -n "$DO_SSH_KEY_IDS" ]]; then
    for kid in ${DO_SSH_KEY_IDS//,/ }; do
      KEY_IDS="$KEY_IDS,$kid"
    done
  fi
  KEY_IDS="$KEY_IDS]"

  DROPLET_PAYLOAD=$(jq -n \
    --arg name "$CLIENT_NAME" \
    --arg region "$DO_REGION" \
    --arg size "$DO_SIZE" \
    --arg image "$DO_IMAGE" \
    --argjson ssh_keys "$KEY_IDS" \
    '{name: $name, region: $region, size: $size, image: $image, ssh_keys: $ssh_keys, tags: ["incenva","rebate-finder"], ipv6: false}')

  info "Creating Droplet '$CLIENT_NAME' in $DO_REGION ($DO_SIZE)..."
  DROPLET_RESP=$(do_post "droplets" "$DROPLET_PAYLOAD")
  do_check "$DROPLET_RESP" "create droplet"
  DROPLET_ID=$(echo "$DROPLET_RESP" | jq -r '.droplet.id')
  [[ "$DROPLET_ID" != "null" && -n "$DROPLET_ID" ]] || fail "Failed to create Droplet:\n$DROPLET_RESP"
  ok "Droplet created (id: $DROPLET_ID)"

  # ── Step 3: Wait for Droplet to be active ──────────────────────────────────
  log "Step 3 — Wait for Droplet to become active"
  elapsed=0
  while true; do
    STATUS=$(do_get "droplets/$DROPLET_ID")
    DROPLET_STATUS=$(echo "$STATUS" | jq -r '.droplet.status')
    DROPLET_IP=$(echo "$STATUS" | jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' 2>/dev/null | head -1 || echo "")
    if [[ "$DROPLET_STATUS" == "active" && -n "$DROPLET_IP" ]]; then
      ok "Droplet active — IP: $DROPLET_IP"
      break
    fi
    elapsed=$((elapsed + 5))
    [[ $elapsed -lt 120 ]] || fail "Droplet did not become active after 120s."
    printf "."
    sleep 5
  done
  echo ""
else
  log "Step 2 — Using existing Droplet"
  ok "Connecting to $DROPLET_IP"
  log "Step 3 — Skipped (existing server)"
fi

# ── Step 4: Wait for SSH ──────────────────────────────────────────────────────
log "Step 4 — Wait for SSH"
# DigitalOcean marks Droplets active before sshd starts — give it a moment
sleep 15
wait_for_ssh "$DROPLET_IP"

# ── Step 5: Run bootstrap ─────────────────────────────────────────────────────
log "Step 5 — Run bootstrap (fully automated)"

info "This will take 5–10 minutes. Output streams live below."
echo ""

ssh_run_heredoc "$DROPLET_IP" << ENDSSH
set -euo pipefail
export GITHUB_PAT='${GITHUB_PAT}'
export GITHUB_ORG='${GITHUB_ORG}'
export APP_DOMAIN='${APP_DOMAIN}'
export OPENAI_API_KEY='${OPENAI_API_KEY}'
$([ -n "$BREVO_API_KEY" ] && echo "export BREVO_API_KEY='${BREVO_API_KEY}'")
$([ -n "$BREVO_SENDER_EMAIL" ] && echo "export BREVO_SENDER_EMAIL='${BREVO_SENDER_EMAIL}'")
$([ -n "$GTM_ID" ] && echo "export NEXT_PUBLIC_GTM_ID='${GTM_ID}'")

curl -fsSL '${BOOTSTRAP_URL}' | bash
ENDSSH

ok "Bootstrap complete"

# ── Step 6: Inject additional .env values ─────────────────────────────────────
log "Step 6 — Inject environment variables"

ssh_run_heredoc "$DROPLET_IP" << ENVSSH
set -euo pipefail
ENV_FILE="/home/rf/apps/rebate-finder/.env"

_set_env() {
  local key="\$1" val="\$2"
  if grep -q "^\${key}=" "\$ENV_FILE" 2>/dev/null; then
    sed -i "s|^\${key}=.*|\${key}=\${val}|" "\$ENV_FILE"
  else
    echo "\${key}=\${val}" >> "\$ENV_FILE"
  fi
}

_set_env "OPENAI_API_KEY" "${OPENAI_API_KEY}"
$([ -n "$BREVO_API_KEY" ]      && echo "_set_env \"BREVO_API_KEY\" \"${BREVO_API_KEY}\"")
$([ -n "$BREVO_SENDER_EMAIL" ] && echo "_set_env \"BREVO_SENDER_EMAIL\" \"${BREVO_SENDER_EMAIL}\"")
$([ -n "$GTM_ID" ]             && echo "_set_env \"NEXT_PUBLIC_GTM_ID\" \"${GTM_ID}\"")
# Set NEXT_BASE_URL to the raw IP when no domain was provided (setup-server.sh
# only sets it when APP_DOMAIN is non-empty, so it stays as the placeholder).
$([ -z "$APP_DOMAIN" ] && echo "_set_env \"NEXT_BASE_URL\" \"http://${DROPLET_IP}\"")
echo "  ✔  .env updated"
ENVSSH

ok "Environment variables injected"

# Restart PM2 so the app picks up the new env vars (OPENAI_API_KEY etc.)
ssh_run "$DROPLET_IP" 'pm2 restart "Rebate Finder" --update-env && pm2 save' || \
  warn "PM2 restart after env inject failed — app may not have OPENAI_API_KEY until next deploy"

# ── Step 7: Seed the database ─────────────────────────────────────────────────
if [[ "$SKIP_SEED" != "true" ]]; then
  log "Step 7 — Seed the database"
  ssh_run "$DROPLET_IP" "bash /home/rf/apps/deployment/scripts/rebate-finder/seed.sh"
  ok "Database seeded"
else
  log "Step 7 — Seed skipped (SKIP_SEED=true)"
fi

# ── Step 8: Create admin user ─────────────────────────────────────────────────
log "Step 8 — Create first admin user"
ssh_run "$DROPLET_IP" \
  "bash /home/rf/apps/deployment/scripts/rebate-finder/create-admin.sh \
    '${ADMIN_EMAIL}' '${ADMIN_PASSWORD}' '${ADMIN_NAME}' super_admin"
ok "Admin user created"

# ── Step 9: CI deploy key ────────────────────────────────────────────────────
log "Step 9 — Set up GitHub Actions CI deploy key"

CI_KEY_FILE="$(mktemp /tmp/incenva_ci_deploy_XXXXXX)"
chmod 600 "$CI_KEY_FILE"
ssh-keygen -t ed25519 -f "$CI_KEY_FILE" -N "" -C "ci-deploy@incenva" >/dev/null 2>&1
CI_PUB_KEY="$(cat "${CI_KEY_FILE}.pub")"
CI_PRIV_KEY="$(cat "$CI_KEY_FILE")"

# Add CI public key to rf user's authorized_keys on the server
ssh_run_heredoc "$DROPLET_IP" << CISSH
set -euo pipefail
mkdir -p /home/rf/.ssh
echo "${CI_PUB_KEY}" >> /home/rf/.ssh/authorized_keys
sort -u /home/rf/.ssh/authorized_keys -o /home/rf/.ssh/authorized_keys
chown -R rf:rf /home/rf/.ssh
chmod 600 /home/rf/.ssh/authorized_keys
echo "  ✔  CI public key added to authorized_keys"
CISSH

ok "CI public key added to server"

# Set GitHub Actions secrets and variables.
# gh CLI is used for secrets (they require libsodium encryption).
# Variables are plain-text and can be set via the REST API with just GITHUB_PAT.
# We authenticate gh via GH_TOKEN — no `gh auth login` needed.
CI_SECRETS_SET=false
GITHUB_REPO="$GITHUB_ORG/rebate-finder"

# Always set variables via GitHub REST API (no encryption needed)
_gh_var() {
  local name="$1" val="$2"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: token $GITHUB_PAT" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$GITHUB_REPO/actions/variables" \
    -d "{\"name\":\"$name\",\"value\":\"$val\"}" 2>/dev/null || echo "000")
  if [[ "$http_code" == "422" ]]; then
    # Variable already exists — PATCH to update
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
      -H "Authorization: token $GITHUB_PAT" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/$GITHUB_REPO/actions/variables/$name" \
      -d "{\"name\":\"$name\",\"value\":\"$val\"}" 2>/dev/null || echo "000")
  fi
  [[ "$http_code" == "201" || "$http_code" == "204" ]] && ok "Variable $name set" || warn "Variable $name: HTTP $http_code"
}

_gh_var "DEPLOY_PATH"   "/home/rf/apps/rebate-finder"
_gh_var "DEPLOY_BRANCH" "main"
_gh_var "PM2_PROCESS"   "Rebate Finder"
_gh_var "PRISMA_DEPLOY" "db-push"

# Secrets require encryption — use gh CLI with GH_TOKEN (no auth login needed)
if command -v gh &>/dev/null; then
  info "gh CLI found — setting GitHub Actions secrets via GH_TOKEN..."
  GH_TOKEN="$GITHUB_PAT" gh secret set DEPLOY_HOST            --body "$DROPLET_IP"  --repo "$GITHUB_REPO" 2>/dev/null && \
  GH_TOKEN="$GITHUB_PAT" gh secret set DEPLOY_SSH_USER        --body "rf"            --repo "$GITHUB_REPO" 2>/dev/null && \
  GH_TOKEN="$GITHUB_PAT" gh secret set DEPLOY_SSH_PRIVATE_KEY --body "$CI_PRIV_KEY" --repo "$GITHUB_REPO" 2>/dev/null && \
  GH_TOKEN="$GITHUB_PAT" gh secret set DEPLOY_SSH_PORT        --body "22"            --repo "$GITHUB_REPO" 2>/dev/null && \
  CI_SECRETS_SET=true
  if [[ "$CI_SECRETS_SET" == "true" ]]; then
    ok "GitHub Actions secrets set via gh CLI"
  else
    warn "gh CLI ran but secret set failed — will print manual instructions"
    CI_SECRETS_SET=false
  fi
else
  info "gh CLI not installed — will print secrets for manual entry"
  info "Install with: brew install gh  (macOS) or https://cli.github.com/manual/installation (Linux)"
  info "No login needed — provision.sh will use your GITHUB_PAT automatically"
fi

# Save CI private key to a local file regardless, so it's not lost
CI_KEY_SAVE="$HOME/.ssh/incenva_ci_deploy_${CLIENT_NAME}"
cp "$CI_KEY_FILE" "$CI_KEY_SAVE"
cp "${CI_KEY_FILE}.pub" "${CI_KEY_SAVE}.pub"
chmod 600 "$CI_KEY_SAVE"
rm -f "$CI_KEY_FILE" "${CI_KEY_FILE}.pub"
ok "CI private key saved to $CI_KEY_SAVE"

# ── Step 10: Health check ─────────────────────────────────────────────────────
log "Step 10 — Health check"

# Give PM2 a moment to finish starting
sleep 5

APP_URL="http://$DROPLET_IP"
[[ -n "$APP_DOMAIN" ]] && APP_URL="https://$APP_DOMAIN"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$APP_URL" || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
  ok "App responding — HTTP $HTTP_CODE"
elif [[ "$HTTP_CODE" == "000" ]]; then
  warn "Could not reach $APP_URL (timeout). DNS may not have propagated yet."
  warn "Check the app via: curl http://$DROPLET_IP"
else
  warn "App returned HTTP $HTTP_CODE — check logs: ssh root@$DROPLET_IP pm2 logs \"Rebate Finder\""
fi

# ── Step 11: Fly.io scraper setup ────────────────────────────────────────────
FLY_SETUP=false

if [[ -z "$FLY_API_TOKEN" ]]; then
  log "Step 11 — Fly.io scraper (skipped — set FLY_API_TOKEN to enable)"
  info "To automate scraper setup in future runs, add: export FLY_API_TOKEN=fo1_..."
else
  log "Step 11 — Fly.io scraper setup"

  # 11a — Install flyctl if not present
  if ! command -v fly &>/dev/null; then
    info "flyctl not found — installing..."
    curl -L https://fly.io/install.sh | sh >/dev/null 2>&1
    export PATH="$HOME/.fly/bin:$PATH"
    command -v fly &>/dev/null || fail "flyctl install failed. Install manually: https://fly.io/docs/hands-on/install-flyctl/"
    ok "flyctl installed"
  else
    ok "flyctl $(fly version 2>/dev/null | awk '{print $2}' | head -1)"
  fi

  # 11b — Locate or auto-clone the scrapers repo
  if [[ -n "$SCRAPER_REPO_DIR" ]]; then
    [[ -f "$SCRAPER_REPO_DIR/fly.toml" ]] || \
      fail "SCRAPER_REPO_DIR '$SCRAPER_REPO_DIR' has no fly.toml — is it the scrapers repo?"
    info "Using scrapers repo at $SCRAPER_REPO_DIR"
  else
    info "SCRAPER_REPO_DIR not set — cloning scrapers repo via GITHUB_PAT..."
    SCRAPER_CLONE_DIR="$(mktemp -d /tmp/incenva_scrapers_XXXXXX)"
    git clone --depth 1 \
      "https://$GITHUB_PAT@github.com/$GITHUB_ORG/rebate-finder-scrapers.git" \
      "$SCRAPER_CLONE_DIR" 2>/dev/null
    SCRAPER_REPO_DIR="$SCRAPER_CLONE_DIR"
    ok "Cloned scrapers repo"
  fi

  # 11c — Read DB credentials and sync secret from the server .env
  info "Reading .env from server..."
  RAW_DB_URL=$(ssh_run "$DROPLET_IP" \
    "grep '^DATABASE_URL=' /home/rf/apps/rebate-finder/.env | head -1 | cut -d= -f2-")
  SYNC_SECRET=$(ssh_run "$DROPLET_IP" \
    "grep '^PROMOTER_SYNC_SECRET=' /home/rf/apps/rebate-finder/.env | head -1 | cut -d= -f2-" 2>/dev/null || echo "")

  # Build the external DB URL: replace localhost with the Droplet's public IP
  # and strip query params (connection_limit etc. — not needed for the scraper)
  EXT_DB_URL="${RAW_DB_URL/localhost/$DROPLET_IP}"
  EXT_DB_URL="${EXT_DB_URL/127.0.0.1/$DROPLET_IP}"
  EXT_DB_URL="${EXT_DB_URL%%\?*}"
  ok "External DB URL: ${EXT_DB_URL//:*@/:***@}"

  # 11d — Open PostgreSQL on the VPS to external connections
  info "Configuring PostgreSQL for external access..."
  ssh_run_heredoc "$DROPLET_IP" << 'PGSSH'
set -euo pipefail
PG_CONF="$(sudo -u postgres psql -tAc 'SHOW config_file' 2>/dev/null)"
PG_HBA="$(sudo -u postgres psql -tAc 'SHOW hba_file' 2>/dev/null)"

# listen_addresses = '*'
if grep -qE "^listen_addresses\s*=\s*'\*'" "$PG_CONF" 2>/dev/null; then
  echo "  ─  listen_addresses already '*'"
else
  sed -i "s|^#\?listen_addresses\s*=.*|listen_addresses = '*'|" "$PG_CONF"
  echo "  ✔  listen_addresses = '*'"
fi

# pg_hba: allow rf user on rebate_finder from anywhere with password
if grep -qE "^host\s+rebate_finder\s+rf\s+0\.0\.0\.0/0" "$PG_HBA" 2>/dev/null; then
  echo "  ─  pg_hba rule already present"
else
  echo "host    rebate_finder   rf    0.0.0.0/0    md5" >> "$PG_HBA"
  echo "  ✔  Added pg_hba external rule"
fi

# UFW: allow 5432
ufw allow 5432/tcp >/dev/null 2>&1 && echo "  ✔  UFW: port 5432 open" || true

# Reload PostgreSQL config
systemctl reload postgresql 2>/dev/null || systemctl restart postgresql 2>/dev/null || true
echo "  ✔  PostgreSQL config reloaded"
PGSSH
  ok "PostgreSQL accepting external connections"

  # 11e — Derive tenant ID and secret name from CLIENT_NAME
  TENANT_ID="${CLIENT_NAME#incenva-}"               # strip "incenva-" prefix → bare slug
  TENANT_SLUG="${TENANT_ID^^}"                       # uppercase for secret name
  TENANT_SLUG="${TENANT_SLUG//-/_}"                  # hyphens → underscores
  TENANT_SECRET="TENANT_${TENANT_SLUG}_DB_URL"
  APP_URL_TENANT="http://$DROPLET_IP"
  [[ -n "$APP_DOMAIN" ]] && APP_URL_TENANT="https://$APP_DOMAIN"
  ok "Tenant: $TENANT_ID  →  secret: $TENANT_SECRET"

  # 11f — Add tenant to tenants.json (idempotent)
  TENANTS_JSON="$SCRAPER_REPO_DIR/config/tenants.json"
  [[ -f "$TENANTS_JSON" ]] || fail "tenants.json not found at $TENANTS_JSON"

  if jq -e --arg id "$TENANT_ID" '.[] | select(.id == $id)' "$TENANTS_JSON" &>/dev/null; then
    info "Tenant '$TENANT_ID' already in tenants.json — skipping"
  else
    NEW_ENTRY=$(jq -n \
      --arg id           "$TENANT_ID" \
      --arg name         "${APP_DOMAIN:-$CLIENT_NAME}" \
      --arg db_url_env   "$TENANT_SECRET" \
      --arg app_url      "$APP_URL_TENANT" \
      --arg sync_secret  "${SYNC_SECRET:-}" \
      '{
        id: $id,
        name: $name,
        active: true,
        sources: ["dsireusa","rewiring_america","energy_star"],
        db_url_env: $db_url_env,
        location_filter: {states:[],utilities:[],service_areas:[],zip_codes:[]},
        max_incentives_per_source: 0,
        app_url: $app_url,
        sync_secret: $sync_secret
      }')
    jq --argjson e "$NEW_ENTRY" '. + [$e]' "$TENANTS_JSON" > "${TENANTS_JSON}.tmp"
    mv "${TENANTS_JSON}.tmp" "$TENANTS_JSON"
    ok "Added tenant '$TENANT_ID' to tenants.json"

    # Push the updated tenants.json so the Docker build picks it up
    cd "$SCRAPER_REPO_DIR"
    git config user.email "provision@incenva" 2>/dev/null || true
    git config user.name  "provision.sh"      2>/dev/null || true
    git add config/tenants.json
    git commit -m "chore: add tenant $TENANT_ID" 2>/dev/null
    git push "https://$GITHUB_PAT@github.com/$GITHUB_ORG/rebate-finder-scrapers.git" HEAD:main \
      2>/dev/null
    ok "Pushed tenants.json to GitHub"
    cd - >/dev/null
  fi

  # 11g — Create Fly.io app (idempotent)
  if FLY_API_TOKEN="$FLY_API_TOKEN" fly status --app "$FLY_APP" &>/dev/null; then
    info "Fly.io app '$FLY_APP' already exists"
  else
    FLY_API_TOKEN="$FLY_API_TOKEN" fly apps create "$FLY_APP" \
      --org personal --region "$FLY_REGION"
    ok "Fly.io app '$FLY_APP' created"
  fi

  # 11h — Stage secrets (picked up by the deploy in 11i)
  FLY_API_TOKEN="$FLY_API_TOKEN" fly secrets set \
    "${TENANT_SECRET}=${EXT_DB_URL}" \
    --app "$FLY_APP" --stage
  ok "Secret $TENANT_SECRET staged"

  if [[ -n "$REWIRING_AMERICA_API_KEY" ]]; then
    FLY_API_TOKEN="$FLY_API_TOKEN" fly secrets set \
      "REWIRING_AMERICA_API_KEY=$REWIRING_AMERICA_API_KEY" \
      --app "$FLY_APP" --stage
    ok "REWIRING_AMERICA_API_KEY staged"
  fi

  # 11i — Deploy (builds Docker image remotely on Fly.io infra)
  info "Deploying scraper (builds Docker image on Fly.io — ~2 min)..."
  cd "$SCRAPER_REPO_DIR"
  FLY_API_TOKEN="$FLY_API_TOKEN" fly deploy \
    --app "$FLY_APP" --remote-only
  ok "Scraper deployed to Fly.io"

  # 11j — Trigger a one-off scrape run to verify
  FLY_API_TOKEN="$FLY_API_TOKEN" fly machine run \
    --app "$FLY_APP" \
    --image "registry.fly.io/${FLY_APP}:latest" \
    --env RUN_ONCE=true \
    --restart no 2>/dev/null \
    && ok "One-off scrape run triggered — check: fly logs --app $FLY_APP" \
    || warn "Could not trigger one-off run — deploy still succeeded"

  cd - >/dev/null
  FLY_SETUP=true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${GREEN}${BOLD}Provisioning complete!${NC}"
echo ""
echo -e "  ${BOLD}Server IP:${NC}      $DROPLET_IP"
if [[ -n "$APP_DOMAIN" ]]; then
  echo -e "  ${BOLD}App URL:${NC}        https://$APP_DOMAIN"
fi
echo -e "  ${BOLD}App (direct):${NC}   http://$DROPLET_IP"
echo ""
echo -e "  ${BOLD}Admin login:${NC}"
echo -e "    Email:    $ADMIN_EMAIL"
echo -e "    Password: $ADMIN_PASSWORD"
echo -e "    URL:      ${APP_URL}/admin/login"
echo ""
echo -e "  ${BOLD}SSH access:${NC}"
echo -e "    ssh root@$DROPLET_IP"
echo ""
echo -e "  ${BOLD}CI deploy key:${NC}  $CI_KEY_SAVE"
echo ""
if [[ "$CI_SECRETS_SET" == "true" ]]; then
  echo -e "  ${GREEN}✔${NC}  GitHub Actions secrets set automatically — CI/CD is ready."
  echo -e "      Push to main to trigger your first deploy."
else
  echo -e "  ${YELLOW}⚠${NC}  GitHub Actions secrets need to be added manually."
  echo -e "      Go to: https://github.com/$GITHUB_ORG/rebate-finder/settings/secrets/actions"
  echo ""
  echo -e "      Add these ${BOLD}Secrets${NC}:"
  echo -e "        DEPLOY_HOST             = $DROPLET_IP"
  echo -e "        DEPLOY_SSH_USER         = rf"
  echo -e "        DEPLOY_SSH_PORT         = 22"
  echo -e "        DEPLOY_SSH_PRIVATE_KEY  = (contents of $CI_KEY_SAVE)"
  echo ""
  echo -e "      Add these ${BOLD}Variables${NC}:"
  echo -e "        DEPLOY_PATH    = /home/rf/apps/rebate-finder"
  echo -e "        DEPLOY_BRANCH  = main"
  echo -e "        PM2_PROCESS    = Rebate Finder"
  echo -e "        PRISMA_DEPLOY  = db-push"
fi
echo ""
echo -e "  ${BOLD}Scraper (Fly.io):${NC}"
if [[ "$FLY_SETUP" == "true" ]]; then
  echo -e "    ${GREEN}✔${NC}  Deployed — fly logs --app $FLY_APP"
  echo -e "         fly status --app $FLY_APP"
else
  echo -e "    ${YELLOW}→${NC}  Not deployed (set FLY_API_TOKEN to automate)"
  echo -e "         bash scripts/scraper/setup-fly.sh"
fi
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    1. Point DNS for ${APP_DOMAIN:-<your-domain>} → $DROPLET_IP (if not done)"
echo -e "    2. Log in to the admin at ${APP_URL}/admin/login"
echo -e "    3. Configure branding: Admin → Brand"
echo -e "    4. Configure filters: Admin → Filters → Translate All to Spanish"
hr
echo ""
