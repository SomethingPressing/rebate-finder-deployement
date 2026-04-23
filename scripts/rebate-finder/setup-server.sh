#!/usr/bin/env bash
# =============================================================================
# setup-server.sh — Idempotent server setup for Incenva Rebate Finder
#
# Installs prerequisites, creates the system user/group, sets up PostgreSQL,
# writes .env, pushes the Prisma schema, seeds admin users, builds the app,
# and registers it with PM2.
#
# Usage:
#   sudo bash scripts/setup-server.sh
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

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
TMP_PASS_FILE="$PROJECT_DIR/.db_pass_setup_tmp"

# ── Configurable defaults ─────────────────────────────────────────────────────
APP_USER="${APP_USER:-rf}"
APP_GROUP="${APP_GROUP:-rf}"
DB_NAME="${DB_NAME:-rebate_finder}"
DB_USER="${DB_USER:-rf}"
NODE_MAJOR="${NODE_MAJOR:-20}"
PM2_APP_NAME="${PM2_APP_NAME:-Rebate Finder}"

# ── Root guard ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0"

# ── OS check (Debian/Ubuntu) ──────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
  warn "apt-get not found. This script is written for Debian/Ubuntu."
  warn "You may need to adapt the package-install steps for your OS."
fi

hr
echo ""
echo -e "  ${BOLD}Incenva Rebate Finder — Server Setup${NC}"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — System group & user
# ─────────────────────────────────────────────────────────────────────────────
log "1/9  System group and user"

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
  ok "Created user '$APP_USER' (home: /home/$APP_USER)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Node.js
# ─────────────────────────────────────────────────────────────────────────────
log "2/9  Node.js $NODE_MAJOR"

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
log "3/9  pnpm"

if command -v pnpm &>/dev/null; then
  skip "pnpm $(pnpm --version)"
else
  npm install -g pnpm >/dev/null
  ok "Installed pnpm $(pnpm --version)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — PM2
# ─────────────────────────────────────────────────────────────────────────────
log "4/9  PM2"

if command -v pm2 &>/dev/null; then
  skip "PM2 $(pm2 --version 2>/dev/null || echo 'installed')"
else
  npm install -g pm2 >/dev/null
  ok "Installed PM2"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
log "5/9  PostgreSQL"

if command -v psql &>/dev/null; then
  skip "PostgreSQL $(psql --version | head -1)"
else
  apt-get install -y postgresql postgresql-contrib >/dev/null
  systemctl enable --now postgresql
  ok "Installed and started PostgreSQL"
fi

# Ensure PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
  systemctl start postgresql
  ok "Started PostgreSQL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Database role + database
# ─────────────────────────────────────────────────────────────────────────────
log "6/9  Database role '$DB_USER' and database '$DB_NAME'"

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  skip "DB role '$DB_USER'"
else
  # Generate a secure random password
  DB_PASS="$(openssl rand -base64 30 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';" >/dev/null
  echo "$DB_PASS" > "$TMP_PASS_FILE"
  chmod 600 "$TMP_PASS_FILE"
  ok "Created DB role '$DB_USER'"
  echo ""
  warn "DB password (shown once — stored temporarily in $TMP_PASS_FILE):"
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
# STEP 7 — .env file
# ─────────────────────────────────────────────────────────────────────────────
log "7/9  Environment file (.env)"

if [[ -f "$ENV_FILE" ]]; then
  skip ".env already exists — not overwriting"
  warn "If DATABASE_URL or JWT_SECRET are wrong, edit $ENV_FILE manually."
else
  cp "$PROJECT_DIR/.env.example" "$ENV_FILE"

  # Inject JWT secret
  JWT_SECRET="$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")"
  sed -i "s|your-long-random-secret-here-min-32-chars|$JWT_SECRET|" "$ENV_FILE"

  # Inject DATABASE_URL if we just created the DB role
  if [[ -f "$TMP_PASS_FILE" ]]; then
    DB_PASS="$(cat "$TMP_PASS_FILE")"
    sed -i \
      "s|postgresql://USER:PASSWORD@HOST:5432/DATABASE|postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME|" \
      "$ENV_FILE"
    rm -f "$TMP_PASS_FILE"
    ok "DATABASE_URL set in .env"
  else
    warn "DB role existed before setup — set DATABASE_URL in $ENV_FILE manually."
  fi

  chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ok "Created $ENV_FILE with auto-generated JWT_SECRET"
  warn "Review .env and fill in: OPENAI_API_KEY, NEXT_PUBLIC_SUPABASE_*, etc."
