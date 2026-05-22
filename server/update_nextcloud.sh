#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Nextcloud Major Version Update
#
#  Updates Nextcloud one major version at a time (e.g. 30 → 31).
#  Nextcloud only supports single-step major upgrades.
#
#  Usage:
#    sudo bash /opt/komms/server/update_nextcloud.sh            # auto: current+1
#    sudo bash /opt/komms/server/update_nextcloud.sh 31         # explicit target
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
err()  { echo -e "${RED}  ✗  $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}▶  $*${NC}"; }

[[ $EUID -ne 0 ]]    && err "Run as root: sudo bash update_nextcloud.sh [target_version]"
[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"

set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a
cd "$SCRIPT_DIR"

# ── Detect current version from running container ─────────────────────────────
CURRENT_VERSION=$(docker compose exec -T -u www-data nextcloud php occ status --output=json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('versionstring',''))" 2>/dev/null || echo "")
[[ -z "$CURRENT_VERSION" ]] && err "Nextcloud container is not running or occ status failed."
CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)

TARGET_MAJOR="${1:-$((CURRENT_MAJOR + 1))}"
DIFF=$((TARGET_MAJOR - CURRENT_MAJOR))

echo ""
echo -e "${BOLD}${BLUE}  KOMMS – Nextcloud Update${NC}"
echo -e "  ${CURRENT_MAJOR} → ${TARGET_MAJOR}"
echo ""

[[ "$CURRENT_MAJOR" -eq "$TARGET_MAJOR" ]] && { ok "Already on Nextcloud $CURRENT_MAJOR — nothing to do."; exit 0; }
[[ "$DIFF" -ne 1 ]] && err "Nextcloud only supports single-step major upgrades. Current: $CURRENT_MAJOR, Target: $TARGET_MAJOR (diff: $DIFF)"
[[ "$TARGET_MAJOR" -lt "$CURRENT_MAJOR" ]] && err "Downgrade not supported."

# ── [1] Update image tag in docker-compose.yml ───────────────────────────────
step "[1/4] Updating image tag: nextcloud:${CURRENT_MAJOR}-apache → nextcloud:${TARGET_MAJOR}-apache"
sed -i "s|nextcloud:${CURRENT_MAJOR}-apache|nextcloud:${TARGET_MAJOR}-apache|" "$COMPOSE_FILE"
ok "docker-compose.yml updated"

# ── [2] Pull new image + restart container ────────────────────────────────────
step "[2/4] Pulling nextcloud:${TARGET_MAJOR}-apache"
docker compose pull nextcloud
ok "Image pulled"

info "Restarting Nextcloud container with new image..."
docker compose up -d --no-deps nextcloud
ok "Container restarted"

# ── [3] Wait for Nextcloud + run upgrade ──────────────────────────────────────
step "[3/4] Running upgrade"
info "Waiting for Nextcloud to initialize (up to 3 min)..."
TRIES=0
until docker compose exec -T -u www-data nextcloud php occ status --output=json 2>/dev/null \
        | grep -q '"installed":true'; do
    TRIES=$((TRIES + 1))
    [[ $TRIES -ge 36 ]] && err "Nextcloud did not start after 3 min. Check: docker compose logs nextcloud"
    printf "."
    sleep 5
done
echo ""
ok "Nextcloud is running"

docker compose exec -T -u www-data nextcloud php occ upgrade
ok "occ upgrade complete"

# Wait for entrypoint initialization to fully complete (file writes finish)
info "Waiting for container to stabilize (30s)..."
sleep 30

docker compose exec -T -u www-data nextcloud php occ db:add-missing-indices   2>/dev/null || true
docker compose exec -T -u www-data nextcloud php occ db:add-missing-columns   2>/dev/null || true
docker compose exec -T -u www-data nextcloud php occ db:convert-filecache-bigint 2>/dev/null || true
ok "Post-upgrade DB tasks done"

# ── [4] Verify maintenance mode is off ────────────────────────────────────────
step "[4/4] Verifying maintenance mode is off"
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --off 2>/dev/null || true
ok "Maintenance mode disabled"

echo ""
echo -e "${GREEN}${BOLD}  ✔  Nextcloud updated: ${CURRENT_MAJOR} → ${TARGET_MAJOR}${NC}"
echo ""
echo -e "  ${YELLOW}Next step:${NC} Update nextcloud image tag in git and push."
echo -e "    ${CYAN}git add server/docker-compose.yml${NC}"
echo -e "    ${CYAN}git commit -m \"chore: update Nextcloud ${CURRENT_MAJOR} to ${TARGET_MAJOR}\"${NC}"
echo ""
