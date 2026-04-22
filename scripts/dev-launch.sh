#!/bin/zsh
# Build + ad-hoc sign + launch the Debug Socket.app for manual testing.
#
# Ad-hoc signing requires stripping developer-team entitlements (aps-environment,
# authentication-services, web-browser public-key-credential) — AMFI rejects a
# launch (exit 137) if an ad-hoc-signed binary claims those without a cert.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build"
APP="$DERIVED/Build/Products/Debug/Socket.app"
ENTITLEMENTS_SRC="$ROOT/Socket/Socket.entitlements"
ENTITLEMENTS_TMP="$(mktemp -t socket-entitlements).plist"

echo "→ Killing any running dev Socket ($APP)…"
# Only kill the dev build, never the installed /Applications one.
pkill -f "$APP/Contents/MacOS/Socket" 2>/dev/null || true

echo "→ Building Debug (arm64, unsigned)…"
xcodebuild \
  -project Socket.xcodeproj \
  -scheme Socket \
  -configuration Debug \
  -arch arm64 \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet \
  | tail -20

if [[ ! -d "$APP" ]]; then
  echo "✘ Build did not produce $APP"
  exit 1
fi

echo "→ Preparing ad-hoc entitlements (stripping developer-team keys)…"
# Keep the sandbox-safe keys, drop anything requiring a team-signed cert.
# Also add cs.disable-library-validation so the hardened runtime allows loading
# ad-hoc-signed nested dylibs (Library Validation treats each ad-hoc signature
# as a different "team", rejecting @rpath/Socket.debug.dylib on launch).
plutil -convert xml1 -o "$ENTITLEMENTS_TMP" "$ENTITLEMENTS_SRC"
for key in \
  com.apple.developer.aps-environment \
  com.apple.developer.authentication-services.autofill-credential-provider \
  com.apple.developer.web-browser.public-key-credential; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$ENTITLEMENTS_TMP" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS_TMP" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :com.apple.security.cs.disable-library-validation true" "$ENTITLEMENTS_TMP"

echo "→ Ad-hoc signing nested binaries first (inside-out)…"
# Sign every nested .dylib / .framework / .app / XPC / bundle explicitly, then
# the outer app. `--deep` alone can leave nested dylibs with stale signatures.
while IFS= read -r -d '' nested; do
  codesign --force --sign - --timestamp=none "$nested" 2>/dev/null || true
done < <(find "$APP" \
  \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.bundle" -o -name "*.app" \) \
  ! -path "$APP" \
  -print0)

echo "→ Ad-hoc signing Socket.app (outer, with library-validation disabled)…"
codesign --force --sign - \
  --entitlements "$ENTITLEMENTS_TMP" \
  "$APP"

rm -f "$ENTITLEMENTS_TMP"

echo "→ Launching $APP"
open -n "$APP"
echo "✓ Launched. Dev logs: tail -f ~/Library/Logs/DiagnosticReports/Socket*.ips (if it crashes)"
