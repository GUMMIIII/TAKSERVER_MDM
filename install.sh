#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  TAKSERVER_MDM – One-Shot Installer
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/TAKSERVER_MDM/main/install.sh | bash
#
#  Private repo (GitHub PAT required):
#    curl -H "Authorization: token $GITHUB_PAT" \
#         -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/TAKSERVER_MDM/main/install.sh \
#      | GITHUB_PAT=$GITHUB_PAT bash
#
#  Supported OS: Ubuntu 22.04 / 24.04 · Debian 12 · Raspberry Pi OS (64-bit)
#  Architecture: x86_64 (full) · aarch64/arm64 (TAKServer unavailable)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIGURE BEFORE DEPLOYING ───────────────────────────────────────────────
REPO_OWNER="GUMMIIII"
REPO_NAME="TAKSERVER_MDM"
REPO_BRANCH="main"
KOMMS_DIR="/opt/komms"       # Git-Repo (Code) — via git pull aktualisierbar
DATA_DIR="/opt/komms-data"   # Persistente Daten (Secrets, generierte Configs, User-Dateien)
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}▶  $*${NC}"; }
hr()   { echo -e "${BLUE}  ─────────────────────────────────────────────────${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root (sudo) or pipe with: sudo bash"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BLUE}${BOLD}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║          KOMMS – Secure Communications Platform         ║
  ║    OpenVPN · TAKServer · Matrix · Mumble · Nextcloud    ║
  ║              Headwind MDM  ·  Installer v1.0            ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── OS Detection ──────────────────────────────────────────────────────────────
[[ -f /etc/os-release ]] || err "Cannot detect OS. Only Ubuntu/Debian/Raspberry Pi OS supported."
# shellcheck source=/dev/null
source /etc/os-release

case "$ID" in
    ubuntu|debian|raspbian) ok "OS: $PRETTY_NAME" ;;
    *) err "Unsupported OS: $PRETTY_NAME. Requires Ubuntu 22.04/24.04, Debian 12, or Raspberry Pi OS (64-bit)." ;;
esac

ARCH=$(uname -m)
info "Architecture: $ARCH"

ARM_MODE=false
TAK_AVAILABLE=true
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ARM_MODE=true
    TAK_AVAILABLE=false
    warn "ARM64 detected (Raspberry Pi). TAKServer is x86-only and will be skipped."
fi

# ── Deployment mode ───────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Deployment mode:${NC}"
echo -e "  ${CYAN}1)${NC} VPS / Cloud Server  — public IP or domain, UFW hardening, fail2ban"
echo -e "  ${CYAN}2)${NC} LAN / Homelab       — private IP, basic firewall, no external exposure"
echo ""
printf "  ${CYAN}Select mode${NC} ${YELLOW}[1=VPS, 2=LAN, default: 1]${NC}: "
read -r _MODE_INPUT < /dev/tty
case "${_MODE_INPUT:-1}" in
    2) DEPLOY_MODE=lan;  ok "Mode: LAN / Homelab" ;;
    *) DEPLOY_MODE=vps;  ok "Mode: VPS / Cloud Server" ;;
esac

# ── Input helpers ─────────────────────────────────────────────────────────────
prompt() {
    local msg="$1" default="${2:-}"
    printf "\n  ${CYAN}%s${NC}" "$msg" >/dev/tty
    [[ -n "$default" ]] && printf " ${YELLOW}[%s]${NC}" "$default" >/dev/tty
    printf ": " >/dev/tty
    local val
    read -r val < /dev/tty
    echo "${val:-$default}"
}

prompt_secret() {
    local msg="$1"
    printf "\n  ${CYAN}%s${NC}: " "$msg" >/dev/tty
    local val
    read -rs val < /dev/tty
    echo "" >/dev/tty
    [[ -z "$val" ]] && err "Password cannot be empty."
    echo "$val"
}

prompt_yn() {
    local msg="$1" default="${2:-n}"
    printf "\n  ${CYAN}%s${NC} ${YELLOW}[y/n, default: %s]${NC}: " "$msg" "$default" >/dev/tty
    local val
    read -r val < /dev/tty
    val="${val:-$default}"
    [[ "$val" =~ ^[Yy] ]]
}

