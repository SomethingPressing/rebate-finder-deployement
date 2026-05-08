#!/usr/bin/env bash
# =============================================================================
# deploy-fly.sh — Deploy Incenva Scraper to fly.io
#
# Thin wrapper: delegates to the deploy script inside the scraper repo.
#
# Usage:
#   bash scripts/scraper/deploy-fly.sh
#
# Override scraper repo path:
#   SCRAPER_DIR=/path/to/rebate-finder-scrapers bash scripts/scraper/deploy-fly.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }

SCRAPER_DIR="${SCRAPER_DIR:-/home/rf/apps/incenva-scraper-service}"

[[ -d "$SCRAPER_DIR" ]] || fail "Scraper repo not found at $SCRAPER_DIR. Set SCRAPER_DIR env var."
[[ -f "$SCRAPER_DIR/scripts/deploy-fly.sh" ]] || fail "deploy-fly.sh not found in $SCRAPER_DIR/scripts/"

exec bash "$SCRAPER_DIR/scripts/deploy-fly.sh" "$@"
