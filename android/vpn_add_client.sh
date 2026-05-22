#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Add OpenVPN Client
#  Generates a .ovpn profile for a new device/user.
#  Upload the generated file to Headwind MDM as a "managed file" pushed to
#  /sdcard/Download/komms.ovpn on the device.
#
#  Usage: bash vpn_add_client.sh <client-name>
#  Example: bash vpn_add_client.sh soldier01
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

CLIENT="${1:-}"
if [[ -z "$CLIENT" ]]; then
    echo "Usage: $0 <client-name>"
    echo "Example: $0 soldier01"
    exit 1
fi

KOMMS_DIR="/opt/komms"
OUT_DIR="$(dirname "$0")/vpn-clients"
mkdir -p "$OUT_DIR"

echo "Generating OpenVPN profile for: $CLIENT"

# Generate client certificate inside the OpenVPN container
docker compose -f "$KOMMS_DIR/docker-compose.yml" run --rm \
    -e EASYRSA_BATCH=1 \
    openvpn easyrsa build-client-full "$CLIENT" nopass

# Export the .ovpn profile
docker compose -f "$KOMMS_DIR/docker-compose.yml" run --rm \
    openvpn ovpn_getclient "$CLIENT" > "$OUT_DIR/${CLIENT}.ovpn"

echo ""
echo "  Profile saved: $OUT_DIR/${CLIENT}.ovpn"
echo ""
echo "  Next steps:"
echo "  1. Upload ${CLIENT}.ovpn to Headwind MDM as a 'Managed File'"
echo "  2. Set target path on device: /sdcard/Download/komms.ovpn"
echo "  3. Assign the file to the device configuration"
echo "  4. The provisioner.sh will auto-trigger the OpenVPN import dialog"
