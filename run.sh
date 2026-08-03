#!/usr/bin/env bash
# =============================================================================
# run.sh — Load secrets.local and run provision.sh
#
# Usage:
#   bash run.sh                    # full provision (new Droplet)
#   DROPLET_IP=1.2.3.4 bash run.sh # skip creation, reconnect to existing server
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/secrets.local"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo ""
  echo "  [error] secrets.local not found."
  echo ""
  echo "  Create it by copying the example:"
  echo "    cp secrets.local.example secrets.local"
  echo "  Then fill in your values and run again."
  echo ""
  exit 1
fi

# Load secrets (skip comments and blank lines)
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

echo "  Loaded secrets.local"
echo ""

exec bash "$SCRIPT_DIR/scripts/provision.sh" "$@"
