#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Add User
#
#  Creates a full KOMMS user account in one command:
#    · SSO account in LLDAP (→ Nextcloud, Matrix, TAK WebUI login)
#    · OpenVPN client certificate + .ovpn profile
#    · TAKServer client certificate (.p12 for ATAK/WinTAK import)
#    · Info QR code (server details, credentials, service URLs)
#    · MDM QR code (link to Headwind MDM enrollment page)
#
#  Usage:
#    sudo bash /opt/komms/server/add_user.sh <username> [display_name]
#
#  Example:
#    sudo bash /opt/komms/server/add_user.sh soldier01 "Max Mustermann"
#
#  Output: /opt/komms-data/users/<username>/
#    ├── soldier01.ovpn           ← OpenVPN profile → uploaded to Nextcloud
#    ├── soldier01-tak.zip        ← ATAK/WinTAK data package → uploaded to Nextcloud
#    ├── soldier01-tak.p12        ← Raw TAK cert (fallback)
#    ├── qr-credentials.png       ← QR with login credentials for Nextcloud
#    └── credentials.txt          ← Plain-text summary (handle securely!)
#
#  Onboarding flow:
#    1. Show user qr-credentials.png
#    2. User logs into Nextcloud → downloads .ovpn from shared folder
#    3. User connects VPN → all other services become accessible
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
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash add_user.sh <username>"

MAKE_ADMIN=false
ARGS=()
for arg in "$@"; do
    [[ "$arg" == "--admin" ]] && MAKE_ADMIN=true || ARGS+=("$arg")
done
set -- "${ARGS[@]}"

