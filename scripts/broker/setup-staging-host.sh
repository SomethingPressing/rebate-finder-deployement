#!/usr/bin/env bash
# =============================================================================
# setup-staging-host.sh — provision the shared staging host (v0.8 Feature 8)
#
# The staging host is one machine running:
#   • PostgreSQL   the shared staging database every collector writes into,
#                  plus the broker's own `broker` schema
#   • Redis        BullMQ job state for the promoter. Nothing durable.
#   • the broker   Next.js app (super-admin console + /v1 wire contract) and
#                  the promoter worker, as two PM2 processes from one repo
#
# Run ON the target machine as root (or with sudo), the same way bootstrap.sh
# is run for a customer box.
#
#   ./setup-staging-host.sh
#
# ── Required env vars ────────────────────────────────────────────────────────
#   BROKER_ADMIN_PASSWORD   password for the super-admin console
#
# ── Optional env vars ────────────────────────────────────────────────────────
#   BROKER_REPO             git URL for rebate-finder-broker
#                           (default: git@github.com:SomethingPressing/rebate-finder-broker.git)
#   BROKER_BRANCH           branch to deploy (default: main)
#   STAGING_DB_NAME         database name (default: incenva_staging)
#   STAGING_DB_USER         database role (default: incenva)
#   STAGING_DB_PASSWORD     generated when unset — printed once at the end
#   BROKER_PORT             HTTP port for the broker (default: 8080)
#   PROMOTER_WRITE_MODE     shadow | live (default: shadow — see the plan; the
#                           promoter writes a comparison table until parity is
#                           proven run after run)
#   POSTGRES_ALLOW_REMOTE   "true" to let collectors reach Postgres from
#                           outside. Collectors need this; tenants never do.
#
# NOTE ON SECRETS: this script prints the generated database password once.
# There is no way to recover it afterwards — store it before closing the shell.
# =============================================================================
set -euo pipefail

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root (or with sudo)"
[[ -n "${BROKER_ADMIN_PASSWORD:-}" ]] || fail "BROKER_ADMIN_PASSWORD is required — the console is locked without it"

BROKER_REPO="${BROKER_REPO:-git@github.com:SomethingPressing/rebate-finder-broker.git}"
BROKER_BRANCH="${BROKER_BRANCH:-main}"
STAGING_DB_NAME="${STAGING_DB_NAME:-incenva_staging}"
STAGING_DB_USER="${STAGING_DB_USER:-incenva}"
STAGING_DB_PASSWORD="${STAGING_DB_PASSWORD:-$(openssl rand -hex 24)}"
BROKER_PORT="${BROKER_PORT:-8080}"
PROMOTER_WRITE_MODE="${PROMOTER_WRITE_MODE:-shadow}"
APP_DIR=/opt/rebate-finder-broker

# ── 1. System packages ───────────────────────────────────────────────────────
log "Installing PostgreSQL, Redis, Node.js and PM2"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-contrib redis-server git curl ca-certificates >/dev/null

