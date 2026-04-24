#!/usr/bin/env bash
# =============================================================================
# setup-server.sh — Idempotent server setup for Incenva Rebate Finder
#
# Installs prerequisites, creates the system user/group, sets up PostgreSQL,
# clones the app repo, writes .env, pushes the Prisma schema, seeds the DB,
# builds the app, and registers it with PM2.
#
# Usage:
#   sudo bash scripts/rebate-finder/setup-server.sh
#
# Override defaults via environment variables before running:
#   APP_REPO_URL=git@github-rebate-finder:SomethingPressing/rebate-finder.git sudo bash ...
#
# Safe to run multiple times — every step checks if work is already done.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[setup]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
skip() { echo -e "  ${YELLOW}─${NC}  $* (already done)"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

# ── Root guard ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0"

# ── Configurable defaults ─────────────────────────────────────────────────────
APP_USER="${APP_USER:-rf}"
APP_GROUP="${APP_GROUP:-rf}"
APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
APP_REPO_URL="${APP_REPO_URL:-}"                  # required if APP_DIR doesn't exist yet
DB_NAME="${DB_NAME:-rebate_finder}"
DB_USER="${DB_USER:-rf}"
NODE_MAJOR="${NODE_MAJOR:-20}"
PM2_APP_NAME="${PM2_APP_NAME:-incenva-rebate-finder}"

ENV_FILE="$APP_DIR/.env"
TMP_PASS_FILE="/tmp/.rf_db_pass_setup"

hr
echo ""
echo -e "  ${BOLD}Incenva Rebate Finder — Server Setup${NC}"
echo "  App directory: $APP_DIR"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — System group & user
# ─────────────────────────────────────────────────────────────────────────────
log "1/10  System group and user"

if getent group "$APP_GROUP" &>/dev/null; then
  skip "Group '$APP_GROUP'"
else
  groupadd --system "$APP_GROUP"
  ok "Created group '$APP_GROUP'"
fi

if id "$APP_USER" &>/dev/null; then
  skip "User '$APP_USER'"
else
  useradd \
    --system \
    --gid "$APP_GROUP" \
    --shell /bin/bash \
    --home-dir "/home/$APP_USER" \
    --create-home \
    "$APP_USER"
  ok "Created user '$APP_USER'"
fi

mkdir -p "$(dirname "$APP_DIR")"
chown "$APP_USER:$APP_GROUP" "$(dirname "$APP_DIR")"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Node.js
# ─────────────────────────────────────────────────────────────────────────────
log "2/10  Node.js $NODE_MAJOR"

CURRENT_NODE_MAJOR=""
if command -v node &>/dev/null; then
  CURRENT_NODE_MAJOR="$(node --version | sed 's/^v//' | cut -d. -f1)"
fi

if [[ "$CURRENT_NODE_MAJOR" == "$NODE_MAJOR" ]]; then
  skip "Node.js $(node --version)"
else
  apt-get update -qq
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
  ok "Installed Node.js $(node --version)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — pnpm
# ─────────────────────────────────────────────────────────────────────────────
log "3/10  pnpm"

if command -v pnpm &>/dev/null; then
  skip "pnpm $(pnpm --version)"
else
  npm install -g pnpm >/dev/null
  ok "Installed pnpm $(pnpm --version)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — PM2
# ─────────────────────────────────────────────────────────────────────────────
log "4/10  PM2"

if command -v pm2 &>/dev/null; then
  skip "PM2 $(pm2 --version 2>/dev/null || echo 'installed')"
else
  npm install -g pm2 >/dev/null
  ok "Installed PM2"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
log "5/10  PostgreSQL"

if command -v psql &>/dev/null; then
  skip "PostgreSQL $(psql --version | head -1)"
else
  apt-get install -y postgresql postgresql-contrib >/dev/null
  systemctl enable --now postgresql
  ok "Installed and started PostgreSQL"
fi

if ! systemctl is-active --quiet postgresql; then
  systemctl start postgresql
  ok "Started PostgreSQL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — PostgreSQL role + database
# ─────────────────────────────────────────────────────────────────────────────
log "6/10  Database role '$DB_USER' and database '$DB_NAME'"

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  skip "DB role '$DB_USER'"
else
  DB_PASS="$(openssl rand -base64 30 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';" >/dev/null
  echo "$DB_PASS" > "$TMP_PASS_FILE"
  chmod 600 "$TMP_PASS_FILE"
  ok "Created DB role '$DB_USER'"
  echo ""
  warn "DB password (shown once, stored temporarily in $TMP_PASS_FILE):"
  echo -e "     ${BOLD}$DB_USER  →  $DB_PASS${NC}"
  echo ""
fi

if sudo -u postgres psql -lqt | cut -d'|' -f1 | grep -qw "$DB_NAME"; then
  skip "Database '$DB_NAME'"
else
  sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" >/dev/null
  ok "Created database '$DB_NAME'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Clone the repository
# ─────────────────────────────────────────────────────────────────────────────
log "7/10  Application repository"

if [[ -d "$APP_DIR/.git" ]]; then
  skip "Repo already at $APP_DIR"
  sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && git pull"
  ok "git pull done"
else
  [[ -n "$APP_REPO_URL" ]] || fail "APP_DIR does not exist and APP_REPO_URL is not set.\nSet it: APP_REPO_URL=git@github-rebate-finder:SomethingPressing/rebate-finder.git sudo bash $0"
  sudo -u "$APP_USER" git clone "$APP_REPO_URL" "$APP_DIR"
  ok "Cloned $APP_REPO_URL → $APP_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — .env file
# ─────────────────────────────────────────────────────────────────────────────
log "8/10  Environment file"

if [[ -f "$ENV_FILE" ]]; then
  skip ".env already exists — not overwriting"
  warn "If DATABASE_URL or JWT_SECRET are wrong, edit $ENV_FILE manually."
else
  cp "$APP_DIR/.env.example" "$ENV_FILE"

  JWT_SECRET="$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")"
  sed -i "s|your-long-random-secret-here-min-32-chars|$JWT_SECRET|" "$ENV_FILE"

  if [[ -f "$TMP_PASS_FILE" ]]; then
    DB_PASS="$(cat "$TMP_PASS_FILE")"
    sed -i \
      "s|postgresql://USER:PASSWORD@HOST:5432/DATABASE|postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME|" \
      "$ENV_FILE"
    rm -f "$TMP_PASS_FILE"
    ok "DATABASE_URL set in .env"
  else
    warn "DB role already existed — set DATABASE_URL in $ENV_FILE manually."
  fi

  # Set NEXT_BASE_URL from domain (strip trailing slash)
  _DOMAIN="${APP_DOMAIN:-_}"
  if [[ "$_DOMAIN" != "_" && -n "$_DOMAIN" ]]; then
    _BASE_URL="http://${_DOMAIN%/}"
    sed -i "s|NEXT_BASE_URL=.*|NEXT_BASE_URL=$_BASE_URL|" "$ENV_FILE"
    ok "NEXT_BASE_URL set to $_BASE_URL"
  fi

  # Remove HOSTNAME — Next.js binds to 0.0.0.0 by default; only PORT is needed
  sed -i '/^HOSTNAME=/d' "$ENV_FILE"

  chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ok "Created $ENV_FILE (JWT_SECRET auto-generated)"
  warn "Review $ENV_FILE and fill in: OPENAI_API_KEY, NEXT_PUBLIC_SUPABASE_*"
