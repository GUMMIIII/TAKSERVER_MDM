#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS Platform – Server Setup (non-interactive)
#
#  Called by install.sh after .env is written, or run standalone to re-apply
#  server configuration on an existing deployment.
#
#  Usage (standalone): sudo bash /opt/komms/server/setup_server.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOMMS_DIR="$(dirname "$SCRIPT_DIR")"
# .env ist ein Symlink → /opt/komms-data/.env (angelegt von install.sh)
ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}▶  $*${NC}"; }

# ── Root + .env ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash setup_server.sh"
[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"
# shellcheck source=/dev/null
set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a

[[ -z "${DOMAIN:-}"  ]] && err "DOMAIN not set in .env"
[[ -z "${DB_PASS:-}" ]] && err "DB_PASS not set in .env"
[[ -z "${LDAP_ADMIN_PASS:-}" ]] && err "LDAP_ADMIN_PASS not set in .env"

DEPLOY_MODE="${DEPLOY_MODE:-lan}"
DATA_DIR="${DATA_DIR:-/opt/komms-data}"

# Verzeichnisse anlegen (idempotent — falls setup_server.sh standalone läuft)
mkdir -p \
    "$DATA_DIR/config/nginx/certs" \
    "$DATA_DIR/config/authelia" \
    "$DATA_DIR/config/matrix" \
    "$DATA_DIR/config/element" \
    "$DATA_DIR/config/mumble" \
    "$DATA_DIR/config/dnsmasq" \
    "$DATA_DIR/config/takserver" \
    "$DATA_DIR/users" \
    "$DATA_DIR/tak" \
    "$DATA_DIR/tak-release"

# ── [1] Firewall ──────────────────────────────────────────────────────────────
step "[1/7] Configuring firewall (UFW)"
if ! command -v ufw &>/dev/null; then
    warn "UFW not installed — skipping firewall setup."
elif [[ "$DEPLOY_MODE" == "lan" ]]; then
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp    comment "SSH"
    ufw allow 80/tcp    comment "HTTP"
    ufw allow 443/tcp   comment "HTTPS"
    ufw allow 8080/tcp  comment "Element Web"
    ufw allow "${VPN_PORT:-1194}/udp" comment "OpenVPN"
    ufw allow 64738/tcp comment "Mumble TCP"
    ufw allow 64738/udp comment "Mumble UDP"
    ufw allow from "${VPN_SUBNET:-10.8.0.0}/24" to any port 53 proto udp comment "DNS for VPN clients (dnsmasq)"
    ufw --force enable
    ok "Firewall configured (LAN mode)"
else
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp    comment "SSH"
    ufw allow 80/tcp    comment "HTTP → HTTPS redirect"
    ufw allow 443/tcp   comment "HTTPS"
    ufw allow "${VPN_PORT:-1194}/udp" comment "OpenVPN"
    ufw allow 8089/tcp  comment "ATAK/WinTAK TLS"
    ufw allow 8444/tcp  comment "TAKServer cert enrollment"
    ufw allow 64738/tcp comment "Mumble TCP"
    ufw allow 64738/udp comment "Mumble UDP"
    ufw allow from "${VPN_SUBNET:-10.8.0.0}/24" to any port 53 proto udp comment "DNS for VPN clients (dnsmasq)"
    ufw --force enable
    ok "Firewall configured (VPS mode)"
    if command -v fail2ban-client &>/dev/null; then
        systemctl enable --now fail2ban >/dev/null 2>&1 || true
        ok "fail2ban enabled"
    fi
fi

# ── [2] TLS certificate ───────────────────────────────────────────────────────
step "[2/7] TLS certificate"
CERT_DIR="$DATA_DIR/config/nginx/certs"
mkdir -p "$CERT_DIR"

if [[ "$DEPLOY_MODE" == "vps" ]]; then
    if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        info "Obtaining Let's Encrypt certificate for ${DOMAIN} and subdomains..."
        if ! command -v certbot &>/dev/null; then
            apt-get install -y -qq certbot
        fi
        certbot certonly --standalone --non-interactive --agree-tos --expand \
            -m "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL not set in .env}" \
            -d "${DOMAIN}" \
            -d "auth.${DOMAIN}" \
            -d "mdm.${DOMAIN}" \
            -d "cloud.${DOMAIN}" \
            -d "matrix.${DOMAIN}" \
            -d "element.${DOMAIN}" \
            -d "ldap.${DOMAIN}" \
            -d "collabora.${DOMAIN}" \
            ${TAK_DOMAIN:+-d "${TAK_DOMAIN}"} \
            2>&1 | tee /tmp/certbot.log | grep -E "(Congratulations|Certificate|error|Error)" || true
        if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
            err "certbot failed — check /tmp/certbot.log for details."
        fi
        ok "Let's Encrypt certificate obtained"
    else
        ok "Let's Encrypt certificate already exists"
    fi
    cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "$CERT_DIR/komms.crt"
    cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "$CERT_DIR/komms.key"
    chmod 644 "$CERT_DIR/komms.crt"
    chmod 600 "$CERT_DIR/komms.key"
    ok "Certificate copied to nginx"

    # Deploy hook: copy renewed cert + reload nginx
    HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$HOOK_DIR"
    CERT_DIR_ABS="$CERT_DIR"
    cat > "$HOOK_DIR/komms-nginx.sh" << HOOK
#!/bin/bash
cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERT_DIR_ABS}/komms.crt"
cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "${CERT_DIR_ABS}/komms.key"
chmod 644 "${CERT_DIR_ABS}/komms.crt"
chmod 600 "${CERT_DIR_ABS}/komms.key"
docker exec komms_nginx nginx -s reload 2>/dev/null || true
HOOK
    chmod +x "$HOOK_DIR/komms-nginx.sh"
    ok "Certbot renewal hook installed"