fi

# Load DATABASE_URL from .env for Prisma commands
# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | grep -E '^(DATABASE_URL|JWT_SECRET)=' | xargs)

if [[ -z "${DATABASE_URL:-}" ]]; then
  fail "DATABASE_URL is not set in $ENV_FILE. Edit it and re-run this script."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Install deps, push schema, seed
# ─────────────────────────────────────────────────────────────────────────────
log "8/9  Dependencies, schema, and seed"

cd "$PROJECT_DIR"

# Ensure app user owns the project directory (so pnpm writes work)
chown -R "$APP_USER:$APP_GROUP" "$PROJECT_DIR"
chmod g+rw "$PROJECT_DIR"

ok "Installing npm dependencies…"
sudo -u "$APP_USER" pnpm install --frozen-lockfile 2>&1 | tail -3

ok "Pushing Prisma schema to database…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; pnpm prisma db push --skip-generate"
ok "Schema up to date"

ok "Regenerating Prisma client…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; pnpm prisma generate" 2>&1 | tail -1

# Check whether admin users already exist
EXISTING_USERS="$(sudo -u postgres psql -d "$DB_NAME" -tAc \
  "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")"
EXISTING_USERS="${EXISTING_USERS//[[:space:]]/}"

if [[ "${EXISTING_USERS:-0}" -gt 0 ]]; then
  skip "Seed ($EXISTING_USERS user(s) already in DB — upsert-safe, running anyway)"
fi

ok "Running seed (upserts are idempotent — safe to repeat)…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; pnpm prisma db seed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Build and PM2
# ─────────────────────────────────────────────────────────────────────────────
log "9/9  Production build and PM2"

ok "Building Next.js app…"
sudo -u "$APP_USER" bash -c "export DATABASE_URL='$DATABASE_URL'; pnpm build"
ok "Build complete"

if sudo -u "$APP_USER" pm2 list 2>/dev/null | grep -q "$PM2_APP_NAME"; then
  sudo -u "$APP_USER" pm2 restart "$PM2_APP_NAME"
  ok "Restarted PM2 process '$PM2_APP_NAME'"
else
  sudo -u "$APP_USER" bash -c "
    cd '$PROJECT_DIR'
    pm2 start 'pnpm start' \
      --name '$PM2_APP_NAME' \
      --env-file '$ENV_FILE'
  "
  ok "Started PM2 process '$PM2_APP_NAME'"
fi

sudo -u "$APP_USER" pm2 save >/dev/null

# Configure PM2 to start on boot
STARTUP_CMD="$(sudo -u "$APP_USER" pm2 startup systemd \
  -u "$APP_USER" --hp "/home/$APP_USER" 2>/dev/null | grep '^sudo' | head -1 || true)"
if [[ -n "$STARTUP_CMD" ]]; then
  eval "$STARTUP_CMD" >/dev/null 2>&1 || true
fi
ok "PM2 startup configured for user '$APP_USER'"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
hr
echo ""
echo -e "  ${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  App URL:    http://localhost:3000  (proxy port 80/443 with Nginx)"
echo "  PM2 status: pm2 status"
echo "  App logs:   pm2 logs '$PM2_APP_NAME'"
echo ""
echo -e "  ${YELLOW}Default admin login:${NC}"
echo "    Email:    admin@incenva.com"
echo "    Password: Admin1234!"
echo -e "  ${YELLOW}→ Change this immediately after first login.${NC}"
echo ""
echo "  Review and complete these settings in $ENV_FILE:"
echo "    • OPENAI_API_KEY"
echo "    • NEXT_PUBLIC_SUPABASE_URL / _ANON_KEY / _PROJECT_ID / SUPABASE_SERVICE_KEY"
echo "    • NEXT_BASE_URL  (set to your public domain)"
echo ""
hr
