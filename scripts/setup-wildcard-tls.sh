#!/usr/bin/env bash
# =============================================================================
# setup-wildcard-tls.sh — one certificate for every tenant on this host
#
# A shared host serves several tenants, each on its own subdomain. Issuing a
# certificate per tenant means running certbot and editing nginx on a live
# customer machine every time somebody is onboarded. One wildcard removes that
# entirely: after this runs, a new tenant needs DNS and a database row, and
# nothing on this machine changes ever again.
#
#   BASE_DOMAIN=incenva.com CLOUDFLARE_TOKEN=... bash scripts/setup-wildcard-tls.sh
#   BASE_DOMAIN=incenva.com DO_TOKEN=dop_v1_...   bash scripts/setup-wildcard-tls.sh
#
# Use the provider that hosts the DNS ZONE, which is not necessarily the one
# hosting the server. The plugin has to create an _acme-challenge record, so it
# needs authority over the domain — pointing it at the wrong provider fails with
# "Unable to determine base domain", which reads like a syntax problem and is
# really "that zone is not in this account".
#
# Safe to re-run. It reissues nothing that already covers the wildcard, and it
# will not reload nginx unless `nginx -t` passes — a bad config plus a reload
# takes a customer's site down, which is the one outcome worth being paranoid
# about here.
#
# ── Why DNS-01 and not the usual HTTP challenge ──────────────────────────────
#
# Let's Encrypt will not issue a wildcard over HTTP-01, at all. Proving control
# of one URL says nothing about *.example.com, so a DNS record is the only
# accepted proof. That is why this exists beside setup-ssl.sh rather than
# replacing it: setup-ssl.sh is right for a single-domain host, and cannot
# issue a wildcard no matter how it is invoked.
#
# ── What this deliberately does not cover ────────────────────────────────────
#
# The apex (incenva.com) — a wildcard covers one label, so `*.incenva.com`
# matches dev.incenva.com and not incenva.com itself. Pass INCLUDE_APEX=1 if
# this host serves it.
#
# Customer-owned domains (rebates.theirbrand.com). Those fall outside any
# wildcard and need their own certificate. See setup-ssl.sh, or move this host
# to on-demand TLS if custom domains become common.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}[tls]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✖${NC} $*" >&2; exit 1; }

BASE_DOMAIN="${BASE_DOMAIN:-}"
DO_TOKEN="${DO_TOKEN:-}"
CLOUDFLARE_TOKEN="${CLOUDFLARE_TOKEN:-}"
INCLUDE_APEX="${INCLUDE_APEX:-0}"
EMAIL="${LETSENCRYPT_EMAIL:-admin@${BASE_DOMAIN}}"
# Which DNS provider holds the zone. Decided by which token was supplied.
if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
  DNS_PROVIDER="cloudflare"
elif [[ -n "$DO_TOKEN" ]]; then
  DNS_PROVIDER="digitalocean"
else
  DNS_PROVIDER="${DNS_PROVIDER:-}"
fi
CREDS="/root/.secrets/${DNS_PROVIDER:-dns}.ini"
PROPAGATION="${DNS_PROPAGATION_SECONDS:-60}"

[[ $EUID -eq 0 ]] || fail "run as root — certbot writes to /etc/letsencrypt and nginx"
[[ -n "$BASE_DOMAIN" ]] || fail "BASE_DOMAIN is required, e.g. BASE_DOMAIN=incenva.com"

# ── 1. certbot and the DNS plugin for whichever provider holds the zone ──────
log "1/5  Installing certbot and the DNS plugin"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
[[ -n "$DNS_PROVIDER" ]] || fail "supply CLOUDFLARE_TOKEN or DO_TOKEN — whichever hosts the ${BASE_DOMAIN} zone"
apt-get install -y -qq certbot "python3-certbot-dns-${DNS_PROVIDER}" nginx >/dev/null
ok "certbot $(certbot --version 2>&1 | awk '{print $2}') with the ${DNS_PROVIDER} plugin"

