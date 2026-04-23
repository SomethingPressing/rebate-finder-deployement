#!/usr/bin/env bash
# =============================================================================
# create-admin.sh — Create or update an admin user in Incenva Rebate Finder
#
# Usage:
#   bash scripts/create-admin.sh <email> <password> [full_name] [role]
#
# Role options (default: super_admin):
#   super_admin | org_admin | approver | editor | viewer
#
# This script is idempotent — running it twice with the same email updates the
# existing user instead of creating a duplicate.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
fail() { echo -e "\n${RED}[error]${NC} $*\n"; exit 1; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }

APP_DIR="${APP_DIR:-/home/rf/apps/rebate-finder}"
ENV_FILE="$APP_DIR/.env"

EMAIL="${1:-}"
PASSWORD="${2:-}"
FULL_NAME="${3:-Admin User}"
ROLE="${4:-super_admin}"

[[ -n "$EMAIL" ]]    || fail "Usage: $0 <email> <password> [full_name] [role]"
[[ -n "$PASSWORD" ]] || fail "Usage: $0 <email> <password> [full_name] [role]"

VALID_ROLES="super_admin org_admin approver editor viewer agency_collaborator read_only_executive compliance_reviewer analytics_only implementation_partner"
if ! echo "$VALID_ROLES" | grep -qw "$ROLE"; then
  fail "Invalid role '$ROLE'. Valid: $VALID_ROLES"
fi

[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE. Run setup-server.sh first."
# shellcheck disable=SC2046
export $(grep -v '^#' "$ENV_FILE" | grep -E '^DATABASE_URL=' | xargs)
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL not set in $ENV_FILE"

cd "$APP_DIR"

echo ""
echo -e "  ${BOLD}Creating / updating admin user${NC}"
echo "  Email:    $EMAIL"
echo "  Role:     $ROLE"
echo "  Name:     $FULL_NAME"
echo ""

# Use tsx to run a quick Prisma upsert
node - <<EOF
const { execSync } = require("child_process");
// Write a temp script and run it with tsx
const fs = require("fs");
const os = require("os");
const path = require("path");

const script = \`
import bcrypt from "bcryptjs";
import { ConsoleRole, PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

async function run() {
  const password_hash = await bcrypt.hash(${JSON.stringify(PASSWORD)}, 12);
  const user = await prisma.user.upsert({
    where: { email: ${JSON.stringify(EMAIL)} },
    create: {
      email: ${JSON.stringify(EMAIL)},
      full_name: ${JSON.stringify(FULL_NAME)},
      password_hash,
    },
    update: {
      full_name: ${JSON.stringify(FULL_NAME)},
      password_hash,
    },
  });

  await prisma.userRole.upsert({
    where: { user_id: user.id },
    create: { user_id: user.id, console_role: ${JSON.stringify(ROLE)} as ConsoleRole },
    update: { console_role: ${JSON.stringify(ROLE)} as ConsoleRole },
  });

  console.log("ok:" + user.id);
  await prisma.\$disconnect();
}

run().catch((e) => { console.error(e.message); process.exit(1); });
\`;

const tmpFile = path.join(os.tmpdir(), "create-admin-" + Date.now() + ".ts");
fs.writeFileSync(tmpFile, script);

try {
  const result = execSync(\`pnpm exec tsx "\${tmpFile}"\`, {
    cwd: ${JSON.stringify(APP_DIR)},
    env: { ...process.env, DATABASE_URL: process.env.DATABASE_URL },
    encoding: "utf8",
  });
  if (result.includes("ok:")) {
    const uid = result.match(/ok:(.+)/)?.[1]?.trim();
    console.log("  ✔  User upserted — id: " + uid);
  } else {
    console.log(result);
  }
} finally {
  fs.unlinkSync(tmpFile);
}
EOF

echo ""
ok "Done. User '${EMAIL}' has role '${ROLE}'."
echo ""