else
    if [[ ! -f "$CERT_DIR/komms.crt" ]]; then
        SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
            -keyout "$CERT_DIR/komms.key" \
            -out    "$CERT_DIR/komms.crt" \
            -subj   "/CN=${DOMAIN}/O=${CERT_ORG:-KOMMS}/C=${CERT_COUNTRY:-DE}/ST=${CERT_STATE:-Bayern}/L=${CERT_CITY:-Berlin}" \
            -addext "subjectAltName=DNS:${DOMAIN},IP:${SERVER_IP}" \
            2>/dev/null
        ok "Self-signed certificate generated"
    else
        ok "TLS certificate already exists"
    fi
fi

# ── [3] Generate configs ──────────────────────────────────────────────────────
step "[3/7] Generating service configuration"

# nginx.conf: VPS uses subdomain template, LAN keeps existing subpath config
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    VPS_TPL="$SCRIPT_DIR/nginx/nginx.conf.vps.template"
    [[ -f "$VPS_TPL" ]] || err "VPS nginx template not found at $VPS_TPL"
    TAK_DOMAIN="${TAK_DOMAIN:-tak.${DOMAIN}}"
    export DOMAIN VPN_SUBNET TAK_DOMAIN
    envsubst '${DOMAIN} ${VPN_SUBNET} ${TAK_DOMAIN}' < "$VPS_TPL" > "$DATA_DIR/config/nginx/nginx.conf"
    ok "nginx.conf generated → $DATA_DIR/config/nginx/nginx.conf"

    # Authelia main configuration
    AUTHELIA_TPL="$SCRIPT_DIR/authelia/configuration.yml.template"
    [[ -f "$AUTHELIA_TPL" ]] || err "Authelia config template not found at $AUTHELIA_TPL"
    export LDAP_BASE_DN DB_USER TAK_DOMAIN
    envsubst '${DOMAIN} ${LDAP_BASE_DN} ${DB_USER} ${TAK_DOMAIN}' \
        < "$AUTHELIA_TPL" > "$DATA_DIR/config/authelia/configuration.yml"
    ok "authelia/configuration.yml generated → $DATA_DIR/config/authelia/"

    # Authelia OIDC provider config — appended to configuration.yml
    OIDC_PEM="$DATA_DIR/config/authelia/oidc.pem"
    AUTHELIA_CFG="$DATA_DIR/config/authelia/configuration.yml"
    if [[ ! -f "$OIDC_PEM" ]]; then
        info "Generating RSA-4096 key for Authelia OIDC JWKS..."
        openssl genrsa 4096 > "$OIDC_PEM" 2>/dev/null
        chmod 600 "$OIDC_PEM"
        ok "authelia/oidc.pem generated"
    else
        ok "authelia/oidc.pem already exists"
    fi
    _OIDC_HMAC="${AUTHELIA_OIDC_HMAC_SECRET:?AUTHELIA_OIDC_HMAC_SECRET not set in .env}"
    _NC_SECRET="${NEXTCLOUD_OIDC_SECRET:?NEXTCLOUD_OIDC_SECRET not set in .env}"
    _SYNAPSE_SECRET="${SYNAPSE_OIDC_SECRET:?SYNAPSE_OIDC_SECRET not set in .env}"
    {
        cat << OIDC_HEADER

identity_providers:
  oidc:
    hmac_secret: '${_OIDC_HMAC}'
    jwks:
      - key_id: 'default'
        algorithm: 'RS256'
        use: 'sig'
        key: |
OIDC_HEADER
        sed 's/^/          /' "$OIDC_PEM"
        cat << OIDC_CLIENTS
    clients:
      - client_id: 'nextcloud'
        client_name: 'Nextcloud'
        client_secret: '\$plaintext\$${_NC_SECRET}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://cloud.${DOMAIN}/apps/user_oidc/code'
        scopes: [openid, profile, email, groups]
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_post
        consent_mode: implicit
      - client_id: 'synapse'
        client_name: 'Matrix / Element'
        client_secret: '\$plaintext\$${_SYNAPSE_SECRET}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://matrix.${DOMAIN}/_synapse/client/oidc/callback'
        scopes: [openid, profile, email]
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
        consent_mode: implicit
OIDC_CLIENTS
    } >> "$AUTHELIA_CFG"
    ok "OIDC provider block appended to authelia/configuration.yml"

    # dnsmasq split-horizon DNS config
    mkdir -p "$SCRIPT_DIR/dnsmasq"
    VPN_GW="${VPN_SUBNET:-10.8.0.0}"
    VPN_GW="${VPN_GW%.*}.1"
    export VPN_GW
    envsubst '${DOMAIN} ${VPN_GW}' \
        < "$SCRIPT_DIR/dnsmasq/dnsmasq.conf.template" > "$DATA_DIR/config/dnsmasq/dnsmasq.conf"
    ok "dnsmasq.conf generated → $DATA_DIR/config/dnsmasq/ (*.${DOMAIN} → ${VPN_GW})"