# ── 2. Credentials ───────────────────────────────────────────────────────────
log "2/5  ${DNS_PROVIDER} API credentials"
if [[ -n "$CLOUDFLARE_TOKEN" || -n "$DO_TOKEN" ]]; then
  mkdir -p "$(dirname "$CREDS")"
  # Written with restrictive permissions BEFORE the token goes in, so it is
  # never briefly world-readable. certbot also refuses a loose file outright.
  install -m 600 /dev/null "$CREDS"
  if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
    printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_TOKEN" > "$CREDS"
  else
    printf 'dns_digitalocean_token = %s\n' "$DO_TOKEN" > "$CREDS"
  fi
  ok "wrote $CREDS (0600)"
elif [[ -f "$CREDS" ]]; then
  chmod 600 "$CREDS"
  ok "using the existing $CREDS"
else
  fail "no token given and no $CREDS on disk — the DNS challenge needs one"
fi

# ── 3. The certificate ───────────────────────────────────────────────────────
log "3/5  Certificate for *.${BASE_DOMAIN}"
CERT_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"

# Re-running should be free. Only reissue when the wildcard is genuinely absent
# — Let's Encrypt rate-limits duplicate certificates, and burning that limit on
# a re-run would block the real reissue you need later.
if [[ -f "${CERT_DIR}/fullchain.pem" ]] \
   && openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -text 2>/dev/null \
      | grep -q "DNS:\*\.${BASE_DOMAIN}"; then
  ok "a wildcard certificate is already installed — not reissuing"
else
  DOMAIN_ARGS=(-d "*.${BASE_DOMAIN}")
  [[ "$INCLUDE_APEX" == "1" ]] && DOMAIN_ARGS+=(-d "${BASE_DOMAIN}")

  # certonly, not --nginx: the nginx installer cannot wire up a wildcard, and
  # we edit the server block ourselves in step 4 where it can be checked.
  certbot certonly \
    "--dns-${DNS_PROVIDER}" \
    "--dns-${DNS_PROVIDER}-credentials" "$CREDS" \
    "--dns-${DNS_PROVIDER}-propagation-seconds" "$PROPAGATION" \
    --non-interactive --agree-tos -m "$EMAIL" \
    --cert-name "$BASE_DOMAIN" \
    "${DOMAIN_ARGS[@]}"
  ok "issued *.${BASE_DOMAIN}${INCLUDE_APEX:+ and the apex}"
fi

# ── 4. Point nginx at it ─────────────────────────────────────────────────────
log "4/5  Updating nginx"
SITE="$(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '^default$' | head -1 || true)"
[[ -n "$SITE" ]] || fail "no enabled nginx site found — run setup-nginx.sh first"
SITE_PATH="/etc/nginx/sites-available/${SITE}"
[[ -f "$SITE_PATH" ]] || SITE_PATH="/etc/nginx/sites-enabled/${SITE}"

BACKUP="${SITE_PATH}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SITE_PATH" "$BACKUP"
ok "backed up to $BACKUP"

# server_name becomes the wildcard so any tenant subdomain is accepted, and the
# certificate paths move to the shared cert. Both are rewritten rather than
# appended: a duplicate ssl_certificate silently wins by last-one-set.
sed -i -E \
  -e "s|^(\s*)server_name\s+[^;]+;|\1server_name *.${BASE_DOMAIN};|" \
  -e "s|^(\s*)ssl_certificate\s+[^;]+;|\1ssl_certificate ${CERT_DIR}/fullchain.pem;|" \
  -e "s|^(\s*)ssl_certificate_key\s+[^;]+;|\1ssl_certificate_key ${CERT_DIR}/privkey.pem;|" \
  "$SITE_PATH"
ok "server_name → *.${BASE_DOMAIN}"

# ── 5. Verify, then reload ───────────────────────────────────────────────────
log "5/5  Testing the configuration"
if ! nginx -t; then
  cp "$BACKUP" "$SITE_PATH"
  fail "nginx rejected the config — restored $BACKUP, nothing was reloaded"
fi
systemctl reload nginx
ok "nginx reloaded"

echo
ok "Done. Every *.${BASE_DOMAIN} subdomain on this host is now served over TLS."
echo "   Adding a tenant needs a DNS record and a client row — nothing on this machine."
echo "   Renewal is automatic; check it with:  certbot renew --dry-run"
