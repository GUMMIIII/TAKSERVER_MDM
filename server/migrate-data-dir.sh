#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Data Directory Migration
#
#  Migrates an existing installation from the old layout (everything in
#  /opt/komms/) to the new layout (code in /opt/komms/, data in /opt/komms-data/).
#
#  Safe to run on a live server — no services are restarted (the stack reads
#  the new paths from the updated .env after the next restart).
#
#  Usage (on the server as root):
#    sudo bash /opt/komms/server/migrate-data-dir.sh
#
#  What it does:
#    1. Creates /opt/komms-data/ with the expected directory structure
#    2. Moves generated configs (nginx.conf, authelia/*, matrix/homeserver.yaml,
#       element/config.json, dnsmasq.conf, mumble/murmur.ini, CoreConfig.xml)
#    3. Moves persistent TAK files (/opt/komms/tak/)
#    4. Moves user files (/opt/komms/users/)
#    5. Moves .env to data dir and replaces original with a symlink
#    6. Adds DATA_DIR= to .env so docker-compose picks it up
#
#  After running: do a full restart of the stack so new bind-mounts take effect:
#    cd /opt/komms/server && docker compose down && docker compose up -d
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOMMS_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$SCRIPT_DIR/.env"
DATA_DIR="/opt/komms-data"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}▶  $*${NC}"; }

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash migrate-data-dir.sh"

echo ""
echo -e "${BOLD}${BLUE}  KOMMS – Data Directory Migration${NC}"
echo ""
echo -e "  Source: ${CYAN}${KOMMS_DIR}/${NC}"
echo -e "  Target: ${CYAN}${DATA_DIR}/${NC}"
echo ""

# Already migrated?
if [[ -L "$ENV_FILE" ]]; then
    ok "Migration already done (.env is already a symlink) — nothing to do."
    exit 0
fi

[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE — is KOMMS installed?"

# ── [1] Create data directory structure ──────────────────────────────────────
step "[1/6] Creating $DATA_DIR structure"
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
ok "Directory structure created"

# Helper: move a file only if the source exists and destination does not
move_if_exists() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]] && [[ ! -f "$dst" ]]; then
        mv "$src" "$dst"
        ok "Moved: $src → $dst"
    elif [[ -f "$src" ]] && [[ -f "$dst" ]]; then
        warn "Both exist — keeping data dir copy, removing old: $src"
        rm -f "$src"
    elif [[ ! -f "$src" ]]; then
        info "Not found (skipping): $src"
    fi
}

# Helper: move a directory if source exists and destination is empty
move_dir_if_exists() {
    local src="$1" dst="$2"
    if [[ -d "$src" ]] && [[ ! -d "$dst" ]]; then
        mv "$src" "$dst"
        ok "Moved: $src/ → $dst/"
    elif [[ -d "$src" ]] && [[ -d "$dst" ]]; then
        warn "Both exist — merging $src/ into $dst/ (rsync cp, no overwrite)"
        cp -rn "$src/." "$dst/" 2>/dev/null || true
        rm -rf "$src"
        ok "Merged: $src/ → $dst/"
    fi
}

# ── [2] Move generated service configs ───────────────────────────────────────
step "[2/6] Moving generated service configs"

# nginx
move_if_exists "$SCRIPT_DIR/nginx/nginx.conf" "$DATA_DIR/config/nginx/nginx.conf"
if [[ -d "$SCRIPT_DIR/nginx/certs" ]]; then
    cp -rn "$SCRIPT_DIR/nginx/certs/." "$DATA_DIR/config/nginx/certs/" 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/nginx/certs"
    ok "Moved: nginx/certs/ → $DATA_DIR/config/nginx/certs/"
fi

# authelia
move_if_exists "$SCRIPT_DIR/authelia/configuration.yml" "$DATA_DIR/config/authelia/configuration.yml"
move_if_exists "$SCRIPT_DIR/authelia/oidc-provider.yml"  "$DATA_DIR/config/authelia/oidc-provider.yml"
move_if_exists "$SCRIPT_DIR/authelia/oidc.pem"           "$DATA_DIR/config/authelia/oidc.pem"

