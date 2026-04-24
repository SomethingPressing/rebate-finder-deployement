#!/usr/bin/env bash
# =============================================================================
# setup-server.sh — Idempotent server setup for Incenva Scraper Service
#
# Installs Go, builds the scraper binaries, clones the repo, writes .env,
# and registers the scheduled scraper with PM2.
#
# Usage:
#   sudo bash scripts/scraper/setup-server.sh
#
# Override defaults:
#   APP_REPO_URL=git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git sudo bash ...
#
# Safe to run multiple times.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[setup]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
skip() { echo -e "  ${YELLOW}─${NC}  $* (already done)"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash $0"

APP_USER="${APP_USER:-rf}"
APP_GROUP="${APP_GROUP:-rf}"
APP_DIR="${APP_DIR:-/home/rf/apps/incenva-scraper-service}"
APP_REPO_URL="${APP_REPO_URL:-}"
CONSUMER_APP_DIR="${CONSUMER_APP_DIR:-/home/rf/apps/rebate-finder}"
GO_VERSION="${GO_VERSION:-1.22.3}"
GO_ARCH="${GO_ARCH:-linux-amd64}"
PM2_APP_NAME="${PM2_APP_NAME:-Incenva Scraper}"

ENV_FILE="$APP_DIR/.env"

hr
echo ""
echo -e "  ${BOLD}Incenva Scraper Service — Server Setup${NC}"
echo "  App directory: $APP_DIR"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
log "1/6  System group and user"

if getent group "$APP_GROUP" &>/dev/null; then
  skip "Group '$APP_GROUP'"
else
  groupadd --system "$APP_GROUP"
  ok "Created group '$APP_GROUP'"
fi

if id "$APP_USER" &>/dev/null; then
  skip "User '$APP_USER'"
else
  useradd --system --gid "$APP_GROUP" --shell /bin/bash \
    --home-dir "/home/$APP_USER" --create-home "$APP_USER"
  ok "Created user '$APP_USER'"
fi

mkdir -p "$(dirname "$APP_DIR")"
chown "$APP_USER:$APP_GROUP" "$(dirname "$APP_DIR")"

# ─────────────────────────────────────────────────────────────────────────────
log "2/6  Go $GO_VERSION"

GO_INSTALLED_VER="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true)"
if [[ "$GO_INSTALLED_VER" == "$GO_VERSION" ]]; then
  skip "Go $GO_VERSION"
else
  GO_TARBALL="go${GO_VERSION}.${GO_ARCH}.tar.gz"
  ok "Downloading $GO_TARBALL…"
  curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "/tmp/$GO_TARBALL"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$GO_TARBALL"
  rm -f "/tmp/$GO_TARBALL"

  GO_LINE='export PATH=$PATH:/usr/local/go/bin'
  for f in /etc/profile.d/go.sh "/home/$APP_USER/.bashrc"; do
    grep -qF "$GO_LINE" "$f" 2>/dev/null || echo "$GO_LINE" >> "$f"
  done
  export PATH="$PATH:/usr/local/go/bin"
  ok "Installed Go $(go version | awk '{print $3}')"
fi

export PATH="$PATH:/usr/local/go/bin"
command -v go &>/dev/null || fail "go not found in PATH after install."

# ─────────────────────────────────────────────────────────────────────────────
log "3/6  PM2"

if command -v pm2 &>/dev/null; then
  skip "PM2 $(pm2 --version 2>/dev/null || echo 'installed')"
else
  command -v npm &>/dev/null || fail "npm not found. Run rebate-finder setup-server.sh first."
  npm install -g pm2 >/dev/null
  ok "Installed PM2"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "4/6  Repository"

if [[ -d "$APP_DIR/.git" ]]; then
  skip "Repo already at $APP_DIR"
  sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && git pull"
  ok "git pull done"
else
  [[ -n "$APP_REPO_URL" ]] || fail "APP_DIR does not exist and APP_REPO_URL is not set.\nSet it: APP_REPO_URL=git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git sudo bash $0"
  sudo -u "$APP_USER" git clone "$APP_REPO_URL" "$APP_DIR"
  ok "Cloned $APP_REPO_URL → $APP_DIR"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "5/6  Environment file and binaries"

if [[ -f "$ENV_FILE" ]]; then
  skip ".env already exists"
else
  cp "$APP_DIR/.env.example" "$ENV_FILE"

  CONSUMER_ENV="$CONSUMER_APP_DIR/.env"
  if [[ -f "$CONSUMER_ENV" ]]; then
    INHERITED="$(grep -E '^DATABASE_URL=' "$CONSUMER_ENV" | head -1 || true)"
    if [[ -n "$INHERITED" ]]; then
      sed -i "s|^DATABASE_URL=.*|$INHERITED|" "$ENV_FILE"
      ok "DATABASE_URL inherited from consumer app"
    fi
  else
    warn "Consumer app .env not found at $CONSUMER_ENV"
    warn "Set DATABASE_URL in $ENV_FILE manually."
  fi

  chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ok "Created $ENV_FILE"
  warn "Set REWIRING_AMERICA_API_KEY in $ENV_FILE."
fi

DATABASE_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)"
export DATABASE_URL
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE."

mkdir -p "$APP_DIR/bin"
chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

ok "Downloading Go modules…"
sudo -u "$APP_USER" bash -c "export PATH=\$PATH:/usr/local/go/bin; cd '$APP_DIR' && go mod download"

ok "Building cmd/scraper…"
sudo -u "$APP_USER" bash -c "export PATH=\$PATH:/usr/local/go/bin; cd '$APP_DIR' && go build -o bin/scraper ./cmd/scraper"

ok "Building cmd/pdf-scraper…"
sudo -u "$APP_USER" bash -c "export PATH=\$PATH:/usr/local/go/bin; cd '$APP_DIR' && go build -o bin/pdf-scraper ./cmd/pdf-scraper"

ok "Binaries built"

# ─────────────────────────────────────────────────────────────────────────────
log "6/6  PM2 process"

if sudo -u "$APP_USER" pm2 list 2>/dev/null | grep -q "$PM2_APP_NAME"; then
  sudo -u "$APP_USER" pm2 restart "$PM2_APP_NAME"
  ok "Restarted '$PM2_APP_NAME'"
else
  sudo -u "$APP_USER" bash -c "
    cd '$APP_DIR'
    pm2 start bin/scraper \
      --name '$PM2_APP_NAME' \
      --interpreter none \
      --env-file '$ENV_FILE'
  "
  ok "Started '$PM2_APP_NAME'"
fi

sudo -u "$APP_USER" pm2 save >/dev/null
STARTUP_CMD="$(sudo -u "$APP_USER" pm2 startup systemd \
  -u "$APP_USER" --hp "/home/$APP_USER" 2>/dev/null | grep '^sudo' | head -1 || true)"
if [[ -n "$STARTUP_CMD" ]]; then
  eval "$STARTUP_CMD" >/dev/null 2>&1 || true
fi
ok "PM2 startup configured"

hr
echo ""
echo -e "  ${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  PM2 status: pm2 status"
echo "  Logs:       pm2 logs '$PM2_APP_NAME'"
echo ""
echo "  Still to configure in $ENV_FILE:"
echo "    REWIRING_AMERICA_API_KEY"
echo "    CONSUMERS_ENERGY_CATALOG_PDF / CONSUMERS_ENERGY_APPLICATION_PDF (PDF scraper)"
echo ""
hr