[[ $# -lt 1 ]] && err "Usage: $0 [--admin] <username> [display_name]\n  Example: $0 soldier01 'Max Mustermann'\n  --admin  also adds user to lldap_admin group (for operator accounts)"

USERNAME="$1"
DISPLAY_NAME="${2:-$USERNAME}"

# Validate username (alphanumeric + hyphens only)
[[ "$USERNAME" =~ ^[a-z0-9][a-z0-9_-]{1,31}$ ]] || \
    err "Username must be lowercase alphanumeric (a-z0-9_-), 2-32 chars, start with a letter/digit."

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"
# shellcheck source=/dev/null
set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a

DATA_DIR="${DATA_DIR:-/opt/komms-data}"
DOMAIN="${DOMAIN:?DOMAIN not set in .env}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:?LDAP_ADMIN_PASS not set in .env}"
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=komms,dc=local}"
TAK_CERT_PASS="${TAK_CERT_PASS:-atakatak}"
HMDM_URL="${HMDM_URL:-https://mdm.${DOMAIN}}"
HMDM_ADMIN_LOGIN="${HMDM_ADMIN_LOGIN:-admin}"
HMDM_ADMIN_PASS="${HMDM_ADMIN_PASS:-}"
HMDM_CONFIG_ID="${HMDM_CONFIG_ID:-}"
NC_ADMIN="${NC_ADMIN:-admin}"
NC_PASS="${NC_PASS:?NC_PASS not set in .env}"
NC_URL="https://cloud.${DOMAIN}"
NC_DAV="${NC_URL}/remote.php/dav/files/${NC_ADMIN}"
NC_OCS="${NC_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares"
LLDAP_API="http://127.0.0.1:17170"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl jq qrencode openssl docker zip; do
    command -v "$cmd" &>/dev/null || err "Missing dependency: $cmd. Run: apt-get install -y $cmd"
done

# ── Output directory ──────────────────────────────────────────────────────────
USER_DIR="$DATA_DIR/users/$USERNAME"
mkdir -p "$USER_DIR"
chmod 700 "$USER_DIR"

echo ""
echo -e "${BOLD}${BLUE}  KOMMS – Adding user: ${USERNAME}${NC}"
echo -e "  Display name: ${DISPLAY_NAME}"
echo -e "  Output dir:   ${USER_DIR}"
echo ""

cd "$SCRIPT_DIR"

# ── [1] LLDAP – Create SSO account ───────────────────────────────────────────
step "[1/5] Creating SSO account in LLDAP"
info "This account is the single login used across Matrix, Nextcloud, and the TAK WebUI."

# Check LLDAP is reachable
curl -sf "$LLDAP_API/health" >/dev/null 2>&1 || \
    err "LLDAP not reachable at $LLDAP_API\nIs the stack running?  docker compose ps"

# Authenticate as LLDAP admin → get JWT
LLDAP_TOKEN=$(curl -sf -X POST "$LLDAP_API/auth/simple/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$LDAP_ADMIN_PASS\"}" \
    | jq -r '.token')
[[ -z "$LLDAP_TOKEN" || "$LLDAP_TOKEN" == "null" ]] && \
    err "LLDAP authentication failed. Check LDAP_ADMIN_PASS in .env."

USER_EMAIL="${USERNAME}@${DOMAIN}"

if [[ "$USERNAME" == "admin" ]]; then
    # 'admin' is the built-in LLDAP system account — do not recreate or reset its
    # password (services like Authelia/Synapse bind to LLDAP using LDAP_ADMIN_PASS).
    # Use the existing password from .env for the credentials file.
    USER_PASS="$LDAP_ADMIN_PASS"
    MAKE_ADMIN=true   # admin is always lldap_admin
    ok "Skipping LLDAP creation — 'admin' is the built-in system account"
else
    # Generate initial password
    USER_PASS=$(openssl rand -base64 18 | tr -d '=+/' | head -c 20)

    # Check if user already exists
    EXISTING=$(curl -sf -X POST "$LLDAP_API/api/graphql" \
        -H "Authorization: Bearer $LLDAP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"{ user(userId: \\\"$USERNAME\\\") { id } }\"}" \
        | jq -r '.data.user.id // empty')

    if [[ -n "$EXISTING" ]]; then
        warn "User '$USERNAME' already exists in LLDAP — resetting password for re-provisioning."
    else
        # Create user
        RESULT=$(curl -sf -X POST "$LLDAP_API/api/graphql" \
            -H "Authorization: Bearer $LLDAP_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$(jq -n \
                --arg id "$USERNAME" \
                --arg email "$USER_EMAIL" \
                --arg dn "$DISPLAY_NAME" \
                '{query: "mutation($u: CreateUserInput!) { createUser(user: $u) { id } }",
                  variables: { u: { id: $id, email: $email, displayName: $dn } }}')")

        echo "$RESULT" | jq -e '.data.createUser.id' >/dev/null 2>&1 || \
            err "Failed to create user in LLDAP:\n$RESULT"
    fi

    # Set / reset password via lldap_set_password (OPAQUE protocol)
    docker compose exec lldap /app/lldap_set_password \
        --base-url "http://127.0.0.1:17170" \
        --admin-password "$LDAP_ADMIN_PASS" \
        --username "$USERNAME" \
        --password "$USER_PASS" >/dev/null
fi

ok "LLDAP account ready: $USERNAME / $USER_EMAIL"

# ── [1b] Add to lldap_admin group (--admin flag) ─────────────────────────────
if [[ "$MAKE_ADMIN" == "true" ]]; then
    ADMIN_GROUP_ID=$(curl -sf -X POST "$LLDAP_API/api/graphql" \
        -H "Authorization: Bearer $LLDAP_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ groups { id displayName } }"}' \
        | jq -r '.data.groups[] | select(.displayName=="lldap_admin") | .id')

    if [[ -z "$ADMIN_GROUP_ID" || "$ADMIN_GROUP_ID" == "null" ]]; then
        warn "lldap_admin group not found — skipping group assignment."
    else
        _grp_result=$(curl -sf -X POST "$LLDAP_API/api/graphql" \
            -H "Authorization: Bearer $LLDAP_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg uid "$USERNAME" --argjson gid "$ADMIN_GROUP_ID" \
                '{query: "mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }",
                  variables: { u: $uid, g: $gid }}')" 2>/dev/null || true)
        if echo "$_grp_result" | jq -e '.data.addUserToGroup.ok' >/dev/null 2>&1; then
            ok "Added $USERNAME to lldap_admin group (admin access to MDM, LLDAP, TAK WebUI)"
        else
            # already a member returns ok:false — treat as success
            ok "$USERNAME is already in lldap_admin group"
        fi
    fi
fi

# ── [2] OpenVPN certificate ───────────────────────────────────────────────────
step "[2/5] Generating OpenVPN certificate"
info "Creates a unique client certificate and .ovpn profile — import in the OpenVPN app (Android/Windows)."
cd "$SCRIPT_DIR"

OVPN_OUT="$USER_DIR/${USERNAME}.ovpn"

# Check if client cert already exists in the OpenVPN volume
CERT_EXISTS=$(docker exec komms_openvpn \
    bash -c "[ -f /etc/openvpn/pki/issued/${USERNAME}.crt ] && echo yes || echo no" 2>/dev/null || echo no)

if [[ "$CERT_EXISTS" == "yes" ]]; then
    warn "OpenVPN cert for '$USERNAME' already exists — re-exporting profile."
else
    docker exec -e EASYRSA_BATCH=1 komms_openvpn \
        easyrsa build-client-full "$USERNAME" nopass
fi

docker exec komms_openvpn ovpn_getclient "$USERNAME" > "$OVPN_OUT"
# Split-tunnel: remove redirect-gateway so client keeps its own internet route
sed -i '/redirect-gateway def1/d' "$OVPN_OUT"
# Require username + password on connect (verified against LLDAP by the server)
grep -q "^auth-user-pass" "$OVPN_OUT" || echo "auth-user-pass" >> "$OVPN_OUT"
chmod 600 "$OVPN_OUT"
ok "OpenVPN profile: ${USERNAME}.ovpn (LDAP auth required)"

# ── [3] TAKServer client certificate + data package ──────────────────────────
step "[3/5] Generating TAKServer certificate & data package"
info "Creates a .zip data package — import in ATAK or WinTAK to auto-connect to TAKServer."

TAK_IMAGE_VAL="${TAK_IMAGE:-}"
TAK_P12_OUT="$USER_DIR/${USERNAME}-tak.p12"
TAK_ZIP_OUT="$USER_DIR/${USERNAME}-tak.zip"
TAK_CERT_DONE=false
TAK_ZIP_DONE=false

if [[ -z "$TAK_IMAGE_VAL" ]] || ! docker image inspect "$TAK_IMAGE_VAL" &>/dev/null 2>&1; then
    warn "TAKServer image not loaded — skipping TAK certificate."
    warn "Run setup_tak.sh first, then re-run add_user.sh to generate the TAK cert."
else
    # Generate client cert inside the TAKServer container
    docker compose exec takserver bash -c "
        set -e
        cd /opt/tak/certs
        if [ -f files/${USERNAME}.p12 ]; then
            echo 'cert-exists'
        else
            rm -f files/${USERNAME}.jks
            ./makeCert.sh client ${USERNAME}
            echo 'cert-created'
        fi
    " | tail -1 | grep -q "cert-" && true

    # Copy the client .p12 out of the container
    docker cp "komms_tak:/opt/tak/certs/files/${USERNAME}.p12" "$TAK_P12_OUT" 2>/dev/null || \
        docker compose cp "takserver:/opt/tak/certs/files/${USERNAME}.p12" "$TAK_P12_OUT"
    chmod 600 "$TAK_P12_OUT"
    ok "TAK certificate: ${USERNAME}-tak.p12 (passphrase: ${TAK_CERT_PASS})"
    TAK_CERT_DONE=true

    # ── Build ATAK/WinTAK data package (auto-connect ZIP) ────────────────────
    # Find the truststore P12 in the container
    TAK_TRUSTSTORE_NAME=""
    for _ts in truststore-root.p12 truststore-intermediate.p12 truststore-int_ca_tak.p12; do
        if docker exec komms_tak test -f "/opt/tak/certs/files/$_ts" 2>/dev/null; then
            TAK_TRUSTSTORE_NAME="$_ts"
            break
        fi
    done

    if [[ -n "$TAK_TRUSTSTORE_NAME" ]]; then
        TAK_PKG_NAME="${USERNAME}-tak"
        TAK_PKG_TMP=$(mktemp -d)
        mkdir -p "$TAK_PKG_TMP/$TAK_PKG_NAME/MANIFEST"

        # Certs into package structure
        cp "$TAK_P12_OUT" "$TAK_PKG_TMP/$TAK_PKG_NAME/${USERNAME}.p12"
        docker cp "komms_tak:/opt/tak/certs/files/$TAK_TRUSTSTORE_NAME" \
            "$TAK_PKG_TMP/$TAK_PKG_NAME/truststore-tak.p12"

        # Unique package ID
        PKG_UID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || \
                  openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')

        # Connection preferences — callsign = display name, server = public hostname
        cat > "$TAK_PKG_TMP/$TAK_PKG_NAME/secure.pref" << PREF
<?xml version='1.0' standalone='yes'?>
<preferences>
<preference version="1" name="cot_streams">
<entry key="count" class="class java.lang.Integer">1</entry>
<entry key="description0" class="class java.lang.String">KOMMS TAKServer</entry>
<entry key="enabled0" class="class java.lang.Boolean">true</entry>
<entry key="connectString0" class="class java.lang.String">tak.${DOMAIN}:8089:ssl</entry>
</preference>
<preference version="1" name="com.atakmap.app_preferences">
<entry key="clientPassword" class="class java.lang.String">${TAK_CERT_PASS}</entry>
<entry key="caPassword" class="class java.lang.String">${TAK_CERT_PASS}</entry>
<entry key="caLocation" class="class java.lang.String">cert/truststore-tak.p12</entry>
<entry key="certificateLocation" class="class java.lang.String">cert/${USERNAME}.p12</entry>
<entry key="displayServerConnectionWidget" class="class java.lang.Boolean">true</entry>
<entry key="locationCallsign" class="class java.lang.String">${DISPLAY_NAME}</entry>
</preference>
</preferences>
PREF

        # Package manifest
        cat > "$TAK_PKG_TMP/$TAK_PKG_NAME/MANIFEST/manifest.xml" << MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="name" value="KOMMS-${USERNAME}" />
    <Parameter name="uid" value="${PKG_UID}" />
    <Parameter name="onReceiveDelete" value="false"/>
  </Configuration>
  <Contents>
    <Content zipEntry="${USERNAME}.p12" ignore="false" />
    <Content zipEntry="secure.pref" ignore="false" />
    <Content zipEntry="truststore-tak.p12" ignore="false" />
  </Contents>
</MissionPackageManifest>
MANIFEST

        (cd "$TAK_PKG_TMP" && zip -r "$TAK_ZIP_OUT" "$TAK_PKG_NAME/" 2>/dev/null)
        rm -rf "$TAK_PKG_TMP"
        chmod 600 "$TAK_ZIP_OUT"
        ok "TAK data package: ${USERNAME}-tak.zip (import in ATAK/WinTAK — auto-connects)"
        TAK_ZIP_DONE=true
    else
        warn "TAK truststore not found — only raw .p12 generated. Run setup_tak.sh to complete TAK setup."
    fi
fi

# ── Credentials file (created early so it can be uploaded to Nextcloud) ──────
cat > "$USER_DIR/credentials.txt" << CREDS
KOMMS User Package – ${USERNAME}
Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
════════════════════════════════════════════

Login (Nextcloud + Authelia SSO)
  Username: ${USERNAME}
  Password: ${USER_PASS}
  URL:      ${NC_URL}

Onboarding Flow
  1. Open ${NC_URL} in browser
  2. Login with above credentials
  3. Find shared folder: KOMMS-Users/${USERNAME}/
  4. Download ${USERNAME}.ovpn → import in OpenVPN app
  5. Connect VPN → access all other services

Service URLs (VPN required)
  Matrix:    @${USERNAME}:${MATRIX_DOMAIN:-$DOMAIN}
  Element:   https://element.${DOMAIN}
  Mumble:    mumble.${DOMAIN}:64738
  TAKServer: tak.${DOMAIN}:8089 (TLS)
  MDM:       https://mdm.${DOMAIN}

Files in Nextcloud (KOMMS-Users/${USERNAME}/)
  ${USERNAME}.ovpn        → OpenVPN profile
$( [[ "$TAK_ZIP_DONE"  == "true" ]] && echo "  ${USERNAME}-tak.zip     → ATAK/WinTAK data package (passphrase: ${TAK_CERT_PASS})" )
$( [[ "$TAK_CERT_DONE" == "false" ]] && echo "  [TAK cert pending – run add_user.sh after TAKServer setup]" )

SECURITY: Delete this file after distribution.
CREDS
chmod 600 "$USER_DIR/credentials.txt"

# ── [4] Upload files to Nextcloud ────────────────────────────────────────────
step "[4/6] Uploading files to Nextcloud"
info "Files will be shared with the user — accessible after first login to ${NC_URL}"

NC_UPLOAD_DONE=false
_NC_FOLDER="KOMMS-Users/${USERNAME}"
# Use localhost inside the container — avoids hairpin NAT, SSL, and trusted_domain checks
_NC_DAV_INT="http://localhost/remote.php/dav/files/${NC_ADMIN}"
_NC_OCS_INT="http://localhost/ocs/v2.php/apps/files_sharing/api/v1/shares"

_nc_curl() {
    # Run curl inside the nextcloud container (avoids hairpin NAT + SSL)
    docker exec komms_nextcloud curl -s --max-time 30 "$@" 2>/dev/null
}

_nc_upload() {
    # $1 = local file, $2 = remote filename
    local tmp="/tmp/nc_up_$(basename "$1")"
    docker cp "$1" "komms_nextcloud:${tmp}" || return 1
    local http
    http=$(docker exec komms_nextcloud curl -s --max-time 30 \
        -u "${NC_ADMIN}:${NC_PASS}" \
        -T "$tmp" "http://localhost/remote.php/dav/files/${NC_ADMIN}/${_NC_FOLDER}/$2" \
        -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")
    docker exec komms_nextcloud rm -f "$tmp" 2>/dev/null || true
    [[ "$http" == "201" || "$http" == "204" ]]
}

if docker exec komms_nextcloud curl -sf --max-time 5 http://localhost/status.php 2>/dev/null \
        | grep -q '"installed":true'; then
    # Pre-provision the LDAP user in Nextcloud so the share works without requiring a prior login.
    # user_oidc (unique-uid=0) maps preferred_username → same UID as user_ldap (uid attr),
    # so OIDC login will reuse this account automatically.
    docker compose exec -T --user www-data nextcloud php occ ldap:check-user "$USERNAME" \
        >/dev/null 2>&1 || true

    # Create folder structure (ignore if already exists)
    _nc_curl -u "${NC_ADMIN}:${NC_PASS}" -X MKCOL \
        "${_NC_DAV_INT}/KOMMS-Users" -o /dev/null || true
    _nc_curl -u "${NC_ADMIN}:${NC_PASS}" -X MKCOL \
        "${_NC_DAV_INT}/${_NC_FOLDER}" -o /dev/null || true

    _upload_ok=true
    _nc_upload "$OVPN_OUT"              "${USERNAME}.ovpn"      || { warn "Upload failed: ${USERNAME}.ovpn";      _upload_ok=false; }
    _nc_upload "$USER_DIR/credentials.txt" "credentials.txt"   || { warn "Upload failed: credentials.txt";       _upload_ok=false; }
    [[ "$TAK_ZIP_DONE"  == "true" ]] && \
        { _nc_upload "$TAK_ZIP_OUT" "${USERNAME}-tak.zip" || { warn "Upload failed: ${USERNAME}-tak.zip"; _upload_ok=false; }; }
    [[ "$TAK_CERT_DONE" == "true" ]] && \
        { _nc_upload "$TAK_P12_OUT" "${USERNAME}-tak.p12" || { warn "Upload failed: ${USERNAME}-tak.p12"; _upload_ok=false; }; }

    if [[ "$_upload_ok" == "true" ]]; then
        if [[ "$USERNAME" == "$NC_ADMIN" ]]; then
            # Admin owns the folder directly — no share needed
            ok "Files uploaded to Nextcloud (${NC_URL} → KOMMS-Users/${USERNAME}/)"
        else
            # Share folder with the LDAP-provisioned user (read-only)
            _share_resp=$(docker exec komms_nextcloud curl -s --max-time 30 \
                -u "${NC_ADMIN}:${NC_PASS}" \
                -H "OCS-APIRequest: true" -X POST \
                "http://localhost/ocs/v2.php/apps/files_sharing/api/v1/shares" \
                -d "path=/KOMMS-Users/${USERNAME}&shareType=0&shareWith=${USERNAME}&permissions=1" \
                2>/dev/null || true)
            if echo "$_share_resp" | grep -q '<status>ok</status>'; then
                ok "Files uploaded and shared with ${USERNAME} in Nextcloud"
            else
                warn "Files uploaded but share with '${USERNAME}' failed (LDAP sync may have missed user)."
                warn "Fix: after ${USERNAME} logs into ${NC_URL} once, re-run:"
                warn "  sudo bash $0 ${USERNAME} '${DISPLAY_NAME}'"
            fi
        fi
        NC_UPLOAD_DONE=true
    fi
else
    warn "Nextcloud not reachable — files remain in ${USER_DIR}/ only"
fi

# ── [5] Credentials QR code ───────────────────────────────────────────────────
step "[5/6] Generating credentials QR code"
info "User scans this QR to get login credentials, then downloads their files from Nextcloud."

MATRIX_HANDLE="@${USERNAME}:${MATRIX_DOMAIN:-$DOMAIN}"

QR_TEXT="KOMMS LOGIN
━━━━━━━━━━━━━━━━━━━
User:  ${USERNAME}
Pass:  ${USER_PASS}
━━━━━━━━━━━━━━━━━━━
${NC_URL}
━━━━━━━━━━━━━━━━━━━
1. Login to Nextcloud
2. Download .ovpn
3. Connect VPN"

qrencode -o "$USER_DIR/qr-credentials.png" -s 8 -m 2 -l M "$QR_TEXT"
ok "Credentials QR: qr-credentials.png"

# ── [6] Credentials summary ───────────────────────────────────────────────────
step "[6/6] Saving credentials"
ok "credentials.txt saved (also uploaded to Nextcloud: KOMMS-Users/${USERNAME}/)"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ✔  User '${USERNAME}' created successfully!${NC}"
echo ""
echo -e "  ${YELLOW}Output files:${NC}  ${CYAN}${USER_DIR}/${NC}"
ls -1 "$USER_DIR" | while read -r f; do echo -e "    $f"; done
echo ""
echo -e "  ${YELLOW}Hand off to user:${NC}"
echo -e "  1. Show ${CYAN}qr-credentials.png${NC} — user scans for login credentials"
echo -e "  2. User logs into ${CYAN}${NC_URL}${NC} and downloads their files"
echo -e "  3. User imports ${CYAN}${USERNAME}.ovpn${NC} → connects VPN → accesses all services"
[[ "$TAK_ZIP_DONE" == "true" ]] && \
    echo -e "  4. User imports ${CYAN}${USERNAME}-tak.zip${NC} in ATAK/WinTAK (passphrase: ${TAK_CERT_PASS})"
echo -e "  5. ${RED}Delete credentials.txt after distribution!${NC}"
echo ""