# matrix
move_if_exists "$SCRIPT_DIR/matrix/homeserver.yaml.active" "$DATA_DIR/config/matrix/homeserver.yaml"
# If .active doesn't exist, try the in-place version (old installs processed it directly)
if [[ ! -f "$DATA_DIR/config/matrix/homeserver.yaml" ]]; then
    if [[ -f "$SCRIPT_DIR/matrix/homeserver.yaml" ]] && \
       ! grep -q '\${' "$SCRIPT_DIR/matrix/homeserver.yaml" 2>/dev/null; then
        # Already-processed (no placeholders) — safe to move as generated file
        cp "$SCRIPT_DIR/matrix/homeserver.yaml" "$DATA_DIR/config/matrix/homeserver.yaml"
        info "Copied processed homeserver.yaml → data dir (template will be re-generated on next setup run)"
    fi
fi

# element
move_if_exists "$SCRIPT_DIR/element/config.json" "$DATA_DIR/config/element/config.json"

# dnsmasq
move_if_exists "$SCRIPT_DIR/dnsmasq/dnsmasq.conf" "$DATA_DIR/config/dnsmasq/dnsmasq.conf"

# mumble
move_if_exists "$SCRIPT_DIR/mumble/murmur.ini" "$DATA_DIR/config/mumble/murmur.ini"

# takserver CoreConfig (generated/active copy — the template stays in repo)
if [[ -f "$SCRIPT_DIR/takserver/CoreConfig.xml" ]] && \
   ! grep -q 'KOMMS_TAK_DB_USER' "$SCRIPT_DIR/takserver/CoreConfig.xml" 2>/dev/null; then
    move_if_exists "$SCRIPT_DIR/takserver/CoreConfig.xml" "$DATA_DIR/config/takserver/CoreConfig.xml"
fi

# ── [3] Move TAK application files ───────────────────────────────────────────
step "[3/6] Moving TAK application files"
move_dir_if_exists "$KOMMS_DIR/tak" "$DATA_DIR/tak"
move_dir_if_exists "$KOMMS_DIR/tak-release" "$DATA_DIR/tak-release"

# ── [4] Move user files ───────────────────────────────────────────────────────
step "[4/6] Moving user files"
move_dir_if_exists "$KOMMS_DIR/users" "$DATA_DIR/users"
# Also handle the old path inside server/
move_dir_if_exists "$SCRIPT_DIR/users" "$DATA_DIR/users"

# ── [5] Update .env with DATA_DIR + new TAK paths ────────────────────────────
step "[5/6] Updating .env"

# Add DATA_DIR if missing
if ! grep -q "^DATA_DIR=" "$ENV_FILE"; then
    echo "DATA_DIR=\"${DATA_DIR}\"" >> "$ENV_FILE"
    ok "DATA_DIR added to .env"
fi

# Update TAK_DIR and TAK_RELEASE_DIR if they point to old paths
if grep -q "^TAK_DIR=" "$ENV_FILE"; then
    sed -i "s|^TAK_DIR=.*|TAK_DIR=\"${DATA_DIR}/tak\"|" "$ENV_FILE"
    ok "TAK_DIR updated → $DATA_DIR/tak"
fi
if grep -q "^TAK_RELEASE_DIR=" "$ENV_FILE"; then
    sed -i "s|^TAK_RELEASE_DIR=.*|TAK_RELEASE_DIR=\"${DATA_DIR}/tak-release\"|" "$ENV_FILE"
    ok "TAK_RELEASE_DIR updated"
fi

# ── [6] Move .env to data dir + create symlink ───────────────────────────────
step "[6/6] Moving .env to data dir and creating symlink"

cp "$ENV_FILE" "$DATA_DIR/.env"
chmod 600 "$DATA_DIR/.env"
rm -f "$ENV_FILE"
ln -sfn "$DATA_DIR/.env" "$ENV_FILE"
ok ".env → $DATA_DIR/.env (symlink at $ENV_FILE)"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ✔  Migration complete!${NC}"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Pull latest code:  ${CYAN}cd $KOMMS_DIR && git pull${NC}"
echo -e "  2. Restart the stack: ${CYAN}cd $SCRIPT_DIR && docker compose down && docker compose up -d${NC}"
echo -e "  3. Verify services:   ${CYAN}docker compose ps${NC}"
echo ""
echo -e "  ${YELLOW}Data is now at:${NC} ${CYAN}${DATA_DIR}/${NC}"
echo -e "  ${YELLOW}Code is at:${NC}     ${CYAN}${KOMMS_DIR}/${NC} (safe to git pull)"
echo ""
