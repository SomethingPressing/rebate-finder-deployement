#!/usr/bin/env bash
# =============================================================================
# bootstrap-broker.sh — one command, blank Ubuntu box → running broker
#
# The staging host from nothing. Run it on a fresh DigitalOcean droplet as root:
#
#   BROKER_ADMIN_PASSWORD='a-long-passphrase' \
#   BROKER_ADMIN_EMAIL=you@incenva.com \
#   APP_DOMAIN=broker.incenva.com \
#     bash <(curl -fsSL https://raw.githubusercontent.com/SomethingPressing/rebate-finder-deployement/main/scripts/broker/bootstrap-broker.sh)
#
# Note `bash <(curl …)` rather than `curl … | bash`: this script has to PAUSE
# and read from your terminal while you paste a deploy key into GitHub, and a
# piped script has its stdin taken by the pipe.
#
# What it does, skipping anything already done:
#   1. Base packages
#   2. A deploy key for the broker repo — pauses while you add it to GitHub
#   3. Clone this deployment repo
#   4. setup-staging-host.sh: Postgres, Redis, schema, build, PM2
#   5. Tell you the two things it deliberately did NOT do
#
# ── Required ─────────────────────────────────────────────────────────────────
#   BROKER_ADMIN_PASSWORD   12+ characters
#
# ── Recommended ──────────────────────────────────────────────────────────────
#   BROKER_ADMIN_EMAIL      who signs in       (default admin@incenva.com)
#   APP_DOMAIN              the broker hostname; enables the TLS step
#   CLOUDFLARE_API_TOKEN    lets TLS use DNS-01, which works behind the proxy
#
# Idempotent. Safe to re-run after fixing whatever stopped it.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[bootstrap]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✖${NC} $*" >&2; exit 1; }
skip() { echo -e "${GREEN}✔${NC} $* ${YELLOW}(already done)${NC}"; }

DEPLOY_REPO="${DEPLOY_REPO:-https://github.com/SomethingPressing/rebate-finder-deployement.git}"
BROKER_REPO_SSH="${BROKER_REPO:-git@github.com:SomethingPressing/rebate-finder-broker.git}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/rebate-finder-deployement}"

