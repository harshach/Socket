#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Socket.xcodeproj"
SCHEME_NAME="Socket"
DERIVED_DATA_PATH="$ROOT_DIR/DerivedData/Socket"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Socket.app"
SHIELDS_MANIFEST="$ROOT_DIR/Support/ShieldsCompiler/Cargo.toml"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Missing vendored Socket project at $PROJECT_PATH" >&2
  exit 1
fi

echo "Using vendored Socket as the primary browser base."

if [[ -f "$SHIELDS_MANIFEST" ]] && command -v cargo >/dev/null 2>&1; then
  echo "Building Shields compiler..."
  if ! cargo build --manifest-path "$SHIELDS_MANIFEST" --release >/tmp/socket-shields-build.log 2>&1; then
    echo "Warning: Shields compiler build failed, continuing with built-in fallback rules."
    echo "Shields build log: /tmp/socket-shields-build.log"
  fi
fi

if xcodebuild -list -project "$PROJECT_PATH" >/dev/null 2>&1; then
  echo "Building $SCHEME_NAME..."

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build >/tmp/socket-build.log 2>&1 || {
      echo "Socket build failed. Opening the Xcode project instead."
      echo "Build log: /tmp/socket-build.log"
      open "$PROJECT_PATH"
      exit 1
    }

  if [[ ! -d "$APP_PATH" ]]; then
    echo "Expected app bundle not found at $APP_PATH" >&2
    echo "Opening the Xcode project instead."
    open "$PROJECT_PATH"
    exit 1
  fi

  pkill -x Socket >/dev/null 2>&1 || true
  open -na "$APP_PATH"
  osascript -e 'tell application "Socket" to activate' >/dev/null 2>&1 || true
else
  echo "xcodebuild is not ready on this machine. Opening the Xcode project instead."
  echo "If needed, run: xcodebuild -runFirstLaunch"
  open "$PROJECT_PATH"
fi
