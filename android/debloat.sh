#!/system/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
#  KOMMS – Android ADB Debloat Script
#
#  Runs with Device Owner privileges via Headwind MDM shell command push.
#  Removes Google/OEM bloatware while preserving GMS core (needed for ATAK).
#
#  DO NOT remove: com.google.android.gms, com.google.android.gsf
#  These are required by many apps including ATAK plugins.
# ─────────────────────────────────────────────────────────────────────────────

PM="pm uninstall -k --user 0"
log() { echo "[KOMMS debloat] $*"; }

log "Starting debloat..."

# ── Google Apps ───────────────────────────────────────────────────────────────
$PM com.google.android.gm              || true  # Gmail
$PM com.google.android.apps.maps       || true  # Maps
$PM com.google.android.youtube         || true  # YouTube
$PM com.google.android.apps.photos     || true  # Photos
$PM com.google.android.apps.docs       || true  # Docs
$PM com.google.android.apps.sheets     || true  # Sheets
$PM com.google.android.apps.slides     || true  # Slides
$PM com.google.android.apps.magazines  || true  # News/Newsstand
$PM com.google.android.music           || true  # Music (legacy)
$PM com.google.android.videos          || true  # Play Movies
$PM com.google.android.calendar        || true  # Calendar
$PM com.google.android.keep            || true  # Keep Notes
$PM com.google.android.apps.translate  || true  # Translate
$PM com.google.android.apps.walletnfcrel || true  # Google Pay / Wallet
$PM com.google.android.play.games      || true  # Play Games
$PM com.google.android.apps.tachyon    || true  # Google Meet (Duo)
$PM com.google.android.talk            || true  # Hangouts (legacy)
$PM com.google.android.apps.googleassistant || true  # Assistant
$PM com.google.android.marvin.talkback || true  # TalkBack (accessibility)
$PM com.google.android.feedback        || true  # Google Feedback
$PM com.google.android.apps.restore    || true  # Backup & Restore
$PM com.google.android.apps.classroom  || true  # Classroom

# ── Play Store ────────────────────────────────────────────────────────────────
# Disables Play Store UI but keeps underlying framework
$PM com.android.vending || true

# ── Google Search / Quick Search Box ─────────────────────────────────────────
$PM com.google.android.googlequicksearchbox || true

# ── Chrome (optional — uncomment if browser not needed on device) ─────────────
# $PM com.android.chrome || true

# ── Samsung / OEM bloat ───────────────────────────────────────────────────────
$PM com.samsung.android.app.tips             || true
$PM com.samsung.android.bixby.agent         || true
$PM com.samsung.android.bixby.wakeup        || true
$PM com.samsung.android.app.spage           || true  # Samsung Free
$PM com.samsung.android.game.gamehome       || true  # Game Launcher
$PM com.samsung.android.kidsinstaller       || true
$PM com.samsung.android.app.galaxy4friend   || true
$PM com.samsung.android.ardrawing           || true
$PM com.samsung.android.arzone              || true

# ── GMS core – DO NOT REMOVE ─────────────────────────────────────────────────
# com.google.android.gms      → required for app compatibility + ATAK plugins
# com.google.android.gsf      → required for app compatibility
# com.google.android.gsfcore  → required for app compatibility

log "Debloat complete."
