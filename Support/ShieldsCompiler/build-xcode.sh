#!/usr/bin/env bash
#
# build-xcode.sh — Build the shields_compiler static library for the
# architectures Xcode is building, and lipo them into a universal .a
# under Support/ShieldsCompiler/target/universal/release/.
#
# Intended to be invoked from an Xcode Run Script build phase with these
# input/output files so incremental builds stay cheap:
#
#   Inputs:
#     $(SRCROOT)/Support/ShieldsCompiler/Cargo.toml
#     $(SRCROOT)/Support/ShieldsCompiler/Cargo.lock
#     $(SRCROOT)/Support/ShieldsCompiler/src/lib.rs
#     $(SRCROOT)/Support/ShieldsCompiler/src/main.rs
#   Outputs:
#     $(SRCROOT)/Support/ShieldsCompiler/target/universal/release/libshields_compiler.a
#
# Xcode sets $ARCHS (e.g. "arm64" or "arm64 x86_64") and $CONFIGURATION
# (Debug/Release). We only build release staticlibs regardless of Xcode
# config because debug-mode Rust builds are 100+ MB of symbols we don't
# need.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Locate cargo. Xcode's environment drops typical shell PATH additions, so
# check the known install locations and error out clearly when missing.
if [ -z "${CARGO:-}" ]; then
  if command -v cargo >/dev/null 2>&1; then
    CARGO="$(command -v cargo)"
  elif [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO="$HOME/.cargo/bin/cargo"
  elif [ -x "/opt/homebrew/bin/cargo" ]; then
    CARGO="/opt/homebrew/bin/cargo"
  else
    echo "error: cargo not found. Install with rustup (https://rustup.rs) and re-run build." >&2
    echo "       Or set CARGO=/path/to/cargo before building." >&2
    exit 1
  fi
fi

# Determine which architectures to build. Default to both when invoked
# outside Xcode so `./build-xcode.sh` from the terminal produces a
# universal binary.
ARCHS="${ARCHS:-arm64 x86_64}"

RUST_TARGETS=()
for arch in $ARCHS; do
  case "$arch" in
    arm64)  RUST_TARGETS+=("aarch64-apple-darwin") ;;
    x86_64) RUST_TARGETS+=("x86_64-apple-darwin") ;;
    *)
      echo "warning: ignoring unknown arch '$arch'" >&2
      ;;
  esac
done

if [ ${#RUST_TARGETS[@]} -eq 0 ]; then
  echo "error: no supported architectures in ARCHS='$ARCHS'" >&2
  exit 1
fi

# Build each target. `cargo build` caches via target/ so repeat runs are
# fast when sources haven't changed.
for target in "${RUST_TARGETS[@]}"; do
  echo "building shields_compiler for $target..."
  "$CARGO" build --release --target "$target" --lib
done

# Assemble the universal .a via lipo.
UNIVERSAL_DIR="target/universal/release"
mkdir -p "$UNIVERSAL_DIR"
UNIVERSAL_OUT="$UNIVERSAL_DIR/libshields_compiler.a"

INPUTS=()
for target in "${RUST_TARGETS[@]}"; do
  INPUTS+=("target/$target/release/libshields_compiler.a")
done

if [ ${#INPUTS[@]} -eq 1 ]; then
  # Single arch: cp is cheaper than lipo -create.
  cp "${INPUTS[0]}" "$UNIVERSAL_OUT"
else
  lipo -create -output "$UNIVERSAL_OUT" "${INPUTS[@]}"
fi

echo "universal staticlib at $UNIVERSAL_OUT"
lipo -info "$UNIVERSAL_OUT" >&2