else
    ok "nginx.conf unchanged (LAN subpath mode)"
fi

# Matrix homeserver.yaml — template stays in repo, generated file goes to data dir
MATRIX_TPL="$SCRIPT_DIR/matrix/homeserver.yaml"
MATRIX_GENERATED="$DATA_DIR/config/matrix/homeserver.yaml"
if [[ ! -f "$MATRIX_GENERATED" ]]; then
    [[ -f "$MATRIX_TPL" ]] || err "Matrix homeserver.yaml template not found at $MATRIX_TPL"
    export DB_USER DB_PASS MATRIX_DOMAIN MATRIX_MACAROON_SECRET \
           MATRIX_FORM_SECRET MATRIX_REGISTRATION_SHARED_SECRET \
           LDAP_BASE_DN LDAP_ADMIN_PASS MATRIX_PUBLIC_BASEURL \
           DOMAIN SYNAPSE_OIDC_SECRET
    envsubst '${DB_USER} ${DB_PASS} ${MATRIX_DOMAIN} ${MATRIX_MACAROON_SECRET} ${MATRIX_FORM_SECRET} ${MATRIX_REGISTRATION_SHARED_SECRET} ${LDAP_BASE_DN} ${LDAP_ADMIN_PASS} ${MATRIX_PUBLIC_BASEURL} ${DOMAIN} ${SYNAPSE_OIDC_SECRET}' \
        < "$MATRIX_TPL" > "$MATRIX_GENERATED"
    chmod 644 "$MATRIX_GENERATED"
    ok "homeserver.yaml generated → $DATA_DIR/config/matrix/"
