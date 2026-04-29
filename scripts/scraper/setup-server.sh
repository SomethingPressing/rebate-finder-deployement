#!/usr/bin/env bash
# =============================================================================
# setup-server.sh — Idempotent server setup for Incenva Scraper Service
#
# Installs Go, clones the repo, writes .env, and builds the scraper binaries.
# The scraper is NOT registered with PM2 — run it manually or via cron.
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

ENV_FILE="$APP_DIR/.env"

hr
echo ""
echo -e "  ${BOLD}Incenva Scraper Service — Server Setup${NC}"
echo "  App directory: $APP_DIR"
echo ""
hr

# ─────────────────────────────────────────────────────────────────────────────
log "1/4  System group and user"

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
log "2/4  Go $GO_VERSION"

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

  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  export PATH="$PATH:/usr/local/go/bin"
  ok "Installed Go $(go version | awk '{print $3}')"
fi

export PATH="$PATH:/usr/local/go/bin"
command -v go &>/dev/null || fail "go not found in PATH after install."

# ─────────────────────────────────────────────────────────────────────────────
log "3/4  Repository"

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
log "4/4  Environment file and binaries"

if [[ -f "$ENV_FILE" ]]; then
  skip ".env already exists"
else
  cp "$APP_DIR/.env.example" "$ENV_FILE"
  chown "$APP_USER:$APP_GROUP" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ok "Created $ENV_FILE"
  warn "Set REWIRING_AMERICA_API_KEY in $ENV_FILE."
fi

# Always sync shared vars from the consumer app (covers first run and re-runs)
CONSUMER_ENV="$CONSUMER_APP_DIR/.env"
if [[ -f "$CONSUMER_ENV" ]]; then
  _sync_var() {
    local varname="$1"
    local val
    val="$(grep -E "^${varname}=" "$CONSUMER_ENV" | head -1 || true)"
    if [[ -n "$val" ]]; then
      sed -i "s|^${varname}=.*|$val|" "$ENV_FILE"
      ok "$varname synced from consumer app"
    else
      warn "$varname not found in $CONSUMER_ENV — set it manually in $ENV_FILE."
    fi
  }
  _sync_var DATABASE_URL
  _sync_var SCRAPER_DB_SCHEMA
  _sync_var PROMOTER_SOURCE_PRIORITY
else
  warn "Consumer app .env not found at $CONSUMER_ENV — set DATABASE_URL, SCRAPER_DB_SCHEMA, PROMOTER_SOURCE_PRIORITY in $ENV_FILE manually."
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

ok "Building cmd/promoter…"
sudo -u "$APP_USER" bash -c "export PATH=\$PATH:/usr/local/go/bin; cd '$APP_DIR' && go build -o bin/promoter ./cmd/promoter"

ok "Building cmd/staging-stats…"
sudo -u "$APP_USER" bash -c "export PATH=\$PATH:/usr/local/go/bin; cd '$APP_DIR' && go build -o bin/staging-stats ./cmd/staging-stats"

if [[ -d "$APP_DIR/cmd/pdf-scraper" ]]; then
  ok "Building cmd/pdf-scraper…"
  sudo -u "$APP_USER" bash -c "export PATH=\$PATH:/usr/local/go/bin; cd '$APP_DIR' && go build -o bin/pdf-scraper ./cmd/pdf-scraper"
else
  warn "cmd/pdf-scraper not found — skipping (add it to the repo when ready)"
fi

ok "Binaries built"

hr
echo ""
echo -e "  ${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  Binaries: $APP_DIR/bin/"
echo ""
echo "  Still to configure in $ENV_FILE:"
echo "    REWIRING_AMERICA_API_KEY"
echo ""
echo "  Run the scraper manually:"
echo "    sudo -u $APP_USER $APP_DIR/bin/scraper"
echo ""
echo "  Check staging table analytics:"
echo "    sudo -u $APP_USER $APP_DIR/bin/staging-stats"
echo "    sudo -u $APP_USER $APP_DIR/bin/staging-stats --json"
echo ""
hr