# ── 0. Preflight ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "run as root (sudo -i, then re-run)"
[[ -n "${BROKER_ADMIN_PASSWORD:-}" ]] || fail "BROKER_ADMIN_PASSWORD is required — the console is locked without it"
[[ ${#BROKER_ADMIN_PASSWORD} -ge 12 ]] || fail "BROKER_ADMIN_PASSWORD must be at least 12 characters"

# Checked here rather than 20 minutes in: the seed at the end rejects a short
# password, and finding that out after a full provision is the wrong time.
BROKER_ADMIN_EMAIL="${BROKER_ADMIN_EMAIL:-admin@incenva.com}"

echo -e "\n${BOLD}Incenva broker — staging host bootstrap${NC}"
echo    "  admin        ${BROKER_ADMIN_EMAIL}"
echo    "  domain       ${APP_DOMAIN:-<none — TLS will be skipped>}"
echo    "  cloudflare   ${CLOUDFLARE_API_TOKEN:+token supplied}${CLOUDFLARE_API_TOKEN:-not supplied}"
echo ""

# ── 1. Base packages ─────────────────────────────────────────────────────────
log "1/5  System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates openssh-client >/dev/null
ok "git, curl, openssh"

# ── 2. Deploy key for the broker repo ────────────────────────────────────────
# The broker repo is private, so the box needs its own key. Generated here and
# left in place: re-running finds it and skips straight past.
log "2/5  GitHub access for the broker repo"
KEY=/root/.ssh/id_ed25519_broker
mkdir -p /root/.ssh && chmod 700 /root/.ssh

if [[ -f "$KEY" ]]; then
  skip "deploy key exists at $KEY"
else
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "broker-staging-host" >/dev/null
  ok "generated $KEY"
fi

if ! grep -q "Host github-broker" /root/.ssh/config 2>/dev/null; then
  cat >> /root/.ssh/config <<SSHCFG
Host github-broker
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
SSHCFG
  chmod 600 /root/.ssh/config
fi
ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null
sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts

# Verify before pausing, so a re-run does not ask for something already done.
if ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github-broker 2>&1 | grep -q "successfully authenticated"; then
  ok "the broker repo is already reachable"
else
  echo ""
  echo -e "${BOLD}Add this deploy key to GitHub, then press Enter:${NC}"
  echo -e "  ${BLUE}https://github.com/SomethingPressing/rebate-finder-broker/settings/keys/new${NC}"
  echo -e "  Title: ${BOLD}staging host${NC}   Write access: ${BOLD}not needed${NC}"
  echo ""
  cat "${KEY}.pub"
  echo ""
  read -rp "  Pressed 'Add key'? [Enter] " _ < /dev/tty
  if ! ssh -T -o BatchMode=yes git@github-broker 2>&1 | grep -q "successfully authenticated"; then
    fail "GitHub still refuses that key. Check it was added to rebate-finder-broker (not another repo), then re-run."
  fi
  ok "authenticated"
fi

# ── 3. This deployment repo ──────────────────────────────────────────────────
log "3/5  Deployment scripts"
if [[ -d "$DEPLOY_DIR/.git" ]]; then
  git -C "$DEPLOY_DIR" pull --quiet --ff-only || warn "could not fast-forward $DEPLOY_DIR — using what is there"
  skip "already cloned at $DEPLOY_DIR"
else
  # Public over HTTPS, so this needs no key of its own.
  git clone --quiet "$DEPLOY_REPO" "$DEPLOY_DIR"
  ok "cloned to $DEPLOY_DIR"
fi

# ── 4. The staging host itself ───────────────────────────────────────────────
log "4/5  Postgres, Redis, schema, build, PM2"
# POSTGRES_ALLOW_REMOTE defaults on here: collectors reach this database
# directly and cannot work without it. Tenants never do — they use /v1.
export POSTGRES_ALLOW_REMOTE="${POSTGRES_ALLOW_REMOTE:-true}"
export BROKER_REPO="$BROKER_REPO_SSH"
export BROKER_ADMIN_EMAIL BROKER_ADMIN_PASSWORD
bash "$DEPLOY_DIR/scripts/broker/setup-staging-host.sh"

# ── 5. TLS, if a domain was given ────────────────────────────────────────────
log "5/5  Reverse proxy and TLS"
if [[ -z "${APP_DOMAIN:-}" ]]; then
  warn "APP_DOMAIN not set — skipping nginx and TLS."
  warn "The broker is reachable on port ${BROKER_PORT:-8080} directly, which is fine for a first look"
  warn "but NOT for a tenant: sites refuse plain HTTP to a public host."
else
  RESOLVED=$(getent hosts "$APP_DOMAIN" | awk '{print $1; exit}' || true)
  if [[ -z "$RESOLVED" ]]; then
    warn "$APP_DOMAIN does not resolve yet — skipping TLS."
    warn "Point an A record at this box, then run:"
    warn "  APP_DOMAIN=$APP_DOMAIN CLOUDFLARE_API_TOKEN=… bash $DEPLOY_DIR/scripts/setup-ssl.sh"
  else
    APP_DOMAIN="$APP_DOMAIN" bash "$DEPLOY_DIR/scripts/setup-nginx.sh" || warn "nginx step failed — see above"
    APP_DOMAIN="$APP_DOMAIN" CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" \
      bash "$DEPLOY_DIR/scripts/setup-ssl.sh" || warn "TLS step failed — see above"
  fi
fi

IP=$(hostname -I | awk '{print $1}')
cat <<SUMMARY

$(printf '\033[1;32m─── broker bootstrapped ───\033[0m')

  Console   ${APP_DOMAIN:+https://$APP_DOMAIN}${APP_DOMAIN:-http://$IP:${BROKER_PORT:-8080}}

$(printf '\033[1;33m  Two things this did NOT do, on purpose:\033[0m')

  1. Create your login. Nothing can sign in until you run this — the password
     is passed inline so it never lands in a file:

       cd /opt/rebate-finder-broker
       BROKER_ADMINS="${BROKER_ADMIN_EMAIL}:a-long-passphrase:Your Name" pnpm seed:admins

  2. Back up /opt/rebate-finder-broker/.env. It holds BROKER_SECRETS_KEY, and
     losing that makes every stored credential unreadable — quietly, with every
     site falling back to its own .env and nothing reporting a problem.

  Then:
    · Managed config → set the Cloudflare token, zone id and default tenant IP
    · bash $DEPLOY_DIR/scripts/broker/connect-tenant.sh    (once per customer)
    · Point collectors at:  postgresql://…@${IP}:5432/incenva_staging

  Write mode is 'shadow' — the promoter writes a comparison table, not the live
  queues. Leave it there until console → Comparison is clean run after run.

SUMMARY
