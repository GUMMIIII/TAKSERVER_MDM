#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Nextcloud LDAP Setup
#
#  Configures Nextcloud to authenticate against LLDAP.
#  Idempotent: safe to run multiple times.
#
#  Usage:
#    bash /opt/komms/server/setup_nextcloud_ldap.sh
#
#  Called automatically by setup_server.sh after the stack is up.
#  Can also be run standalone if LDAP config needs to be re-applied.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }

[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"
# shellcheck source=/dev/null
set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a

LDAP_BASE="${LDAP_BASE_DN:-dc=komms,dc=local}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:?LDAP_ADMIN_PASS not set in .env}"

cd "$SCRIPT_DIR"

occ() { docker compose exec -T --user www-data nextcloud php occ "$@"; }

echo -e "\n${BOLD}${BLUE}▶  Nextcloud LDAP Setup${NC}"

# ── Wait for Nextcloud ────────────────────────────────────────────────────────
info "Waiting for Nextcloud to be ready (up to 5 min on first start)..."
TRIES=0
until occ status --output=json 2>/dev/null | grep -q '"installed":true'; do
    TRIES=$((TRIES + 1))
    [[ $TRIES -ge 60 ]] && err "Nextcloud not ready after 5 min. Run this script again once Nextcloud is up."
    printf "."
    sleep 5
done
[[ $TRIES -gt 0 ]] && echo ""

# ── Check if already configured ───────────────────────────────────────────────
if occ ldap:show-config 2>/dev/null | grep -q "lldap"; then
    ok "Nextcloud LDAP already configured — skipping."
    exit 0
fi

# ── Enable app + create config ────────────────────────────────────────────────
occ app:enable user_ldap --no-interaction 2>&1 | grep -v "already enabled" || true
ok "user_ldap app enabled"

CREATE_OUT=$(occ ldap:create-empty-config 2>&1) || err "ldap:create-empty-config failed: $CREATE_OUT"
CFG=$(echo "$CREATE_OUT" | grep -oP 'configID \K\S+' || true)
[[ -z "$CFG" ]] && err "Could not parse config ID from occ output:\n$CREATE_OUT"
info "LDAP config created: $CFG"

# ── Apply settings ────────────────────────────────────────────────────────────
s() { occ ldap:set-config "$CFG" "$1" "$2"; }

s ldapHost                  "lldap"
s ldapPort                  "3890"
s ldapAgentName             "uid=admin,ou=people,${LDAP_BASE}"
s ldapAgentPassword         "${LDAP_ADMIN_PASS}"
s ldapBase                  "${LDAP_BASE}"
s ldapBaseUsers             "ou=people,${LDAP_BASE}"
s ldapBaseGroups            "ou=groups,${LDAP_BASE}"
s ldapUserFilter            "(objectClass=person)"
s ldapLoginFilter           "(&(objectClass=person)(uid=%uid))"
s ldapUserDisplayName       "cn"
s ldapEmailAttribute        "mail"
s ldapGroupFilter           "(objectClass=groupOfUniqueNames)"
s ldapGroupMemberAssocAttr  "uniqueMember"
s ldapGroupDisplayName      "cn"
s ldapExpertUsernameAttr    "uid"
s turnOnPasswordChange      "0"
s ldapConfigurationActive   "1"

ok "Nextcloud LDAP configured (config: $CFG)"

# ── Connection test ───────────────────────────────────────────────────────────
info "Testing LDAP connection..."
TEST_OUT=$(occ ldap:test-config "$CFG" 2>&1 || true)
if echo "$TEST_OUT" | grep -qi "The configuration is valid\|successfully"; then
    ok "LDAP connection test passed"
else
    warn "LDAP test result: $TEST_OUT"
    warn "If the stack just started, wait 30 s and re-test:"
    warn "  docker compose exec nextcloud php occ ldap:test-config $CFG"
fi
