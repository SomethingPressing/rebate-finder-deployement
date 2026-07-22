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
# ── Usage ─────────────────────────────────────────────────────────────────────
#   export DO_API_TOKEN=dop_v1_...
#   export GITHUB_PAT=ghp_...
#   export OPENAI_API_KEY=sk-...
#   export APP_DOMAIN=acme.incenva.com
#   export DO_SSH_KEY_IDS=12345678   # optional — your own DO SSH key ID
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

BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/SomethingPressing/rebate-finder-deployement/main/scripts/bootstrap.sh}"

GITHUB_ORG="${GITHUB_ORG:-SomethingPressing}"
DO_API="https://api.digitalocean.com/v2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# State tracking
TEMP_KEY_ID=""    # DO SSH key ID for the temp key (cleaned up on exit)
TEMP_KEY_FILE=""  # path to the temp private key file
DROPLET_ID=""     # created Droplet ID

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
echo "  ✔  .env updated"
ENVSSH

ok "Environment variables injected"

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

# ── Step 9: Health check ──────────────────────────────────────────────────────
log "Step 9 — Health check"

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
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    1. Point DNS for $APP_DOMAIN → $DROPLET_IP (if not done)"
echo -e "    2. Log in to the admin at ${APP_URL}/admin/login"
echo -e "    3. Configure branding: Admin → Brand Settings"
echo -e "    4. Configure filters: Admin → Filters → Translate All to Spanish"
echo -e "    5. Set up GitHub Actions deploy secrets (DEPLOY_HOST=$DROPLET_IP)"
echo -e "       See: https://github.com/$GITHUB_ORG/rebate-finder/blob/main/docs/deployment-guide.md#3-deploy-the-code"
hr
echo ""