else
    ok "homeserver.yaml already exists in data dir"
fi

# Element Web config.json — always written from current mode settings
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    MATRIX_BASE_URL="https://matrix.${DOMAIN}"
else
    MATRIX_BASE_URL="https://${DOMAIN}"
fi

cat > "$DATA_DIR/config/element/config.json" << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "${MATRIX_BASE_URL}",
            "server_name": "${DOMAIN}"
        }
    },
    "brand": "KOMMS",
    "disable_custom_urls": false,
    "disable_guests": true,
    "disable_3pid_login": true,
    "default_country_code": "DE",
    "show_labs_settings": false,
    "default_federate": false,
    "room_directory": {
        "servers": []
    },
    "settingDefaults": {
        "breadcrumbs": true,
        "language": "de-DE"
    },
    "sso_redirect_options": {
        "immediate": true,
        "on_welcome_page": false
    }
}
EOF
ok "element/config.json written → $DATA_DIR/config/element/ (homeserver: ${MATRIX_BASE_URL})"

# ── [4] OpenVPN PKI ───────────────────────────────────────────────────────────
step "[4/7] OpenVPN PKI"
cd "$SCRIPT_DIR"

if docker compose run --rm openvpn bash -c '[ -f /etc/openvpn/pki/ca.crt ]' >/dev/null 2>&1; then
    ok "OpenVPN PKI already initialized"
else
    info "Initializing OpenVPN PKI..."
    docker compose run --rm openvpn ovpn_genconfig \
        -u "udp://${VPN_HOST:-$DOMAIN}" \
        -s "${VPN_SUBNET:-10.8.0.0}/24"
    # Switch to split-tunnel: clients keep their own internet route.
    # redirect-gateway routes ALL traffic through the container (no internet NAT).
    # block-outside-dns breaks Windows split-tunnel DNS.
    # Remove any generated DNS push — the correct DNS (dnsmasq tun0 IP) is
    # injected by the idempotent block below, after PKI init.
    docker compose run --rm openvpn bash -c '
        sed -i "/redirect-gateway/d"  /etc/openvpn/openvpn.conf
        sed -i "/block-outside-dns/d" /etc/openvpn/openvpn.conf
        sed -i "/dhcp-option DNS/d"   /etc/openvpn/openvpn.conf
    ' >/dev/null 2>&1 || true
    docker compose run --rm -e EASYRSA_BATCH=1 openvpn ovpn_initpki nopass
    ok "OpenVPN PKI initialized (split-tunnel)"
fi

# Always update push directives (idempotent):
# Remove any stale server-IP route push and push dnsmasq IP as DNS instead.
# dnsmasq resolves *.DOMAIN → tun0 IP so VPN clients reach nginx via tunnel.
_VPN_GW="${VPN_SUBNET:-10.8.0.0}"
_VPN_GW="${_VPN_GW%.*}.1"
docker compose run --rm openvpn bash -c "
    sed -i '/push.*route.*255\.255\.255\.255/d' /etc/openvpn/openvpn.conf
    sed -i '/push.*dhcp-option DNS/d'           /etc/openvpn/openvpn.conf
    echo 'push \"dhcp-option DNS ${_VPN_GW}\"' >> /etc/openvpn/openvpn.conf
" >/dev/null 2>&1
ok "OpenVPN push directives: DNS → ${_VPN_GW} (split-horizon via dnsmasq)"

# Add LDAP credential check to OpenVPN server config (idempotent).
# Uses "sh script" so no execute-bit is required on the mounted file.
docker compose run --rm openvpn bash -c \
    'grep -q "auth-user-pass-verify" /etc/openvpn/openvpn.conf || printf "%s\n%s\n%s\n" \
        "auth-user-pass-verify \"/bin/sh /etc/openvpn/auth/verify_ldap.sh\" via-env" \
        "script-security 3" \
        "username-as-common-name" >> /etc/openvpn/openvpn.conf' >/dev/null 2>&1
