#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Update
#
#  Updates the KOMMS installation to the latest release tag, main branch,
#  or a specific tag. Data in /opt/komms-data/ is never modified.
#
#  Usage:
#    sudo bash /opt/komms/server/update.sh            # latest release tag
#    sudo bash /opt/komms/server/update.sh main       # current main branch
#    sudo bash /opt/komms/server/update.sh v0.2.0     # specific tag
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

# ── Root + sanity checks ──────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]          && err "Run as root: sudo bash update.sh [target]"
[[ -d "$KOMMS_DIR/.git" ]] || err "Not a git repository: $KOMMS_DIR"
[[ -f "$ENV_FILE" ]]       || err ".env not found at $ENV_FILE — is KOMMS installed?"

# shellcheck source=/dev/null
set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a

DATA_DIR="${DATA_DIR:-/opt/komms-data}"
BACKUP_DIR="$DATA_DIR/backups"
mkdir -p "$BACKUP_DIR"

TARGET_INPUT="${1:-stable}"

echo ""
echo -e "${BOLD}${BLUE}  KOMMS – Update${NC}"
echo -e "  Target: ${CYAN}${TARGET_INPUT}${NC}"
echo ""

# ── [1] Current version ───────────────────────────────────────────────────────
step "[1/6] Current version"
cd "$KOMMS_DIR"

CURRENT_VERSION=$(git describe --tags --always 2>/dev/null || echo "unknown")
CURRENT_COMMIT=$(git rev-parse HEAD)
info "Installed: $CURRENT_VERSION  ($CURRENT_COMMIT)"

# ── [2] Fetch remote ──────────────────────────────────────────────────────────
step "[2/6] Fetching latest release info"
if git fetch --tags origin 2>/dev/null; then
    ok "Tags and refs fetched from origin"
else
    warn "Could not reach origin — continuing with locally cached refs."
fi

# ── [3] Resolve target ref ────────────────────────────────────────────────────
step "[3/6] Resolving target"

if [[ "$TARGET_INPUT" == "stable" ]]; then
    TARGET_REF=$(git tag -l 'v*' | sort -V | tail -1)
    [[ -z "$TARGET_REF" ]] && \
        err "No release tags found. Tag the repo first or pass 'main' explicitly."
    TARGET_TYPE="tag"
elif [[ "$TARGET_INPUT" == "main" ]]; then
    TARGET_REF="origin/main"
    TARGET_TYPE="branch"
else
    git rev-parse --verify "refs/tags/${TARGET_INPUT}" >/dev/null 2>&1 || \
    git rev-parse --verify "${TARGET_INPUT}"            >/dev/null 2>&1 || \
        err "Ref '$TARGET_INPUT' not found. Run: git fetch --tags origin"
    TARGET_REF="$TARGET_INPUT"
    TARGET_TYPE="tag"
fi

TARGET_COMMIT=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "")
info "Target:    $TARGET_REF  (${TARGET_COMMIT:0:10})"

if [[ "$CURRENT_COMMIT" == "$TARGET_COMMIT" ]]; then
    ok "Already on $TARGET_REF — nothing to do."
    exit 0
fi

# ── Migration notes (optional) ────────────────────────────────────────────────
MIGRATION_NOTE="$KOMMS_DIR/migrations/${TARGET_REF}.md"
if [[ -f "$MIGRATION_NOTE" ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}  !! Migration notes for ${TARGET_REF}:${NC}"
    echo "  ──────────────────────────────────────────────"
    sed 's/^/  /' "$MIGRATION_NOTE"
    echo "  ──────────────────────────────────────────────"
    echo ""
    read -r -p "  Read and understood? Continue with update? [y/N] " _MIG_CONFIRM < /dev/tty
    [[ "$_MIG_CONFIRM" =~ ^[Yy]$ ]] || err "Update aborted."
fi

# ── Uncommitted changes warning ───────────────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
    warn "Uncommitted local changes in $KOMMS_DIR will be overwritten."
    read -r -p "  Continue anyway? [y/N] " _DIRTY_CONFIRM < /dev/tty
    [[ "$_DIRTY_CONFIRM" =~ ^[Yy]$ ]] || err "Update aborted."
fi

# ── [4] Backup .env ───────────────────────────────────────────────────────────
step "[4/6] Backing up .env"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
BACKUP_FILE="$BACKUP_DIR/env-${CURRENT_VERSION}-${TIMESTAMP}.bak"
cp "$DATA_DIR/.env" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
ok "Backed up → $BACKUP_FILE"

# ── [5] Stop · Checkout · Pull · Start ───────────────────────────────────────
step "[5/6] Updating"
cd "$SCRIPT_DIR"

info "Stopping services (volumes preserved)..."
docker compose down
ok "Services stopped"

info "Checking out $TARGET_REF..."
cd "$KOMMS_DIR"
if [[ "$TARGET_TYPE" == "branch" ]]; then
    git checkout main 2>/dev/null || git checkout -b main --track origin/main
    git reset --hard origin/main
else
    git checkout "$TARGET_REF"
fi
NEW_VERSION=$(git describe --tags --always 2>/dev/null || echo "$TARGET_REF")
ok "Code at $NEW_VERSION"

# ── New .env variables check ──────────────────────────────────────────────────
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
if [[ -f "$ENV_EXAMPLE" ]]; then
    MISSING_VARS=$(comm -23 \
        <(grep -E '^[A-Z_][A-Z0-9_]*=' "$ENV_EXAMPLE" | cut -d= -f1 | sort) \
        <(grep -E '^[A-Z_][A-Z0-9_]*=' "$DATA_DIR/.env"  | cut -d= -f1 | sort) \
    )
    if [[ -n "$MISSING_VARS" ]]; then
        warn "New variables in .env.example are missing from your .env:"
        while IFS= read -r _v; do
            echo -e "    ${YELLOW}+${NC} $_v"
        done <<< "$MISSING_VARS"
        warn "Add them to $DATA_DIR/.env before starting, if needed."
    else
        ok ".env is complete (no missing variables)"
    fi
fi

info "Pulling updated Docker images..."
cd "$SCRIPT_DIR"
# --ignore-buildable skips synapse/dnsmasq (they build from local Dockerfiles).
# TAKServer's image is loaded by setup_tak.sh and is not on Docker Hub.
docker compose pull --ignore-buildable --quiet 2>/dev/null || true

info "Starting services..."
docker compose up -d --remove-orphans
ok "Services started"

# ── [6] Verify ────────────────────────────────────────────────────────────────
step "[6/6] Verifying"
info "Waiting 15 seconds for containers to initialize..."
sleep 15
docker compose ps --format 'table {{.Name}}\t{{.Status}}'

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}  ✔  Update complete!${NC}"
echo ""
echo -e "  ${YELLOW}Version:${NC}  ${CURRENT_VERSION}  →  ${NEW_VERSION}"
echo -e "  ${YELLOW}Backup:${NC}   ${BACKUP_FILE}"
echo ""