fi

# Load DATABASE_URL for Prisma commands (parse explicitly to avoid IFS/xargs word-split issues)
DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
export DATABASE_URL
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE. Edit it and re-run."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Install deps, push schema, seed
# ─────────────────────────────────────────────────────────────────────────────
log "9/10  Dependencies, schema, and seed"

cd "$APP_DIR"
chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

ok "Installing npm dependencies…"
sudo -u "$APP_USER" pnpm install --frozen-lockfile 2>&1 | tail -3

ok "Pushing Prisma schema…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; pnpm prisma db push --skip-generate"

ok "Regenerating Prisma client…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; pnpm prisma generate" 2>&1 | tail -1

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Build and PM2
# ─────────────────────────────────────────────────────────────────────────────
log "10/10  Production build and PM2"

ok "Building Next.js app…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; cd '$APP_DIR' && pnpm build"
ok "Build complete"

if sudo -u "$APP_USER" pm2 list 2>/dev/null | grep -q "$PM2_APP_NAME"; then
  sudo -u "$APP_USER" pm2 restart "$PM2_APP_NAME"
  ok "Restarted '$PM2_APP_NAME'"
else
  sudo -u "$APP_USER" bash -c "
    cd '$APP_DIR'
    pm2 start 'pnpm start' \
      --name '$PM2_APP_NAME'
  "
  ok "Started '$PM2_APP_NAME' (pnpm start)"
fi

sudo -u "$APP_USER" pm2 save >/dev/null

STARTUP_CMD="$(sudo -u "$APP_USER" pm2 startup systemd \
  -u "$APP_USER" --hp "/home/$APP_USER" 2>/dev/null | grep '^sudo' | head -1 || true)"
if [[ -n "$STARTUP_CMD" ]]; then
  eval "$STARTUP_CMD" >/dev/null 2>&1 || true
fi
ok "PM2 startup configured"

# ─────────────────────────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  App URL:    http://localhost:3000"
echo "  PM2 status: pm2 status"
echo "  Logs:       pm2 logs '$PM2_APP_NAME'"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo "  1. Edit $ENV_FILE"
echo "     → OPENAI_API_KEY, NEXT_PUBLIC_SUPABASE_*, NEXT_BASE_URL"
echo "  2. Rebuild after editing .env:"
echo "     bash scripts/rebate-finder/deploy.sh"
echo ""
hr
