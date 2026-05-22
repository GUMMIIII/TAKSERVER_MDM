#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Local Config Generator (for Docker Desktop testing)
#
#  Substitutes .env variables into homeserver.yaml and CoreConfig.xml
#  so docker compose up -d works without running the full install.sh.
#
#  Usage:
#    cd server/
#    cp .env.example .env   # fill in all CHANGE_ME values
#    bash generate-configs.sh
#    docker compose up -d
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' NC='\033[0m'
ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || err ".env not found.\n  cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env\n  Fill in all CHANGE_ME values, then re-run."

# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

# Basic sanity check
for VAR in DOMAIN DB_USER DB_PASS MATRIX_DOMAIN MATRIX_MACAROON_SECRET MATRIX_FORM_SECRET MATRIX_REGISTRATION_SHARED_SECRET LDAP_BASE_DN LDAP_ADMIN_PASS; do
    VAL="${!VAR:-}"
    [[ -z "$VAL" || "$VAL" == CHANGE_ME* ]] && err "$VAR is not set or still contains a placeholder in .env"
done

echo ""
echo "  KOMMS – Generating local config files from .env"
echo ""

# ── homeserver.yaml ───────────────────────────────────────────────────────────
MATRIX_TPL="$SCRIPT_DIR/matrix/homeserver.yaml"
[[ -f "$MATRIX_TPL" ]] || err "homeserver.yaml not found at $MATRIX_TPL"

if grep -q '\${' "$MATRIX_TPL"; then
    TMP=$(mktemp)
    envsubst '${DB_USER} ${DB_PASS} ${MATRIX_DOMAIN} ${MATRIX_MACAROON_SECRET} ${MATRIX_FORM_SECRET} ${MATRIX_REGISTRATION_SHARED_SECRET} ${LDAP_BASE_DN} ${LDAP_ADMIN_PASS}' \
        < "$MATRIX_TPL" > "$TMP"
    mv "$TMP" "$MATRIX_TPL"
    ok "matrix/homeserver.yaml generated"
else
    ok "matrix/homeserver.yaml already processed"
fi

# ── CoreConfig.xml ────────────────────────────────────────────────────────────
CORE_CFG="$SCRIPT_DIR/takserver/CoreConfig.xml"
if [[ -f "$CORE_CFG" ]]; then
    if grep -q 'KOMMS_TAK_DB_USER' "$CORE_CFG"; then
        TMP=$(mktemp)
        sed \
            -e "s|KOMMS_TAK_DB_USER|${DB_USER}|g" \
            -e "s|KOMMS_TAK_DB_PASS|${DB_PASS}|g" \
            -e "s|KOMMS_CERT_PASS|${TAK_CERT_PASS:-atakatak}|g" \
            -e "s|KOMMS_SERVER_HOST|${DOMAIN}|g" \
            "$CORE_CFG" > "$TMP"
        mv "$TMP" "$CORE_CFG"
        ok "takserver/CoreConfig.xml generated"
    else
        ok "takserver/CoreConfig.xml already processed"
    fi
else
    warn "takserver/CoreConfig.xml not found — TAKServer will not start"
    info "This is normal if you have not placed the TAKServer zip yet."
fi

# ── nginx/certs ───────────────────────────────────────────────────────────────
CERT_DIR="$SCRIPT_DIR/nginx/certs"
mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_DIR/komms.crt" ]]; then
    info "Generating self-signed TLS certificate for local testing..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$CERT_DIR/komms.key" \
        -out    "$CERT_DIR/komms.crt" \
        -subj   "/CN=${DOMAIN}/O=${CERT_ORG:-KOMMS}/C=${CERT_COUNTRY:-DE}" \
        -addext "subjectAltName=DNS:${DOMAIN},IP:127.0.0.1" \
        2>/dev/null
    ok "nginx/certs/komms.crt generated"
else
    ok "nginx/certs/komms.crt already exists"
fi

echo ""
echo -e "  ${GREEN}All configs ready. Start KOMMS with:${NC}"
echo -e "  ${CYAN}docker compose up -d${NC}"
echo ""
warn "TAKServer requires its Docker image to be loaded first (setup_tak.sh)."
info "To start without TAKServer: docker compose up -d --scale takserver=0"
echo ""