ok "OpenVPN LDAP auth configured"

# Restart OpenVPN so new push directives (DNS) take effect for new connections.
docker compose restart openvpn >/dev/null 2>&1 || true
ok "OpenVPN restarted (new push directives active)"

# ── [5] Start services ────────────────────────────────────────────────────────
step "[5/7] Starting KOMMS services"
cd "$SCRIPT_DIR"

info "Building Synapse custom image (adds matrix-synapse-ldap3)..."
docker compose build synapse --quiet

_BASE_SERVICES="nginx postgres redis lldap authelia headwind openvpn synapse mumble nextcloud element-web collabora"
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    info "Building dnsmasq image (VPS split-horizon DNS)..."
    docker compose build dnsmasq --quiet
    _BASE_SERVICES="$_BASE_SERVICES dnsmasq"
fi

TAK_IMAGE_VAL="${TAK_IMAGE:-}"
if [[ -n "$TAK_IMAGE_VAL" ]] && docker image inspect "$TAK_IMAGE_VAL" &>/dev/null 2>&1; then
    _START_SERVICES="$_BASE_SERVICES takserver"
else
    _START_SERVICES="$_BASE_SERVICES"
    warn "TAKServer image not loaded — skipping (run setup_tak.sh to add it later)"
fi

info "Pulling remaining images..."
# shellcheck disable=SC2086
docker compose pull --ignore-buildable --quiet $_START_SERVICES 2>/dev/null || true

# Pre-create Synapse data volume with correct ownership BEFORE starting services.
# Docker creates named volumes as root; the Synapse container runs as uid 991,
# causing PermissionError on /data/signing.key if ownership isn't set first.
info "Pre-creating Synapse data volume (uid 991)..."
_SYN_VOL_NAME="$(basename "$SCRIPT_DIR")_synapse_data"
docker volume create "$_SYN_VOL_NAME" >/dev/null 2>&1 || true
docker run --rm -v "${_SYN_VOL_NAME}:/data" alpine chown -R 991:991 /data >/dev/null 2>&1 || true
ok "Synapse volume ownership set (uid 991)"

# shellcheck disable=SC2086
docker compose up -d $_START_SERVICES
ok "Services started"

# ── Mumble: server name + join password ───────────────────────────────────────
MUMBLE_SERVER_PASS="${MUMBLE_SERVER_PASS:-}"
MUMBLE_SERVER_NAME="${MUMBLE_SERVER_NAME:-KOMMS Voice}"
_MURMUR_TPL="$SCRIPT_DIR/mumble/murmur.ini"
_MURMUR_INI="$DATA_DIR/config/mumble/murmur.ini"
# Copy template to data dir on first run; subsequent runs update the data dir copy.
if [[ ! -f "$_MURMUR_INI" ]] && [[ -f "$_MURMUR_TPL" ]]; then
    cp "$_MURMUR_TPL" "$_MURMUR_INI"
fi
if [[ -f "$_MURMUR_INI" ]]; then
    sed -i "s/^registerName=.*/registerName=${MUMBLE_SERVER_NAME}/" "$_MURMUR_INI"
    if grep -q "^serverpassword=" "$_MURMUR_INI"; then
        sed -i "s/^serverpassword=.*/serverpassword=${MUMBLE_SERVER_PASS}/" "$_MURMUR_INI"
    else
        echo "serverpassword=${MUMBLE_SERVER_PASS}" >> "$_MURMUR_INI"
    fi
    docker compose restart mumble >/dev/null 2>&1 || true
    ok "Mumble: server name and join password set → $DATA_DIR/config/mumble/murmur.ini"
fi

