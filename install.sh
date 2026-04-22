#!/usr/bin/env bash
# Socket Browser installer — downloads the latest DMG, drops Socket.app into
# /Applications, strips macOS quarantine attrs so Gatekeeper doesn't block
# first-launch, then opens the app.
#
# Usage:
#   # Stable (default):
#   /bin/bash -c "$(curl -fsSL https://harshach.github.io/Socket/install.sh)"
#
#   # Nightly:
#   SOCKET_CHANNEL=nightly /bin/bash -c "$(curl -fsSL https://harshach.github.io/Socket/install.sh)"
#
# Why this exists: Socket builds are ad-hoc signed (not Developer-ID
# notarized), so a browser-downloaded DMG carries `com.apple.quarantine`
# plus, on macOS 15+, `com.apple.provenance`. Gatekeeper refuses to launch
# either way. A curl|bash install avoids the browser altogether — the
# script itself isn't quarantined, and it clears attrs from the DMG
# contents before copying Socket.app to /Applications.

set -euo pipefail

REPO="harshach/Socket"
APP_NAME="Socket"
CHANNEL="${SOCKET_CHANNEL:-stable}"

log()  { printf "\033[1;34m[socket-install]\033[0m %s\n" "$*" >&2; }
fail() { printf "\033[1;31m[socket-install] ERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# ---- Resolve latest release for the channel --------------------------------

case "$CHANNEL" in
  stable)
    # /releases/latest excludes pre-releases automatically.
    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      || fail "Could not fetch latest stable release from GitHub")
    ;;
  nightly)
    # Pick the newest release flagged `prerelease: true`. The first item of
    # /releases is the most recently-published.
    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases" \
      | /usr/bin/python3 -c 'import sys, json
data = json.load(sys.stdin)
for rel in data:
    if rel.get("prerelease"):
        print(json.dumps(rel))
        break' || fail "Could not find a nightly pre-release")
    [ -n "$RELEASE_JSON" ] || fail "No nightly pre-release published yet"
    ;;
  *)
    fail "SOCKET_CHANNEL must be 'stable' or 'nightly' (got: $CHANNEL)"
    ;;
esac

TAG=$(printf '%s' "$RELEASE_JSON" | /usr/bin/python3 -c 'import sys, json; print(json.load(sys.stdin)["tag_name"])')
DMG_URL=$(printf '%s' "$RELEASE_JSON" | /usr/bin/python3 -c '
import sys, json
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    if asset.get("name", "").endswith(".dmg"):
        print(asset["browser_download_url"])
        break
')
[ -n "${DMG_URL:-}" ] || fail "No .dmg asset attached to release ${TAG}"

log "Installing Socket ${TAG} (${CHANNEL}) from ${DMG_URL}"

# ---- Download + mount + copy -----------------------------------------------

TMPDIR=$(mktemp -d /tmp/socket-install.XXXXXX)
MOUNT_POINT=""
cleanup() {
  if [ -n "${MOUNT_POINT:-}" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

DMG_PATH="$TMPDIR/Socket.dmg"
log "Downloading DMG…"
curl -fSL --progress-bar "$DMG_URL" -o "$DMG_PATH"

log "Mounting DMG…"
MOUNT_POINT=$(mktemp -d /tmp/socket-mount.XXXXXX)
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" -quiet

SRC="$MOUNT_POINT/${APP_NAME}.app"
[ -d "$SRC" ] || fail "Mounted DMG has no ${APP_NAME}.app at $SRC"

DEST="/Applications/${APP_NAME}.app"
if [ -d "$DEST" ]; then
  log "Removing existing $DEST"
  # /Applications is user-writable by default on single-user Macs. Fall back
  # to sudo if rm complains so we don't silently fail midway.
  rm -rf "$DEST" 2>/dev/null || sudo rm -rf "$DEST"
fi

log "Copying to $DEST"
cp -R "$SRC" "$DEST" 2>/dev/null || sudo cp -R "$SRC" "$DEST"

# ---- Strip Gatekeeper attrs ------------------------------------------------

log "Clearing extended attributes so Gatekeeper doesn't block launch"
xattr -cr "$DEST" 2>/dev/null || sudo xattr -cr "$DEST"

# ---- Done — hand off to the user ------------------------------------------

log "Launching ${APP_NAME}…"
open "$DEST"

log "Installed Socket ${TAG}. Future updates come in-app via Sparkle."
