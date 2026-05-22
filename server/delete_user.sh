#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Delete User
#
#  Removes a user from all KOMMS systems:
#    · LLDAP (SSO account)
#    · OpenVPN (revokes certificate)
#    · TAKServer (removes client certificate)
#    · Nextcloud (account + uploaded files)
#    · Local user directory (/opt/komms/users/<username>/)
#
#  Usage:
#    sudo bash /opt/komms/server/delete_user.sh <username>
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOMMS_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}▶  $*${NC}"; }

# ── Args + root ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash delete_user.sh <username>"
[[ $# -lt 1 ]]    && err "Usage: $0 <username>"

USERNAME="$1"

[[ "$USERNAME" == "admin" ]] && \
    err "'admin' is the LLDAP system account and cannot be deleted."

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"
set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a

DATA_DIR="${DATA_DIR:-/opt/komms-data}"
DOMAIN="${DOMAIN:?DOMAIN not set in .env}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:?LDAP_ADMIN_PASS not set in .env}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=komms,dc=local}"
NC_ADMIN="${NC_ADMIN:-admin}"
NC_PASS="${NC_PASS:?NC_PASS not set in .env}"
LLDAP_API="http://127.0.0.1:17170"

USER_DIR="$DATA_DIR/users/$USERNAME"

echo ""
echo -e "${BOLD}${RED}  KOMMS – Deleting user: ${USERNAME}${NC}"
echo ""
echo -e "  ${YELLOW}This will permanently remove:${NC}"
echo -e "    · LLDAP account (SSO for all services)"
echo -e "    · OpenVPN certificate (VPN access revoked)"
echo -e "    · TAKServer certificate"
echo -e "    · Nextcloud account + all uploaded files"
[[ -d "$USER_DIR" ]] && echo -e "    · Local files: ${USER_DIR}/"
echo ""

# Confirmation prompt
read -r -p "  Type the username to confirm deletion: " CONFIRM
[[ "$CONFIRM" == "$USERNAME" ]] || err "Confirmation did not match — aborting."
echo ""

cd "$SCRIPT_DIR"

# ── [1] LLDAP – Delete SSO account ───────────────────────────────────────────
step "[1/4] Removing LLDAP account"

if curl -sf "$LLDAP_API/health" >/dev/null 2>&1; then
    LLDAP_TOKEN=$(curl -sf -X POST "$LLDAP_API/auth/simple/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"$LDAP_ADMIN_PASS\"}" \
        | jq -r '.token')

    if [[ -n "$LLDAP_TOKEN" && "$LLDAP_TOKEN" != "null" ]]; then
        EXISTING=$(curl -sf -X POST "$LLDAP_API/api/graphql" \
            -H "Authorization: Bearer $LLDAP_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"query\":\"{ user(userId: \\\"$USERNAME\\\") { id } }\"}" \
            | jq -r '.data.user.id // empty')

        if [[ -n "$EXISTING" ]]; then
            RESULT=$(curl -sf -X POST "$LLDAP_API/api/graphql" \
                -H "Authorization: Bearer $LLDAP_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --arg id "$USERNAME" \
                    '{query: "mutation($id: String!) { deleteUser(userId: $id) { ok } }",
                      variables: { id: $id }}')")
            if echo "$RESULT" | jq -e '.data.deleteUser.ok' >/dev/null 2>&1; then
                ok "LLDAP account deleted: $USERNAME"
            else
                warn "LLDAP delete returned unexpected response: $RESULT"
            fi
        else
            warn "User '$USERNAME' not found in LLDAP — skipping."
        fi
    else
        warn "LLDAP authentication failed — skipping LLDAP deletion."
    fi
else
    warn "LLDAP not reachable — skipping LLDAP deletion."
fi

# ── [2] Nextcloud – Delete account + files ───────────────────────────────────
# Runs AFTER LLDAP deletion. For LDAP-backed users occ user:delete fails directly,
# so we first run ldap:check-user which detects the user is gone and marks them
# deleted in Nextcloud — then user:delete succeeds.
step "[2/4] Removing Nextcloud account and files"

if docker exec komms_nextcloud curl -sf --max-time 5 http://localhost/status.php 2>/dev/null \
        | grep -q '"installed":true'; then

    # Remove the admin-owned upload folder first (works regardless of user state)
    _folder_http=$(docker exec komms_nextcloud curl -s --max-time 10 \
        -u "${NC_ADMIN}:${NC_PASS}" \
        -X DELETE "http://localhost/remote.php/dav/files/${NC_ADMIN}/KOMMS-Users/${USERNAME}" \
        -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")
    if [[ "$_folder_http" == "204" || "$_folder_http" == "200" ]]; then
        ok "Nextcloud upload folder removed: KOMMS-Users/${USERNAME}/"
    else
        warn "Could not remove Nextcloud folder KOMMS-Users/${USERNAME}/ (HTTP $_folder_http) — delete manually."
    fi

    # For LDAP-backed users: trigger a check so Nextcloud marks the user as deleted
    # (user no longer exists in LLDAP). Then user:delete can clean up the DB record.
    docker compose exec -T --user www-data nextcloud \
        php occ ldap:check-user "$USERNAME" 2>/dev/null || true
    if docker compose exec -T --user www-data nextcloud \
            php occ user:delete "$USERNAME" 2>/dev/null; then
        ok "Nextcloud account deleted: $USERNAME"
    else
        warn "Nextcloud account for '$USERNAME' not found or already removed — skipping."
    fi
else
    warn "Nextcloud not reachable — skipping Nextcloud deletion."
fi

# ── [3] OpenVPN – Revoke certificate ─────────────────────────────────────────
step "[3/4] Revoking OpenVPN certificate"

CERT_EXISTS=$(docker exec komms_openvpn \
    bash -c "[ -f /etc/openvpn/pki/issued/${USERNAME}.crt ] && echo yes || echo no" 2>/dev/null || echo no)

if [[ "$CERT_EXISTS" == "yes" ]]; then
    docker exec -e EASYRSA_BATCH=1 komms_openvpn \
        easyrsa revoke "$USERNAME" 2>/dev/null || true
    docker exec -e EASYRSA_BATCH=1 komms_openvpn \
        easyrsa gen-crl 2>/dev/null || true
    # Remove PKI files so add_user.sh creates a fresh cert instead of re-exporting the revoked one
    docker exec komms_openvpn rm -f \
        "/etc/openvpn/pki/issued/${USERNAME}.crt" \
        "/etc/openvpn/pki/private/${USERNAME}.key" \
        "/etc/openvpn/pki/reqs/${USERNAME}.req" \
        2>/dev/null || true
    ok "OpenVPN certificate revoked and PKI files removed: $USERNAME"
else
    warn "No OpenVPN certificate found for '$USERNAME' — skipping."
fi

# ── [4] TAKServer – Remove client certificate ─────────────────────────────────
step "[4/4] Removing TAKServer certificate"

TAK_IMAGE_VAL="${TAK_IMAGE:-}"
if [[ -n "$TAK_IMAGE_VAL" ]] && docker container inspect komms_tak &>/dev/null 2>&1; then
    if docker exec komms_tak test -f "/opt/tak/certs/files/${USERNAME}.p12" 2>/dev/null; then
        docker exec komms_tak rm -f \
            "/opt/tak/certs/files/${USERNAME}.p12" \
            "/opt/tak/certs/files/${USERNAME}.crt" \
            "/opt/tak/certs/files/${USERNAME}.key" \
            "/opt/tak/certs/files/${USERNAME}.jks" \
            "/opt/tak/certs/files/${USERNAME}-trusted.pem" \
            2>/dev/null || true
        ok "TAKServer certificate removed: $USERNAME"
    else
        warn "No TAKServer certificate found for '$USERNAME' — skipping."
    fi
else
    warn "TAKServer not running — skipping TAK certificate removal."
fi

# ── Local files ───────────────────────────────────────────────────────────────
if [[ -d "$USER_DIR" ]]; then
    rm -rf "$USER_DIR"
    ok "Local files removed: $USER_DIR/"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ✔  User '${USERNAME}' removed from all KOMMS systems.${NC}"
echo ""
echo -e "  ${YELLOW}Note:${NC} If the user has active sessions, they will expire naturally."
echo -e "  To force immediate logout, restart Authelia:"
echo -e "    ${CYAN}cd $SCRIPT_DIR && docker compose restart authelia${NC}"
echo ""