# Wait for Synapse to pass its healthcheck (up to 3 min), then restart nginx
# to ensure all upstream hostnames are freshly resolved in Docker DNS.
info "Waiting for Synapse to initialize (up to 3 min)..."
_SYN_TRIES=0
until [[ "$(docker inspect --format='{{.State.Health.Status}}' komms_synapse 2>/dev/null)" == "healthy" ]]; do
    _SYN_TRIES=$((_SYN_TRIES + 1))
    if [[ $_SYN_TRIES -ge 36 ]]; then
        warn "Synapse not healthy after 3 min — restarting nginx anyway"
        break
    fi
    sleep 5
done
[[ $_SYN_TRIES -lt 36 ]] && ok "Synapse healthy"
docker compose restart nginx >/dev/null 2>&1 || true
ok "nginx restarted"

# ── [6] Configure Nextcloud ───────────────────────────────────────────────────
step "[6/7] Configuring Nextcloud LDAP + OIDC integration"
bash "$SCRIPT_DIR/setup_nextcloud_ldap.sh"

# Nextcloud reverse-proxy settings: trust nginx, force https:// URLs.
docker compose exec -T -u www-data nextcloud php occ config:system:set overwriteprotocol --value=https >/dev/null 2>&1 || true
docker compose exec -T -u www-data nextcloud php occ config:system:set overwrite.cli.url --value="https://cloud.${DOMAIN}" >/dev/null 2>&1 || true
docker compose exec -T -u www-data nextcloud php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12" >/dev/null 2>&1 || true
# Allow Nextcloud to make outbound requests to internal/Docker IPs (needed for OIDC discovery via nginx alias)
docker compose exec -T -u www-data nextcloud php occ config:system:set allow_local_remote_servers --value=true --type=boolean >/dev/null 2>&1 || true
# Remove header-based SSO (replaced by OIDC)
docker compose exec -T -u www-data nextcloud php occ config:system:delete user_auth_trusted_header >/dev/null 2>&1 || true
ok "Nextcloud proxy config set (overwriteprotocol=https, trusted_proxies, allow_local_remote_servers)"

# Install and configure user_oidc app for Authelia SSO
info "Installing Nextcloud user_oidc app..."
docker compose exec -T -u www-data nextcloud php occ app:install user_oidc >/dev/null 2>&1 || \
    docker compose exec -T -u www-data nextcloud php occ app:enable  user_oidc >/dev/null 2>&1 || true

_NC_SECRET="${NEXTCLOUD_OIDC_SECRET:?NEXTCLOUD_OIDC_SECRET not set in .env}"
docker compose exec -T -u www-data nextcloud php occ user_oidc:provider Authelia \
    --clientid=nextcloud \
    --clientsecret="${_NC_SECRET}" \
    --discoveryuri="https://auth.${DOMAIN}/.well-known/openid-configuration" \
    --unique-uid=0 \
    --mapping-uid=preferred_username \
    >/dev/null 2>&1 || true
# Auto-redirect to Authelia on the Nextcloud login page
docker compose exec -T -u www-data nextcloud php occ \
    config:app:set user_oidc auto_redirect_login_page --value=1 >/dev/null 2>&1 || true
# Disable password login — OIDC (Authelia SSO) is the only auth path
docker compose exec -T -u www-data nextcloud php occ \
    config:app:set user_oidc allow_multiple_user_backends --value=0 >/dev/null 2>&1 || true
ok "Nextcloud OIDC: Authelia provider configured (auto-redirect enabled)"

# Switch Nextcloud background jobs from AJAX (runs on user requests) to cron.
# AJAX mode causes post-login lag; cron mode offloads jobs to a system timer.
docker compose exec -T -u www-data nextcloud php occ \
    config:system:set backgroundjobs_mode --value=cron >/dev/null 2>&1 && \
    ok "Nextcloud background jobs: cron mode" || true

# Write dedicated cron file so the job survives root crontab edits.
cat > /etc/cron.d/komms-nextcloud << 'CRONEOF'
*/5 * * * * root docker exec -u www-data komms_nextcloud php -f /var/www/html/cron.php
CRONEOF
chmod 644 /etc/cron.d/komms-nextcloud
ok "Nextcloud cron job installed (/etc/cron.d/komms-nextcloud)"

