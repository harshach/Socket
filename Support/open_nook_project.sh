#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Nook.xcodeproj"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Nook project not found at $PROJECT_PATH" >&2
  exit 1
fi

open "$PROJECT_PATH"