if ! command -v node >/dev/null || [[ "$(node -v | cut -c2- | cut -d. -f1)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
corepack enable >/dev/null 2>&1 || npm install -g pnpm >/dev/null
command -v pm2 >/dev/null || npm install -g pm2 >/dev/null
ok "packages installed ($(node -v), $(psql --version | awk '{print $3}'))"

# ── 2. Postgres: the shared staging database ─────────────────────────────────
log "Creating the staging database and role"
systemctl enable --now postgresql >/dev/null

sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${STAGING_DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -q -c "CREATE ROLE ${STAGING_DB_USER} LOGIN PASSWORD '${STAGING_DB_PASSWORD}'"
sudo -u postgres psql -q -c "ALTER ROLE ${STAGING_DB_USER} PASSWORD '${STAGING_DB_PASSWORD}'"

sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${STAGING_DB_NAME}'" | grep -q 1 || \
  sudo -u postgres createdb -O "${STAGING_DB_USER}" "${STAGING_DB_NAME}"

# The scraper schema is owned by the collectors' GORM migrations and the broker
# schema by the broker itself. Both are created by their owners at runtime —
# this script only makes sure the role is allowed to create them.
sudo -u postgres psql -q -d "${STAGING_DB_NAME}" -c "GRANT ALL ON DATABASE ${STAGING_DB_NAME} TO ${STAGING_DB_USER}"
ok "database ${STAGING_DB_NAME} ready"

if [[ "${POSTGRES_ALLOW_REMOTE:-false}" == "true" ]]; then
  # Collectors run elsewhere (Fly) and reach the staging database directly.
  # Tenants never do — they only ever speak HTTP to the broker.
  PG_CONF=$(sudo -u postgres psql -tAc "SHOW config_file")
  PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file")
  grep -q "^listen_addresses = '\*'" "$PG_CONF" || echo "listen_addresses = '*'" >> "$PG_CONF"
  grep -q "0.0.0.0/0" "$PG_HBA" || echo "host ${STAGING_DB_NAME} ${STAGING_DB_USER} 0.0.0.0/0 scram-sha-256" >> "$PG_HBA"
  systemctl restart postgresql
  warn "Postgres is reachable from anywhere — restrict this to the collectors' addresses with a firewall"
fi

# ── 3. Redis ─────────────────────────────────────────────────────────────────
log "Enabling Redis"
systemctl enable --now redis-server >/dev/null
redis-cli ping >/dev/null || fail "Redis did not answer PING"
ok "Redis running (BullMQ job state only — the queues themselves live in Postgres)"

# ── 4. The broker ────────────────────────────────────────────────────────────
log "Deploying the broker from ${BROKER_BRANCH}"
if [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch --quiet origin "$BROKER_BRANCH"
  git -C "$APP_DIR" reset --hard --quiet "origin/${BROKER_BRANCH}"
else
  git clone --quiet --branch "$BROKER_BRANCH" "$BROKER_REPO" "$APP_DIR"
fi

# Secrets the operator should never have to invent. Generated once, here, and
# then left alone: BROKER_SECRETS_KEY in particular must survive, because
# changing it makes every stored credential undecryptable and every site
# silently falls back to its own .env — a failure with no error message.
BROKER_SECRETS_KEY="${BROKER_SECRETS_KEY:-$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 48)}"
BROKER_SESSION_SECRET="${BROKER_SESSION_SECRET:-$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 48)}"

cat > "$APP_DIR/.env" <<ENV
DATABASE_URL=postgresql://${STAGING_DB_USER}:${STAGING_DB_PASSWORD}@localhost:5432/${STAGING_DB_NAME}
REDIS_URL=redis://localhost:6379
PORT=${BROKER_PORT}
LOG_LEVEL=info
LOG_FORMAT=json
PROMOTER_INTERVAL_MS=60000
PROMOTER_WRITE_MODE=${PROMOTER_WRITE_MODE}
BROKER_ADMIN_PASSWORD=${BROKER_ADMIN_PASSWORD}
# Signs console sessions. Rotating it logs everybody out without changing a password.
BROKER_SESSION_SECRET=${BROKER_SESSION_SECRET}
# Encrypts everything in Managed config. KEEP IT — see the note above.
BROKER_SECRETS_KEY=${BROKER_SECRETS_KEY}
QUEUE_RATE_LIMIT_PER_MINUTE=120
QUEUE_REMOVAL_RETENTION_DAYS=7
ENV
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
pnpm install --frozen-lockfile --silent

# The broker owns broker.* through Prisma and nothing else — the datasource is
# scoped to that schema, so this can never touch the collectors' scraper.* or a
# tenant's public.*. Without it the console's newer tables do not exist and
# pages fail one by one rather than all at once, which is harder to diagnose.
log "Creating the broker schema"
pnpm db:push
ok "broker.* is in sync with the schema"

pnpm build

# A console nobody can sign into is not much use. Idempotent, and also the
# recovery path if everyone is locked out later.
log "Seeding the super-admin account"
pnpm seed:admins || warn "could not seed an admin — run 'pnpm seed:admins' by hand"

log "Starting the broker under PM2"
pm2 delete incenva-broker incenva-broker-promoter >/dev/null 2>&1 || true
pm2 start ecosystem.config.cjs
pm2 save >/dev/null
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
ok "broker running — two processes, one repo"

# ── 5. Verify ────────────────────────────────────────────────────────────────
log "Checking health"
sleep 4
if curl -fsS "http://localhost:${BROKER_PORT}/healthz" >/dev/null; then
  ok "/healthz answered — Postgres and Redis both reachable"
else
  warn "/healthz did not answer yet; check: pm2 logs incenva-broker"
fi

cat <<SUMMARY

$(printf '\033[1;32m─── staging host ready ───\033[0m')

  Console       http://$(hostname -I | awk '{print $1}'):${BROKER_PORT}/
  Health        http://$(hostname -I | awk '{print $1}'):${BROKER_PORT}/healthz
  Wire contract http://$(hostname -I | awk '{print $1}'):${BROKER_PORT}/v1/...
  Write mode    ${PROMOTER_WRITE_MODE}

  Collectors point at:
    DATABASE_URL=postgresql://${STAGING_DB_USER}:${STAGING_DB_PASSWORD}@$(hostname -I | awk '{print $1}'):5432/${STAGING_DB_NAME}

$(printf '\033[1;33m  Store that password now — it is not recoverable.\033[0m')

  Next, in this order:
    1. TLS, before any tenant uses it. scripts/setup-nginx.sh and
       scripts/setup-ssl.sh do the same job they do for a customer box.
       Until then every bearer key and managed credential crosses the network
       in cleartext — and tenant sites now REFUSE plain HTTP to a public host
       unless BROKER_ALLOW_INSECURE is set, so this is a real blocker, not
       advice.
    2. Connect each tenant:  bash scripts/broker/connect-tenant.sh
    3. Leave PROMOTER_WRITE_MODE=shadow until the comparison is clean run after
       run (console → Comparison, or \`pnpm compare\`).

  Secrets written to $APP_DIR/.env — back it up:
    BROKER_SECRETS_KEY      lose it and stored credentials become unreadable
    BROKER_SESSION_SECRET   rotate to log everyone out
    BROKER_ADMIN_PASSWORD   the one you supplied

SUMMARY