# Install and configure richdocuments (Collabora Online) if in VPS mode
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    info "Installing Nextcloud richdocuments app (Collabora Office)..."
    docker compose exec -T -u www-data nextcloud php occ app:install richdocuments >/dev/null 2>&1 || \
        docker compose exec -T -u www-data nextcloud php occ app:enable  richdocuments >/dev/null 2>&1 || true
    docker compose exec -T -u www-data nextcloud php occ config:app:set richdocuments wopi_url \
        --value="https://collabora.${DOMAIN}" >/dev/null 2>&1 || true
    ok "Nextcloud richdocuments: Collabora wopi_url=https://collabora.${DOMAIN}"
fi

# ── [7] Headwind MDM admin password ───────────────────────────────────────────
step "[7/7] Setting Headwind MDM admin password"

HMDM_PASS="${HMDM_ADMIN_PASS:-admin}"

info "Waiting for Headwind DB initialization (up to 3 min)..."
TRIES=0
until docker compose exec -T -e PGPASSWORD="$DB_PASS" postgres \
    psql -U "$DB_USER" -d hmdm -qtAc \
    "SELECT 1 FROM information_schema.tables WHERE table_name='users'" \
    2>/dev/null | grep -q 1; do
    TRIES=$((TRIES + 1))
    if [[ $TRIES -ge 36 ]]; then
        warn "Headwind DB not ready after 3 min — skipping password init."
        warn "Run manually: bash $SCRIPT_DIR/setup_server.sh"
        TRIES=-1
        break
    fi
    printf "."
    sleep 5
done
[[ $TRIES -gt 0 ]] && echo ""

