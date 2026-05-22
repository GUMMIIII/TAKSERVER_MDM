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

# ── Detect current version ────────────────────────────────────────────────────
CURRENT_TAG=$(grep -E '^\s+image: nextcloud:' "$COMPOSE_FILE" | head -1 | sed 's/.*nextcloud:\([^-]*\).*/\1/')
[[ -z "$CURRENT_TAG" ]] && err "Could not detect current Nextcloud version from docker-compose.yml"
CURRENT_MAJOR="$CURRENT_TAG"

TARGET_MAJOR="${1:-$((CURRENT_MAJOR + 1))}"
DIFF=$((TARGET_MAJOR - CURRENT_MAJOR))

echo ""
echo -e "${BOLD}${BLUE}  KOMMS – Nextcloud Update${NC}"
echo -e "  ${CURRENT_MAJOR} → ${TARGET_MAJOR}"
echo ""

[[ "$CURRENT_MAJOR" -eq "$TARGET_MAJOR" ]] && { ok "Already on Nextcloud $CURRENT_MAJOR — nothing to do."; exit 0; }
[[ "$DIFF" -ne 1 ]] && err "Nextcloud only supports single-step major upgrades. Current: $CURRENT_MAJOR, Target: $TARGET_MAJOR (diff: $DIFF)"
[[ "$TARGET_MAJOR" -lt "$CURRENT_MAJOR" ]] && err "Downgrade not supported."

# ── [1] Maintenance mode on ───────────────────────────────────────────────────
step "[1/5] Enabling maintenance mode"
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --on
ok "Maintenance mode enabled"

# ── [2] Update image tag in docker-compose.yml ────────────────────────────────
step "[2/5] Updating image tag: nextcloud:${CURRENT_MAJOR}-apache → nextcloud:${TARGET_MAJOR}-apache"
sed -i "s|nextcloud:${CURRENT_MAJOR}-apache|nextcloud:${TARGET_MAJOR}-apache|" "$COMPOSE_FILE"
ok "docker-compose.yml updated"

# ── [3] Pull new image + restart container ────────────────────────────────────
step "[3/5] Pulling nextcloud:${TARGET_MAJOR}-apache"
docker compose pull nextcloud
ok "Image pulled"

info "Restarting Nextcloud container with new image..."
docker compose up -d --no-deps nextcloud
ok "Container restarted"

# ── [4] Wait for Nextcloud + run upgrade ──────────────────────────────────────
step "[4/5] Running upgrade"
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

docker compose exec -T -u www-data nextcloud php occ db:add-missing-indices   2>/dev/null || true
docker compose exec -T -u www-data nextcloud php occ db:add-missing-columns   2>/dev/null || true
docker compose exec -T -u www-data nextcloud php occ db:convert-filecache-bigint 2>/dev/null || true
ok "Post-upgrade DB tasks done"

# ── [5] Maintenance mode off ──────────────────────────────────────────────────
step "[5/5] Disabling maintenance mode"
docker compose exec -T -u www-data nextcloud php occ maintenance:mode --off
ok "Maintenance mode disabled"

echo ""
echo -e "${GREEN}${BOLD}  ✔  Nextcloud updated: ${CURRENT_MAJOR} → ${TARGET_MAJOR}${NC}"
echo ""
echo -e "  ${YELLOW}Next step:${NC} Update nextcloud image tag in git and push."
echo -e "    ${CYAN}git add server/docker-compose.yml${NC}"
echo -e "    ${CYAN}git commit -m \"chore: update Nextcloud ${CURRENT_MAJOR} to ${TARGET_MAJOR}\"${NC}"
echo ""