# ── Collect configuration ─────────────────────────────────────────────────────
step "Configuration"
echo -e "\n  ${YELLOW}Enter values for all settings. Press Enter to accept the default shown in [brackets].${NC}\n"
hr

echo -e "\n  ${BOLD}── Server ──────────────────────────────────────────${NC}"
AUTO_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    info "Enter the public domain name for this server (e.g. komms.example.com)."
    info "Auto-detected IP: ${AUTO_IP}"
else
    info "Enter the LAN IP of this server."
fi
DOMAIN=$(prompt "Server domain / IP" "${AUTO_IP}")
[[ -z "$DOMAIN" ]] && err "Server domain/IP is required."

if [[ "$DEPLOY_MODE" == "vps" ]]; then
    VPS_IP=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
    TAK_DOMAIN="tak.${DOMAIN}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}DNS records required before Let's Encrypt can issue certificates.${NC}"
    echo -e "  Create these A records pointing to ${CYAN}${VPS_IP}${NC}:"
    echo -e "    ${CYAN}${DOMAIN}${NC}"
    echo -e "    ${CYAN}auth.${DOMAIN}${NC}"
    echo -e "    ${CYAN}element.${DOMAIN}${NC}"
    echo -e "    ${CYAN}matrix.${DOMAIN}${NC}"
    echo -e "    ${CYAN}cloud.${DOMAIN}${NC}"
    echo -e "    ${CYAN}mdm.${DOMAIN}${NC}"
    echo -e "    ${CYAN}mumble.${DOMAIN}${NC}"
    echo -e "    ${CYAN}tak.${DOMAIN}${NC}"
    echo -e "    ${CYAN}ldap.${DOMAIN}${NC}"
    echo -e "    ${CYAN}office.${DOMAIN}${NC}"
    echo -e "  ${YELLOW}(Or use a wildcard: *.${DOMAIN} + ${DOMAIN})${NC}"
    echo ""
    if ! prompt_yn "Are all DNS records live and pointing to this server?" "n"; then
        warn "Set up DNS records first, then re-run the installer."
        err "DNS not confirmed — aborting."
    fi

    echo -e "\n  ${BOLD}── Let's Encrypt ────────────────────────────────────${NC}"
    info "A valid, internet-accessible email is required by Let's Encrypt for cert expiry notices."
    while true; do
        LETSENCRYPT_EMAIL=$(prompt "Let's Encrypt contact email" "")
        [[ "$LETSENCRYPT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
        warn "Enter a real internet-accessible email address (e.g. you@gmail.com)."
    done
fi

echo -e "\n  ${BOLD}── Database (PostgreSQL) ────────────────────────────${NC}"
info "Shared internal database used by Matrix (Synapse), Nextcloud, and LLDAP."
info "This password is stored in .env and never needs to be typed manually again."
DB_USER=$(prompt "Database username" "komms")
DB_PASS=$(prompt_secret "Database password (min 12 chars)")
[[ ${#DB_PASS} -lt 12 ]] && err "Database password must be at least 12 characters."

echo -e "\n  ${BOLD}── Headwind MDM ─────────────────────────────────────${NC}"
info "Login for the MDM web dashboard — used to manage Android devices and push configs."
info "Use a real email address if you want password-reset support later."
while true; do
    HMDM_ADMIN_EMAIL=$(prompt "MDM admin email" "admin@komms.local")
    [[ "$HMDM_ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
    warn "Invalid email address — please enter a valid address (e.g. admin@example.com)."
done
HMDM_ADMIN_PASS=$(prompt_secret "MDM admin password")

echo -e "\n  ${BOLD}── Nextcloud ────────────────────────────────────────${NC}"
info "Admin account for the Nextcloud file-sharing and collaboration interface."
info "Regular users log in via LLDAP (SSO) — this account is for administration only."
NC_ADMIN=$(prompt "Nextcloud admin username" "admin")
NC_PASS=$(prompt_secret "Nextcloud admin password")

echo -e "\n  ${BOLD}── Matrix / Synapse ─────────────────────────────────${NC}"
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    info "Matrix user IDs will be @user:${DOMAIN} — enter base domain, not subdomain."
else
    info "Matrix user IDs take the form @user:<domain> — determines the identity suffix for all accounts."
fi
info "Three internal secrets (macaroon, form, registration) will be auto-generated."
MATRIX_DOMAIN=$(prompt "Matrix server domain (for user IDs)" "$DOMAIN")
MATRIX_MACAROON_SECRET=$(openssl rand -hex 32)
MATRIX_FORM_SECRET=$(openssl rand -hex 32)
MATRIX_REGISTRATION_SHARED_SECRET=$(openssl rand -hex 32)
info "Matrix secrets auto-generated (saved in .env)."

echo -e "\n  ${BOLD}── Mumble ───────────────────────────────────────────${NC}"
info "Server name is the label shown in Mumble clients when browsing or bookmarking the server."
info "SuperUser is the built-in privileged admin account, separate from regular voice users."
MUMBLE_SERVER_NAME=$(prompt "Mumble server display name" "KOMMS Voice")
MUMBLE_PASS=$(prompt_secret "Mumble superuser password")
MUMBLE_SERVER_PASS=$(prompt_secret "Mumble server join password (users must enter this to connect)")

echo -e "\n  ${BOLD}── SSO / LDAP (LLDAP) ───────────────────────────────${NC}"
info "LLDAP is the central identity provider — all logins (Matrix, Nextcloud, TAK WebUI) use it."
info "Base DN defines the root of the directory tree. Only change this if you need a custom namespace (e.g. dc=myorg,dc=com)."
info "The LLDAP admin password is used by add_user.sh to create and manage operator accounts."
LDAP_BASE_DN=$(prompt "LDAP Base DN" "dc=komms,dc=local")
LDAP_ADMIN_PASS=$(prompt_secret "LLDAP admin password")
LLDAP_JWT_SECRET=$(openssl rand -hex 32)
AUTHELIA_JWT_SECRET=$(openssl rand -hex 32)
AUTHELIA_SESSION_SECRET=$(openssl rand -hex 32)
AUTHELIA_STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)
AUTHELIA_OIDC_HMAC_SECRET=$(openssl rand -hex 32)
NEXTCLOUD_OIDC_SECRET=$(openssl rand -hex 32)
COLLABORA_ADMIN_PASS=$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)
info "LLDAP + Authelia + Collabora secrets auto-generated."

echo -e "\n  ${BOLD}── OpenVPN ──────────────────────────────────────────${NC}"
info "VPN hostname/IP is written into every .ovpn profile distributed to users — must be reachable from the internet."
info "Port 1194 UDP is the standard; change only if blocked by your network or ISP."
info "VPN subnet is the private IP range assigned to connected clients (e.g. 10.8.0.0 → clients get 10.8.0.x)."
VPN_HOST=$(prompt "VPN hostname or IP (written into .ovpn profiles)" "$DOMAIN")
VPN_PORT=$(prompt "VPN UDP port" "1194")
VPN_SUBNET=$(prompt "VPN internal subnet (CIDR base)" "10.8.0.0")

echo -e "\n  ${BOLD}── Certificates ─────────────────────────────────────${NC}"
info "Embedded in OpenVPN and TAKServer self-signed TLS certificates. Not visible to end users."
CERT_COUNTRY=$(prompt "Certificate country code (2 letters)" "DE")
CERT_STATE=$(prompt "Certificate state / province" "Bayern")
CERT_CITY=$(prompt "Certificate city" "Berlin")
CERT_ORG=$(prompt "Certificate organisation" "KOMMS")
CERT_UNIT=$(prompt "Certificate unit" "Ops")

if [[ "$TAK_AVAILABLE" == "true" ]]; then
    echo -e "\n  ${BOLD}── TAKServer ────────────────────────────────────────${NC}"
    info "TAKServer uses Java keystores (.jks) for TLS. This password protects those keystore files."
    info "The default 'atakatak' is acceptable for internal deployments; use a stronger value for exposed servers."
    CERT_PASS=$(prompt "TAK JKS certificate store password" "atakatak")
    TAK_RELEASE_DIR="$DATA_DIR/tak-release"
    info "TAKServer Docker zip from tak.gov must be placed at:"
    info "  $TAK_RELEASE_DIR/<TAKSERVER-DOCKER-*.zip>"
    if prompt_yn "Is the TAKServer zip already in place?" "n"; then
        SETUP_TAK=true
    else
        SETUP_TAK=false
        warn "TAKServer setup will be skipped. Run  bash $KOMMS_DIR/server/setup_tak.sh  later."    fi
else
    CERT_PASS="atakatak"
    SETUP_TAK=false
fi

hr
echo -e "\n  ${YELLOW}Configuration complete — starting installation.${NC}\n"

# ── [1] System update ─────────────────────────────────────────────────────────
step "[1/8] System update"
apt-get update -qq
apt-get upgrade -y -qq
ok "System up to date"

# ── [2] Base packages ─────────────────────────────────────────────────────────
step "[2/8] Installing required packages"
apt-get install -y -qq \
    curl wget git ca-certificates gnupg lsb-release \
    ufw fail2ban unattended-upgrades \
    openssl net-tools htop gettext-base unzip zip \
    jq qrencode
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    apt-get install -y -qq certbot
fi
ok "Packages installed"

# ── [3] Docker ────────────────────────────────────────────────────────────────
step "[3/8] Installing Docker"
if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$ID" "$(lsb_release -cs)" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed: $(docker --version)"
else
    ok "Docker already present: $(docker --version)"
fi

SUDO_USER_ACTUAL="${SUDO_USER:-}"
if [[ -n "$SUDO_USER_ACTUAL" ]]; then
    usermod -aG docker "$SUDO_USER_ACTUAL" || true
    info "Added $SUDO_USER_ACTUAL to docker group (re-login required for non-root use)"
fi

# ── [4] Deploy KOMMS repo ─────────────────────────────────────────────────────
step "[4/8] Deploying KOMMS files"
mkdir -p "$KOMMS_DIR"

GITHUB_PAT="${GITHUB_PAT:-}"
if [[ -d "$KOMMS_DIR/.git" ]]; then
    info "Updating existing repo..."
    # If no PAT provided, try to recover it from the existing remote URL
    if [[ -z "$GITHUB_PAT" ]]; then
        _remote=$(git -C "$KOMMS_DIR" remote get-url origin 2>/dev/null || true)
        # handles both https://x-access-token:TOKEN@... and https://TOKEN@...
        GITHUB_PAT=$(echo "$_remote" | sed -n 's|https://x-access-token:\([^@]*\)@.*|\1|p')
        [[ -z "$GITHUB_PAT" ]] && \
            GITHUB_PAT=$(echo "$_remote" | sed -n 's|https://\([^:@][^@]*\)@.*|\1|p')
    fi
    if [[ -n "$GITHUB_PAT" ]]; then
        git -C "$KOMMS_DIR" remote set-url origin \
            "https://x-access-token:${GITHUB_PAT}@github.com/${REPO_OWNER}/${REPO_NAME}.git"
    fi
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git -C "$KOMMS_DIR" pull --quiet
    ok "Repo updated"
else
    if [[ -n "$GITHUB_PAT" ]]; then
        CLONE_URL="https://x-access-token:${GITHUB_PAT}@github.com/${REPO_OWNER}/${REPO_NAME}.git"
    else
        CLONE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
    fi
    TMP_CLONE=$(mktemp -d)
    info "Cloning KOMMS repo..."
    git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$CLONE_URL" "$TMP_CLONE"
    cp -a "$TMP_CLONE/." "$KOMMS_DIR/"
    rm -rf "$TMP_CLONE"
    ok "Repo deployed to $KOMMS_DIR"
fi

mkdir -p \
    "$DATA_DIR/config/nginx/certs" \
    "$DATA_DIR/config/authelia" \
    "$DATA_DIR/config/matrix" \
    "$DATA_DIR/config/element" \
    "$DATA_DIR/config/mumble" \
    "$DATA_DIR/config/dnsmasq" \
    "$DATA_DIR/config/takserver" \
    "$DATA_DIR/tak-release" \
    "$DATA_DIR/tak" \
    "$DATA_DIR/users" \
    "$KOMMS_DIR/android/vpn-clients"

# ── [5] Write .env ────────────────────────────────────────────────────────────
step "[5/8] Writing .env"

# Compute mode-specific derived values
if [[ "$DEPLOY_MODE" == "vps" ]]; then
    HEADWIND_DOMAIN="mdm.${DOMAIN}"
    NC_TRUSTED_DOMAIN="cloud.${DOMAIN}"
    MATRIX_PUBLIC_BASEURL="https://matrix.${DOMAIN}"
    HMDM_URL="https://mdm.${DOMAIN}"
    TAK_DOMAIN="tak.${DOMAIN}"
else
    TAK_DOMAIN="tak.${DOMAIN}"
    HEADWIND_DOMAIN="${DOMAIN}"
    NC_TRUSTED_DOMAIN="${DOMAIN}"
    MATRIX_PUBLIC_BASEURL="https://${DOMAIN}"
    HMDM_URL="https://${DOMAIN}/mdm"
fi

cat > "$DATA_DIR/.env" << EOF
# KOMMS Platform – Environment Configuration
# Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ─────────────────────────────────────────────────────────────────────────────

DATA_DIR="${DATA_DIR}"

DEPLOY_MODE="${DEPLOY_MODE}"
DOMAIN="${DOMAIN}"

DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"

HMDM_URL="${HMDM_URL}"
HMDM_ADMIN_EMAIL="${HMDM_ADMIN_EMAIL}"
HMDM_ADMIN_PASS="${HMDM_ADMIN_PASS}"
HEADWIND_DOMAIN="${HEADWIND_DOMAIN}"

NC_ADMIN="${NC_ADMIN}"
NC_PASS="${NC_PASS}"
NC_TRUSTED_DOMAIN="${NC_TRUSTED_DOMAIN}"

MATRIX_DOMAIN="${MATRIX_DOMAIN}"
MATRIX_PUBLIC_BASEURL="${MATRIX_PUBLIC_BASEURL}"
MATRIX_MACAROON_SECRET="${MATRIX_MACAROON_SECRET}"
MATRIX_FORM_SECRET="${MATRIX_FORM_SECRET}"
MATRIX_REGISTRATION_SHARED_SECRET="${MATRIX_REGISTRATION_SHARED_SECRET}"

MUMBLE_SERVER_NAME="${MUMBLE_SERVER_NAME}"
MUMBLE_SUPERUSER_PASS="${MUMBLE_PASS}"
MUMBLE_SERVER_PASS="${MUMBLE_SERVER_PASS}"

LDAP_BASE_DN="${LDAP_BASE_DN}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS}"
LLDAP_JWT_SECRET="${LLDAP_JWT_SECRET}"

AUTHELIA_JWT_SECRET="${AUTHELIA_JWT_SECRET}"
AUTHELIA_SESSION_SECRET="${AUTHELIA_SESSION_SECRET}"
AUTHELIA_STORAGE_ENCRYPTION_KEY="${AUTHELIA_STORAGE_ENCRYPTION_KEY}"
AUTHELIA_OIDC_HMAC_SECRET="${AUTHELIA_OIDC_HMAC_SECRET}"
NEXTCLOUD_OIDC_SECRET="${NEXTCLOUD_OIDC_SECRET}"

VPN_HOST="${VPN_HOST}"
VPN_PORT="${VPN_PORT}"
VPN_PROTO=udp
VPN_SUBNET="${VPN_SUBNET}"
VPN_MASK=255.255.255.0

COLLABORA_ADMIN_USER=admin
COLLABORA_ADMIN_PASS="${COLLABORA_ADMIN_PASS}"

LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

TAK_DOMAIN="${TAK_DOMAIN}"
TAK_CERT_PASS="${CERT_PASS}"
TAK_IMAGE=takserver/takserver:5.3-RELEASE-35

CERT_COUNTRY="${CERT_COUNTRY}"
CERT_STATE="${CERT_STATE}"
CERT_CITY="${CERT_CITY}"
CERT_ORG="${CERT_ORG}"
CERT_UNIT="${CERT_UNIT}"
EOF
sed -i 's/\r//' "$DATA_DIR/.env"
chmod 600 "$DATA_DIR/.env"
# Symlink in server/ damit docker compose das .env automatisch findet
ln -sfn "$DATA_DIR/.env" "$KOMMS_DIR/server/.env"
ok ".env written to $DATA_DIR/.env (mode 600, symlink in server/)"

# ── [6] Server setup ──────────────────────────────────────────────────────────
step "[6/8] Running server setup"
bash "$KOMMS_DIR/server/setup_server.sh"

# ── [7] TAKServer ─────────────────────────────────────────────────────────────
step "[7/8] TAKServer"
if [[ "$SETUP_TAK" == "true" ]]; then
    bash "$KOMMS_DIR/server/setup_tak.sh"
else
    if [[ "$TAK_AVAILABLE" == "false" ]]; then
        warn "TAKServer not available on ARM64."
    else
        warn "TAKServer skipped. To set it up later:"
        info "  1. Place TAKSERVER-DOCKER-*.zip in $KOMMS_DIR/tak-release/"
        info "  2. Run: bash $KOMMS_DIR/server/setup_tak.sh"
    fi
fi

# ── [8/8] Health check ────────────────────────────────────────────────────────
step "[8/8] Health check"
cd "$KOMMS_DIR/server"

_chk() {
    local name="$1" url="$2"
    if curl -sk --max-time 10 "$url" >/dev/null 2>&1; then
        ok "$name"
    else
        warn "$name — not responding yet (may still be starting up)"
    fi
}
_chk_port() {
    local name="$1" host="$2" port="$3"
    if timeout 5 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then
        ok "$name"
    else
        warn "$name — port ${port} not reachable yet"
    fi
}

docker compose exec -T postgres pg_isready -U "${DB_USER}" >/dev/null 2>&1 \
    && ok "PostgreSQL" || warn "PostgreSQL — not ready"

_chk "LLDAP" "http://127.0.0.1:17170/health"

if [[ "$DEPLOY_MODE" == "vps" ]]; then
    _chk "Headwind MDM"  "https://mdm.${DOMAIN}/rest/public/auth/options"
    _chk "Nextcloud"     "https://cloud.${DOMAIN}/status.php"
    _chk "Matrix"        "https://matrix.${DOMAIN}/_matrix/client/versions"
    _chk "Element Web"   "https://element.${DOMAIN}/"
else
    _chk "Headwind MDM"  "https://${DOMAIN}/mdm/rest/public/auth/options"
    _chk "Nextcloud"     "https://${DOMAIN}/nextcloud/status.php"
    _chk "Matrix"        "https://${DOMAIN}/_matrix/client/versions"
    _chk "Element Web"   "https://${DOMAIN}:8080/"
fi

_chk_port "Mumble" "${DOMAIN}" 64738
[[ "$SETUP_TAK" == "true" ]] && _chk "TAKServer" "https://${DOMAIN}:8443"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
cat << 'DONE_BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║              KOMMS installation complete!               ║
  ╚══════════════════════════════════════════════════════════╝
DONE_BANNER
echo -e "${NC}"

echo -e "  ${BOLD}${YELLOW}─── Service Logins ────────────────────────────────${NC}"
echo ""
printf "  %-18s %-44s %s\n" "Service" "URL" "Login"
printf "  %-18s %-44s %s\n" "──────────────────" "────────────────────────────────────────────" "────────────────────────────────"

if [[ "$DEPLOY_MODE" == "vps" ]]; then
    printf "  %-18s %-44s %s\n" "Headwind MDM"  "https://mdm.${DOMAIN}"        "${HMDM_ADMIN_EMAIL}  /  ${HMDM_ADMIN_PASS}"
    printf "  %-18s %-44s %s\n" "Nextcloud"     "https://cloud.${DOMAIN}"      "${NC_ADMIN}  /  ${NC_PASS}"
    printf "  %-18s %-44s %s\n" "Element Web"   "https://element.${DOMAIN}"    "via LLDAP credentials"
    printf "  %-18s %-44s %s\n" "Matrix"        "https://matrix.${DOMAIN}"     "(Element / ATAK / Android app)"
    printf "  %-18s %-44s %s\n" "LLDAP Admin"   "https://ldap.${DOMAIN}"       "admin  /  ${LDAP_ADMIN_PASS}"
    printf "  %-18s %-44s %s\n" "Mumble"        "${DOMAIN}:64738"              "SuperUser  /  ${MUMBLE_PASS}"
    [[ "$SETUP_TAK" == "true" ]] && \
    printf "  %-18s %-44s %s\n" "TAKServer"     "https://${DOMAIN}:8443"       "cert-based (see add_user.sh)"
else
    printf "  %-18s %-44s %s\n" "Headwind MDM"  "https://${DOMAIN}/mdm"        "${HMDM_ADMIN_EMAIL}  /  ${HMDM_ADMIN_PASS}"
    printf "  %-18s %-44s %s\n" "Nextcloud"     "https://${DOMAIN}/nextcloud"  "${NC_ADMIN}  /  ${NC_PASS}"
    printf "  %-18s %-44s %s\n" "Element Web"   "https://${DOMAIN}:8080"       "via LLDAP credentials"
    printf "  %-18s %-44s %s\n" "Matrix"        "https://${DOMAIN}/_matrix"    "(Element / ATAK / Android app)"
    printf "  %-18s %-44s %s\n" "LLDAP Admin"   "https://${DOMAIN}/ldap"       "admin  /  ${LDAP_ADMIN_PASS}"
    printf "  %-18s %-44s %s\n" "Mumble"        "${DOMAIN}:64738"              "SuperUser  /  ${MUMBLE_PASS}"
    [[ "$SETUP_TAK" == "true" ]] && \
    printf "  %-18s %-44s %s\n" "TAKServer"     "https://${DOMAIN}:8443"       "cert-based (see add_user.sh)"
fi

echo ""
echo -e "  ${BOLD}${YELLOW}─── Operator Account ───────────────────────────────${NC}"
echo ""
info "Creating your operator (admin) account — generates .ovpn, TAK cert, and uploads files to Nextcloud."
info "The operator is added to lldap_admin group and gets access to MDM, LLDAP, and TAK WebUI."
OPERATOR_USER=$(prompt "Operator username" "operator")
OPERATOR_NAME=$(prompt "Operator display name" "Operator")
echo ""
bash "$KOMMS_DIR/server/add_user.sh" --admin "$OPERATOR_USER" "$OPERATOR_NAME"

echo ""
echo -e "  ${BOLD}${YELLOW}─── Operator VPN Profile ───────────────────────────${NC}"
echo ""
echo -e "  Your .ovpn is at:"
echo -e "  ${CYAN}${DATA_DIR}/users/${OPERATOR_USER}/${OPERATOR_USER}.ovpn${NC}"
echo ""
echo -e "  Copy it to your local machine:"
echo -e "  ${CYAN}scp root@$(curl -sf4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):${DATA_DIR}/users/${OPERATOR_USER}/${OPERATOR_USER}.ovpn .${NC}"
echo ""
echo -e "  Or download from Nextcloud after login: ${CYAN}https://cloud.${DOMAIN}${NC}"

echo ""
echo -e "  ${BOLD}${YELLOW}─── Operations ────────────────────────────────────${NC}"
echo ""
echo -e "  Add user:        ${CYAN}sudo bash $KOMMS_DIR/server/add_user.sh <name> [Display Name]${NC}"
echo -e "  Service status:  ${CYAN}cd $KOMMS_DIR/server && docker compose ps${NC}"
echo -e "  Data directory:  ${CYAN}$DATA_DIR/${NC}  (configs, users, tak — survives git pull)"
echo -e "  Logs:            ${CYAN}docker compose logs -f <service>${NC}"
echo ""
if [[ "$DEPLOY_MODE" == "lan" ]]; then
    echo -e "  ${YELLOW}Note:${NC} LAN mode uses a self-signed certificate. Import ${CYAN}${DOMAIN}/nginx/certs/komms.crt${NC}"
    echo -e "  into your device's trust store to avoid browser warnings."
fi
echo ""
