#!/system/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Android Device Provisioner
#
#  Pushed and executed by Headwind MDM after QR enrollment.
#  Runs with Device Owner privileges (no root required).
#
#  What this script does:
#    1. Debloat (remove Google/OEM bloatware)
#    2. Configure device restrictions (lock down Play Store etc.)
#    3. Apply system settings (timezone, NTP, display)
#    4. Set up OpenVPN profile (pushed as file by MDM)
# ─────────────────────────────────────────────────────────────────────────────

log()  { echo "[KOMMS provisioner] $1"; }
step() { echo ""; echo "[KOMMS provisioner] ── $1 ──"; }

# ─────────────────────────────────────────────────────────────────────────────
step "1/4  Debloat"
# ─────────────────────────────────────────────────────────────────────────────

PM="pm uninstall -k --user 0"

# Google Apps
$PM com.google.android.gm              || true
$PM com.google.android.apps.maps       || true
$PM com.google.android.youtube         || true
$PM com.google.android.apps.photos     || true
$PM com.google.android.apps.docs       || true
$PM com.google.android.apps.sheets     || true
$PM com.google.android.apps.slides     || true
$PM com.google.android.music           || true
$PM com.google.android.videos          || true
$PM com.google.android.calendar        || true
$PM com.google.android.keep            || true
$PM com.google.android.apps.translate  || true
$PM com.google.android.apps.walletnfcrel || true
$PM com.google.android.play.games      || true
$PM com.google.android.apps.tachyon    || true
$PM com.google.android.apps.googleassistant || true
$PM com.google.android.feedback        || true
$PM com.google.android.googlequicksearchbox || true

# Play Store (UI disabled, framework stays)
$PM com.android.vending || true

# Samsung bloat (safe to fail on non-Samsung)
$PM com.samsung.android.bixby.agent    || true
$PM com.samsung.android.bixby.wakeup   || true
$PM com.samsung.android.app.spage      || true
$PM com.samsung.android.game.gamehome  || true

log "Debloat done"

# ─────────────────────────────────────────────────────────────────────────────
step "2/4  Device restrictions"
# ─────────────────────────────────────────────────────────────────────────────
# These settings-based restrictions are primarily configured via the
# Headwind MDM policy JSON (see headwind/policy.json).
# Shell fallbacks for direct setting commands:

# Disable unknown sources (sideloading outside MDM)
settings put global install_non_market_apps 0

# Disable developer options and USB debugging
settings put global development_settings_enabled 0
settings put global adb_enabled 0

# Disable safe mode (prevent user from booting into it)
# Note: hardware-enforced, MDM policy handles this

# Screen timeout: 5 minutes (300000 ms)
settings put system screen_off_timeout 300000

# Disable location sharing (can be re-enabled per app if needed)
settings put secure location_mode 0

# Disable airplane mode toggle for users
settings put global airplane_mode_on 0

log "Device restrictions applied"

# ─────────────────────────────────────────────────────────────────────────────
step "3/4  System settings"
# ─────────────────────────────────────────────────────────────────────────────

# Timezone (adjust to your operation area)
setprop persist.sys.timezone "Europe/Berlin"

# Disable automatic date/time from network (use internal NTP via VPN instead)
settings put global auto_time 0
settings put global auto_time_zone 0

# Brightness: auto
settings put system screen_brightness_mode 1

# Keep WiFi on during sleep
settings put global wifi_sleep_policy 2

log "System settings applied"

# ─────────────────────────────────────────────────────────────────────────────
step "4/4  OpenVPN auto-connect"
# ─────────────────────────────────────────────────────────────────────────────
# The .ovpn profile is pushed as a managed file by Headwind MDM
# to /sdcard/Download/komms.ovpn
#
# OpenVPN for Android supports importing profiles via intent:
#   am start -a android.intent.action.VIEW \
#     -d file:///sdcard/Download/komms.ovpn \
#     -t application/x-openvpn-profile
#
# This opens the OpenVPN import dialog automatically.

OVPN_FILE="/sdcard/Download/komms.ovpn"

if [ -f "$OVPN_FILE" ]; then
    am start -a android.intent.action.VIEW \
        -d "file://${OVPN_FILE}" \
        -t "application/x-openvpn-profile" \
        --activity-brought-to-front 2>/dev/null || true
    log "OpenVPN profile import triggered"
else
    log "komms.ovpn not yet on device — MDM file push may still be in progress"
fi

# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Provisioning complete!"
log "Device is ready. Check Headwind MDM dashboard for confirmation."