if [[ $TRIES -ge 0 ]]; then
    # Headwind stores the MD5 hash (uppercase) that the browser computes client-side
    HMDM_HASH=$(printf '%s' "$HMDM_PASS" | md5sum | awk '{print $1}' | tr 'a-z' 'A-Z')

    docker compose exec -T -e PGPASSWORD="$DB_PASS" postgres \
        psql -U "$DB_USER" -d hmdm -q \
        -c "UPDATE users SET password='$HMDM_HASH', passwordreset=false, lastloginfail=0 WHERE id=1;" \
        >/dev/null
    ok "Headwind admin: ${HMDM_ADMIN_EMAIL:-admin@komms.local} / ${HMDM_PASS}"

    # Create default KOMMS device configuration via API
    info "Creating default MDM configuration..."
    _HMDM_COOKIES=$(mktemp)
    _HMDM_TOKEN=$(curl -sf --max-time 10 -c "$_HMDM_COOKIES" "${HMDM_URL}/rest/public/auth/login" \
        -H "Content-Type: application/json" \
        -H "Origin: ${HMDM_URL}" \
        -H "Referer: ${HMDM_URL}/" \
        -H "User-Agent: Mozilla/5.0 (KOMMS-Script)" \
        -d "{\"login\":\"${HMDM_ADMIN_LOGIN:-admin}\",\"password\":\"${HMDM_HASH}\"}" \
        2>/dev/null | jq -r '.data.authToken // empty' 2>/dev/null || true)

    if [[ -n "$_HMDM_TOKEN" ]]; then
        _CFG_ID=$(curl -sf --max-time 5 -b "$_HMDM_COOKIES" "${HMDM_URL}/rest/private/configurations/list" \
            2>/dev/null | jq -r '.data[] | select(.name == "KOMMS") | .id' 2>/dev/null | head -1 || true)

        if [[ -z "$_CFG_ID" ]]; then
            _CFG_ID=$(curl -sf --max-time 10 -b "$_HMDM_COOKIES" -X POST "${HMDM_URL}/rest/private/configurations" \
                -H "Content-Type: application/json" \
                -d '{"name":"KOMMS","type":1,"useDefaultDesktop":false,"iconSize":"NORMAL","password":""}' \
                2>/dev/null | jq -r '.data.id // empty' 2>/dev/null || true)
        fi

        if [[ -n "$_CFG_ID" ]]; then
            grep -q "^HMDM_CONFIG_ID=" "$ENV_FILE" \
                && sed -i "s/^HMDM_CONFIG_ID=.*/HMDM_CONFIG_ID=\"${_CFG_ID}\"/" "$ENV_FILE" \
                || echo "HMDM_CONFIG_ID=\"${_CFG_ID}\"" >> "$ENV_FILE"
            ok "Headwind MDM default configuration: KOMMS (id: ${_CFG_ID})"
        else
            warn "Could not create Headwind configuration — run 'add_user.sh' after creating one manually."
        fi
    else
        warn "Headwind API not reachable yet — HMDM_CONFIG_ID not set. Re-run setup_server.sh once Headwind is up."
    fi
    rm -f "$_HMDM_COOKIES"

    # Ensure HMDM launcher APK is present in files volume (needed for enrollment QR)
    _APK_URL=$(docker compose exec -T -e PGPASSWORD="$DB_PASS" postgres \
        psql -U "$DB_USER" -d hmdm -t \
        -c "SELECT url FROM applicationversions WHERE url LIKE '%hmdm-%.apk' LIMIT 1;" \
        2>/dev/null | tr -d ' \t\r\n')
    if [[ -n "$_APK_URL" ]]; then
        _APK_FILE=$(basename "$_APK_URL")
        if ! docker compose exec -T headwind test -f "/opt/hmdm/files/$_APK_FILE" 2>/dev/null; then
            info "Downloading HMDM launcher APK ($_APK_FILE)..."
            _H_MDM_SRC="https://h-mdm.com/files/$_APK_FILE"
            if curl -sf --max-time 120 "$_H_MDM_SRC" -o "/tmp/$_APK_FILE" 2>/dev/null; then
                docker cp "/tmp/$_APK_FILE" "komms_headwind:/opt/hmdm/files/$_APK_FILE" \
                    && ok "HMDM launcher APK downloaded: $_APK_FILE" \
                    || warn "docker cp failed — place $_APK_FILE in headwind_files volume manually."
                rm -f "/tmp/$_APK_FILE"
            else
                warn "HMDM APK download failed — get it manually: $_H_MDM_SRC"
            fi
        else
            ok "HMDM launcher APK already present: $_APK_FILE"
        fi
    fi

    # PROTOCOL=http avoids SSL-cert lookup by headwind, but public URL must be https://.
    # ROOT.xml is only generated when it doesn't exist, so patching it + restarting is stable.
    _ROOT_XML="/usr/local/tomcat/conf/Catalina/localhost/ROOT.xml"
    if docker compose exec -T headwind grep -q "http://${HEADWIND_DOMAIN}" "$_ROOT_XML" 2>/dev/null; then
        info "Patching Headwind base.url to https:// in ROOT.xml..."
        docker compose exec -T headwind \
            sed -i "s|http://${HEADWIND_DOMAIN}|https://${HEADWIND_DOMAIN}|g" "$_ROOT_XML"
        docker compose restart headwind >/dev/null 2>&1
        ok "Headwind base.url: https://${HEADWIND_DOMAIN}"
    fi

    # HMDM init.sql uses $PROTOCOL://$BASE_DOMAIN for APK URLs → http:// with PROTOCOL=http.
    # Fix all applicationversions URLs to https:// so Android 9+ can download APKs.
    docker compose exec -T -e PGPASSWORD="$DB_PASS" postgres \
        psql -U "$DB_USER" -d hmdm -q \
        -c "UPDATE applicationversions SET url = REPLACE(url, 'http://${HEADWIND_DOMAIN}', 'https://${HEADWIND_DOMAIN}') WHERE url LIKE 'http://${HEADWIND_DOMAIN}/%';" \
        2>/dev/null && ok "APK URLs patched to https://" || true
fi

echo ""
echo -e "  ${CYAN}docker compose ps${NC}          — check container status"
echo -e "  ${CYAN}docker compose logs -f <svc>${NC} — follow logs"
echo ""
