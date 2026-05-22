#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – TAKServer Setup
#
#  Extracts the TAKServer Docker zip from tak-release/, loads the image,
#  patches CoreConfig.xml, generates certificates, and initialises the DB.
#
#  Called by install.sh, or run standalone:
#    sudo bash /opt/komms/server/setup_tak.sh
#
#  Prerequisites:
#    · KOMMS already installed (docker compose stack up, .env populated)
#    · TAKSERVER-DOCKER-*.zip placed in /opt/komms-data/tak-release/
#      (download from https://tak.gov/products/tak-server – free account required)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOMMS_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$SCRIPT_DIR/.env"
TAK_CFG_DIR="$SCRIPT_DIR/takserver"   # template source (repo)

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}▶  $*${NC}"; }

# ── Root + .env ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash setup_tak.sh"
[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"
# shellcheck source=/dev/null
set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a

DATA_DIR="${DATA_DIR:-/opt/komms-data}"
TAK_RELEASE_DIR="$DATA_DIR/tak-release"

DOMAIN="${DOMAIN:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
DB_USER="${DB_USER:-komms}"
DB_PASS="${DB_PASS:?DB_PASS not set in .env}"
TAK_CERT_PASS="${TAK_CERT_PASS:-atakatak}"
CERT_COUNTRY="${CERT_COUNTRY:-DE}"
CERT_STATE="${CERT_STATE:-Bayern}"
CERT_CITY="${CERT_CITY:-Berlin}"
CERT_ORG="${CERT_ORG:-KOMMS}"
CERT_UNIT="${CERT_UNIT:-Ops}"

echo ""
echo -e "${BOLD}${BLUE}  KOMMS – TAKServer Setup${NC}"
echo ""
info "Release dir: $TAK_RELEASE_DIR"
info "Domain:      $DOMAIN"
info "DB user:     $DB_USER"

# ── [1] Find zip ──────────────────────────────────────────────────────────────
step "[1/5] Locating TAKServer release"

shopt -s nullglob
TAK_ZIPS=("$TAK_RELEASE_DIR"/*.zip)
shopt -u nullglob

if [[ ${#TAK_ZIPS[@]} -eq 0 ]]; then
    err "No TAKServer zip found in $TAK_RELEASE_DIR/\n\n  1. Create a free account at https://tak.gov\n  2. Download the TAKSERVER-DOCKER-*.zip release\n  3. Place it in $TAK_RELEASE_DIR/\n  4. Re-run: sudo bash $SCRIPT_DIR/setup_tak.sh"
fi

TAK_ZIP="${TAK_ZIPS[0]}"
ok "Found: $(basename "$TAK_ZIP")"

# ── [2] Extract zip ───────────────────────────────────────────────────────────
step "[2/5] Extracting TAKServer release"
TMP_EXTRACT=$(mktemp -d)
trap 'rm -rf "$TMP_EXTRACT"' EXIT

unzip -q "$TAK_ZIP" -d "$TMP_EXTRACT"
ok "Zip extracted"

# Derive version tag from zip filename (e.g. takserver-docker-5.7-RELEASE-32.zip → 5.7-RELEASE-32)
TAK_VER=$(basename "$TAK_ZIP" .zip | grep -oP '[\d]+\.[\d]+-RELEASE-[\d]+' || \
          basename "$TAK_ZIP" .zip | sed 's/.*docker-//' | sed 's/\.zip//')

# ── [2b] Copy tak/ application files to persistent location ──────────────────
# TAKServer 5.7+ images have no files at /opt/tak — they expect a bind mount.
# The zip always has: <release-name>/tak/  as the top-level structure.
TAK_ZIP_ROOT=$(find "$TMP_EXTRACT" -maxdepth 1 -mindepth 1 -type d | head -1 || true)
TAK_APP_SRC="${TAK_ZIP_ROOT}/tak"
[[ -d "$TAK_APP_SRC" ]] || \
    err "Cannot find tak/ directory in zip (expected ${TAK_APP_SRC}).\nContents:\n$(find "$TMP_EXTRACT" -maxdepth 3 -type d | head -20)"
ok "Found TAK application files: $TAK_APP_SRC"

TAK_DIR="$DATA_DIR/tak"
if [[ ! -f "$TAK_DIR/takserver.war" ]]; then
    info "Copying TAK application files to $TAK_DIR ..."
    mkdir -p "$TAK_DIR"
    cp -a "$TAK_APP_SRC/." "$TAK_DIR/"
    touch "$TAK_DIR/.komms_initialized"
    ok "TAK application files copied to $TAK_DIR"
else
    ok "TAK application files already at $TAK_DIR"
fi
mkdir -p "$TAK_DIR/logs" "$TAK_DIR/certs/files"

# Write TAK_DIR to .env so docker-compose can bind-mount it
grep -q "^TAK_DIR=" "$ENV_FILE" && \
    sed -i "s|^TAK_DIR=.*|TAK_DIR=\"$TAK_DIR\"|" "$ENV_FILE" || \
    echo "TAK_DIR=\"$TAK_DIR\"" >> "$ENV_FILE"
info "TAK_DIR → $TAK_DIR"

# ── [3] Load or build Docker image ───────────────────────────────────────────
step "[3/5] Loading TAKServer Docker image"

# Check if image already loaded
TAK_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -i "takserver" | grep -v "db" | head -1 || true)

if [[ -n "$TAK_IMAGE" ]]; then
    ok "Image already present: $TAK_IMAGE"
else
    # Try pre-built tar first (older releases)
    TAK_IMG_FILE=$(find "$TMP_EXTRACT" -name "*.tar.gz" -o -name "takserver*.tar" 2>/dev/null | head -1 || true)
    [[ -z "$TAK_IMG_FILE" ]] && TAK_IMG_FILE=$(find "$TMP_EXTRACT" -type f -name "*.tar" | head -1 || true)

    if [[ -n "$TAK_IMG_FILE" ]]; then
        info "Loading image from tar (may take 1–2 min)..."
        docker load -i "$TAK_IMG_FILE"
        TAK_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -i "takserver" | grep -v "db" | head -1 || true)
        ok "Image loaded: $TAK_IMAGE"
    else
        # New format (5.7+): build from Dockerfiles
        TAK_DOCKERFILE=$(find "$TMP_EXTRACT" -name "Dockerfile.takserver" ! -name "*-db" | head -1 || true)
        [[ -z "$TAK_DOCKERFILE" ]] && \
            err "Cannot find Docker image tar or Dockerfile.takserver in zip.\nContents:\n$(find "$TMP_EXTRACT" -type f | head -20)"

        TAK_BUILD_CTX=$(dirname "$TAK_DOCKERFILE")
        # Build context needs the tak/ directory alongside docker/
        TAK_BUILD_ROOT=$(dirname "$TAK_BUILD_CTX")

        info "Building TAKServer image from Dockerfile (may take 5–10 min)..."
        TAK_IMAGE="takserver/takserver:${TAK_VER}"
        docker build \
            -t "$TAK_IMAGE" \
            -f "$TAK_DOCKERFILE" \
            "$TAK_BUILD_ROOT" 2>&1 | tail -5
        ok "Image built: $TAK_IMAGE"
    fi
fi

# Update TAK_IMAGE in .env
sed -i "s|^TAK_IMAGE=.*|TAK_IMAGE=${TAK_IMAGE}|" "$ENV_FILE"
info "Updated TAK_IMAGE in .env → $TAK_IMAGE"

# ── [4] Patch CoreConfig.xml ──────────────────────────────────────────────────
step "[4/5] Configuring TAKServer"
mkdir -p "$DATA_DIR/config/takserver"
CORE_CFG_TPL="$TAK_CFG_DIR/CoreConfig.xml"       # template stays in repo
CORE_CFG="$DATA_DIR/config/takserver/CoreConfig.xml"  # generated, bind-mounted
[[ -f "$CORE_CFG_TPL" ]] || err "CoreConfig.xml template not found at $CORE_CFG_TPL"

LDAP_BASE_DN_VAL="${LDAP_BASE_DN:-dc=komms,dc=local}"
LDAP_ADMIN_PASS_VAL="${LDAP_ADMIN_PASS:-}"

sed \
    -e "s|KOMMS_TAK_DB_USER|${DB_USER}|g" \
    -e "s|KOMMS_TAK_DB_PASS|${DB_PASS}|g" \
    -e "s|KOMMS_CERT_PASS|${TAK_CERT_PASS}|g" \
    -e "s|KOMMS_SERVER_HOST|${DOMAIN}|g" \
    -e "s|KOMMS_LDAP_ADMIN_PASS|${LDAP_ADMIN_PASS_VAL}|g" \
    -e "s|KOMMS_LDAP_BASE_DN|${LDAP_BASE_DN_VAL}|g" \
    "$CORE_CFG_TPL" > "$CORE_CFG"
ok "CoreConfig.xml generated → $DATA_DIR/config/takserver/"

# Write cert-metadata.sh to the bind-mount path so cert scripts pick it up
cat > "${TAK_DIR}/certs/cert-metadata.sh" << EOF
COUNTRY=${CERT_COUNTRY}
STATE=${CERT_STATE}
CITY=${CERT_CITY}
ORGANIZATION=${CERT_ORG}
ORGANIZATIONAL_UNIT=${CERT_UNIT}
CAPASS=${TAK_CERT_PASS}
PASS=${TAK_CERT_PASS}
DIR=files

SUBJBASE="/C=\${COUNTRY}/"
[ -n "\${STATE}" ]             && SUBJBASE+="ST=\${STATE}/" || true
[ -n "\${CITY}" ]              && SUBJBASE+="L=\${CITY}/"  || true
[ -n "\${ORGANIZATION}" ]      && SUBJBASE+="O=\${ORGANIZATION}/" || true
[ -n "\${ORGANIZATIONAL_UNIT}" ] && SUBJBASE+="OU=\${ORGANIZATIONAL_UNIT}/" || true
EOF
chmod +x "${TAK_DIR}/certs/cert-metadata.sh"
ok "cert-metadata.sh written to TAK certs dir"

# ── [5] Generate certificates + init DB ───────────────────────────────────────
step "[5/5] Certificates + database initialisation"
cd "$SCRIPT_DIR"

# Make sure postgres is healthy before proceeding
info "Waiting for PostgreSQL to be ready..."
TRIES=0
until docker compose exec -T postgres pg_isready -U "$DB_USER" &>/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    [[ $TRIES -ge 30 ]] && err "PostgreSQL did not become ready in time."
    sleep 2
done
ok "PostgreSQL ready"

# Ensure the tak database exists (init-dbs.sh runs on first start, may already exist)
docker compose exec -T postgres psql -U "$DB_USER" -d postgres -tc \
    "SELECT 1 FROM pg_database WHERE datname='tak'" 2>/dev/null | grep -q 1 || \
    docker compose exec -T postgres psql -U "$DB_USER" -d postgres \
        -c "CREATE DATABASE tak; GRANT ALL PRIVILEGES ON DATABASE tak TO ${DB_USER};" \
        >/dev/null 2>&1 || true

# Pull up takserver now that the image is loaded
docker compose up -d takserver
info "TAKServer container started — waiting for it to be ready..."
sleep 15

# Generate Root CA + server certificate + admin client cert (skip if already done)
if [[ -f "${TAK_DIR}/certs/files/ca.pem" ]]; then
    ok "TAKServer certificates already exist — skipping generation"
else
    info "Generating TAKServer Root CA, server certificate, and admin client cert..."
    docker compose exec -T takserver bash -c "
        set -e
        cd /opt/tak/certs
        ./makeRootCa.sh --ca-name KOMMSca 2>&1
        ./makeCert.sh server takserver 2>&1
        ./makeCert.sh client admin 2>&1
        echo 'Certificates generated successfully.'
    " || err "Certificate generation failed — check: docker compose logs takserver"
    # Produce admin-browser.p12 for browser import.
    # TAKServer cert format depends on the Java version in the container:
    #   - Java 8/11 (older images): RC2/3DES PKCS12 — already browser-compatible, just copy
    #   - Java 17+ (newer images):  PBES2/AES-256-CBC — browsers reject it; re-export needed
    # Detect by whether host OpenSSL 3.x can decode admin.p12:
    #   success → PBES2 format (re-export with AES-256-CBC to avoid legacy provider)
    #   failure → RC2 format   (already compatible, copy as-is)
    _TMP_PEM=$(mktemp)
    if openssl pkcs12 \
        -in  "${TAK_DIR}/certs/files/admin.p12" \
        -passin "pass:${TAK_CERT_PASS}" \
        -nodes -out "$_TMP_PEM" 2>/dev/null; then
        # PBES2/AES-256-CBC (Java 17+): re-export with explicit modern algorithms
        if openssl pkcs12 -export \
            -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg SHA256 \
            -in "$_TMP_PEM" \
            -out "${TAK_DIR}/certs/files/admin-browser.p12" \
            -passout "pass:${TAK_CERT_PASS}" 2>/dev/null; then
            ok "admin-browser.p12 created (AES-256-CBC, Firefox 75+ / Chrome 68+)"
        else
            cp "${TAK_DIR}/certs/files/admin.p12" "${TAK_DIR}/certs/files/admin-browser.p12"
            ok "admin-browser.p12 created (copied admin.p12)"
        fi
    else
        # RC2/3DES (Java 8/11): already the format browsers prefer, copy directly
        cp "${TAK_DIR}/certs/files/admin.p12" "${TAK_DIR}/certs/files/admin-browser.p12"
        ok "admin-browser.p12 created (RC2/legacy format, universally browser-compatible)"
    fi
    rm -f "$_TMP_PEM"
    ok "TAKServer certificates generated"
fi

# Enable PostGIS in the tak database (required by TAKServer, CASCADE handles deps)
info "Enabling PostGIS extension in tak database..."
docker compose exec -T postgres psql -U "$DB_USER" -d tak \
    -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;" >/dev/null 2>&1 || true

# Initialise / upgrade DB schema
# Pass connection args explicitly — SchemaManager defaults to 127.0.0.1 if not given
info "Initialising TAKServer database schema..."
_DB_URL="jdbc:postgresql://postgres:5432/tak"
docker compose exec -T takserver bash -c "
    set -e
    cd /opt/tak/db-utils
    echo 'Creating initial schema...'
    java -jar SchemaManager.jar -url '${_DB_URL}' -user '${DB_USER}' -password '${DB_PASS}' SetupGenericDatabase
    echo 'Upgrading schema...'
    java -jar SchemaManager.jar -url '${_DB_URL}' -user '${DB_USER}' -password '${DB_PASS}' upgrade
" || err "DB schema initialisation failed — check: docker compose logs takserver"

ok "Database schema ready"

# Re-patch CoreConfig.xml after TAK 5.7 rewrites it into its canonical format.
# SchemaManager (and takserver.war on first boot) normalize the XML via JAXB,
# dropping attributes it doesn't recognize and using TAK 5.7 element/attribute names
# that differ from TAK 4.x. This patch applies the required corrections:
#   · auth/ldap:  TAK 5.7 uses userstring/serviceAccountCredential (not userDN/password)
#   · security:   TLS requires keymanager="SunX509" (not keyManagerType)
#   · connector:  port 8443 needs clientAuth="WANT" (Spring Boot enum; requests cert, doesn't require it)
#   · federation: add <federation-server> with TLS if TAK hasn't already added it
info "Patching CoreConfig.xml for TAK 5.7 attribute names..."
_PAT=$(mktemp --suffix=.py)
cat > "$_PAT" << 'PYEOF'
import sys, re

cfg, cpw, lbase, lpw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
txt = open(cfg).read()

# 1. Replace entire auth block with correct TAK 5.7 LDAP format.
#    SchemaManager strips userstring/serviceAccountCredential because the input
#    used old-format attribute names; this restores them with the correct names.
new_auth = (
    '<auth default="ldap" x509groups="true" x509addAnonymous="false">'
    '<ldap url="ldap://lldap:3890"'
    ' userstring="uid=%s,ou=people,' + lbase + '"'
    ' serviceAccountDN="uid=admin,ou=people,' + lbase + '"'
    ' serviceAccountCredential="' + lpw + '"'
    ' style="DS"'
    ' groupObjectClass="groupOfUniqueNames"'
    ' userBaseRDN="ou=people,' + lbase + '"'
    ' groupBaseRDN="ou=groups,' + lbase + '"/>'
    '<File/>'
    '</auth>'
)
txt = re.sub(r'<auth[^>]*>.*?</auth>', new_auth, txt, flags=re.DOTALL)

# 2. Add keymanager="SunX509" to <security><tls> if missing.
#    Required by SubmissionService to create a KeyManagerFactory for port 8089.
def add_keymanager(m):
    s = m.group(0)
    if 'keymanager=' not in s:
        s = s.replace('/>\n    </security>', ' keymanager="SunX509"/>\n    </security>')
    return s
txt = re.sub(r'<security>\s*<tls[^>]*/>\s*</security>', add_keymanager, txt, flags=re.DOTALL)

# 3. Set clientAuth="NONE" on port 8443 (WebTAK / admin UI) connector.
#    Spring Boot maps this to Ssl.ClientAuth enum — valid values: NEED, NONE, WANT.
#    Without this, Tomcat requires a client certificate from browsers/nginx (→ 502).
def fix_8443_client_auth(m):
    s = m.group(0)
    if 'clientAuth=' not in s:
        s = s.replace('<connector port="8443"', '<connector port="8443" clientAuth="WANT"', 1)
    else:
        s = re.sub(r'clientAuth="(?!WANT|NEED)[^"]*"', 'clientAuth="WANT"', s)
    return s
txt = re.sub(r'<connector port="8443"[^/]*/>', fix_8443_client_auth, txt)

# 4. Add <federation-server> inside <federation> if takserver.war hasn't done it yet.
#    DistributedFederationManager.init() unconditionally calls getFederationServer().getTls()
#    which NPEs if the element is absent, even when federation is disabled.
if '<federation-server' not in txt:
    fed_server = (
        '<federation-server port="9000">'
        '<tls keystore="JKS" keystoreFile="/opt/tak/certs/files/takserver.jks" keystorePass="' + cpw + '"'
        ' truststore="JKS" truststoreFile="/opt/tak/certs/files/fed-truststore.jks" truststorePass="' + cpw + '"'
        ' context="TLSv1.3" keymanager="SunX509"/>'
        '</federation-server>'
    )
    txt = re.sub(r'(<federation[^>]*>)', r'\g<1>' + fed_server, txt, count=1)

open(cfg, 'w').write(txt)
PYEOF
python3 "$_PAT" \
    "$CORE_CFG" \
    "$TAK_CERT_PASS" \
    "${LDAP_BASE_DN:-dc=komms,dc=local}" \
    "${LDAP_ADMIN_PASS:-}" \
    && ok "CoreConfig.xml patched (TAK 5.7 LDAP + TLS + clientAuth)" \
    || warn "CoreConfig.xml patch failed — WebTAK auth may not work"
rm -f "$_PAT"

# Restart TAKServer so it picks up the new certs + schema
docker compose restart takserver
ok "TAKServer restarted"

# Restart dnsmasq so it picks up TAKServer's Docker IP and applies DNAT rules
docker compose restart dnsmasq 2>/dev/null && ok "dnsmasq restarted (TAK DNAT rules active)" || true

# Grant ROLE_ADMIN to the admin client certificate.
# certmod connects via Apache Ignite — wait for TCP port first, then allow
# extra time for the Ignite grid to fully initialize before running certmod.
if [[ -f "${TAK_DIR}/certs/files/admin.pem" ]]; then
    info "Waiting for TAKServer port 8443 to open..."
    _TAK_TRIES=0
    until bash -c "echo > /dev/tcp/localhost/8443" 2>/dev/null; do
        _TAK_TRIES=$((_TAK_TRIES + 1))
        if [[ $_TAK_TRIES -ge 60 ]]; then
            warn "TAKServer not ready after 5 min — certmod skipped, run manually later"
            break
        fi
        sleep 5
    done
    if [[ $_TAK_TRIES -lt 60 ]]; then
        info "Port open — waiting 60s for Ignite grid to initialize..."
        sleep 60
        _CERTMOD_OK=false
        for _attempt in 1 2 3; do
            if docker compose exec -T takserver bash -c \
                'cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/admin.pem 2>&1' \
                | grep -qE "Username|Role|Fingerprint|successfully"; then
                ok "admin certificate granted ROLE_ADMIN"
                _CERTMOD_OK=true
                break
            fi
            [[ $_attempt -lt 3 ]] && { info "certmod attempt $_attempt failed, retrying in 30s..."; sleep 30; }
        done
        [[ "$_CERTMOD_OK" == "false" ]] && \
            warn "certmod failed after 3 attempts — run manually: docker compose exec takserver bash -c 'cd /opt/tak && java -jar utils/UserManager.jar certmod -A certs/files/admin.pem'"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}  ✔  TAKServer setup complete!${NC}"
echo ""
echo -e "  ${YELLOW}Access URLs:${NC}"
echo -e "  WebTAK / Marti:    ${CYAN}https://tak.${DOMAIN}${NC}  (VPN + Authelia — recommended)"
echo -e "  ATAK client port:  ${CYAN}${DOMAIN}:8089 (TLS)${NC}"
echo -e "  Cert enrollment:   ${CYAN}https://${DOMAIN}:8444${NC}"
echo -e "  ${YELLOW}Note:${NC} Do NOT open https://${DOMAIN}:8443 directly in a browser."
echo -e "       The TAKServer cert is issued for CN=takserver (not ${DOMAIN})."
echo -e "       Browsers block it with HSTS and no exception can be added."
echo ""
echo -e "  ${YELLOW}Browser setup (one-time, on your local machine):${NC}"
echo -e "  ${CYAN}scp root@${DOMAIN}:${TAK_DIR}/certs/files/ca.pem             ~/Downloads/tak-ca.pem${NC}"
echo -e "  ${CYAN}scp root@${DOMAIN}:${TAK_DIR}/certs/files/admin-browser.p12 ~/Downloads/admin-browser.p12${NC}"
echo ""
echo -e "  The admin browser cert is only needed for native TAK clients (ATAK/WinTAK),"
echo -e "  not for the web UI. Access the web UI via ${CYAN}https://tak.${DOMAIN}${NC} (VPN + Authelia)."
echo ""
