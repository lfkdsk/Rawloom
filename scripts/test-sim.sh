#!/usr/bin/env bash
#
# test-sim.sh — run the Rawloom test suite on an iOS Simulator.
#
# The pipeline's GPU stages (Metal compute) and the AVFoundation-free parts of the app can be
# exercised on the Simulator: on Apple Silicon the Simulator provides a real Metal device, and
# XCTest runs there. This is our primary correctness gate (`swift test` on a Command-Line-Tools
# host has no XCTest; the Simulator does).
#
# It does NOT require `xcode-select`-ing Xcode or sudo: we point at Xcode.app via DEVELOPER_DIR.
#
# Usage:
#   scripts/test-sim.sh                 # default device (iPhone 17), runs all tests
#   SIM_NAME="iPhone 17 Pro" scripts/test-sim.sh
#   scripts/test-sim.sh -only RawloomCoreTests/PipelineGPUTests
#
set -euo pipefail

# --- locate Xcode (full toolchain) without touching the global xcode-select --------------------
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "error: full Xcode not found at DEVELOPER_DIR=$DEVELOPER_DIR" >&2
  echo "       install Xcode.app or set DEVELOPER_DIR to your Xcode's Developer dir." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="${SCHEME:-Rawloom}"
SIM_NAME="${SIM_NAME:-iPhone 17}"
RESULT_BUNDLE="${RESULT_BUNDLE:-$ROOT/.build/sim-tests.xcresult}"

# Optional: pass through `-only-testing` filters, e.g. `-only RawloomCoreTests/PipelineGPUTests`.
ONLY_ARGS=()
if [[ "${1:-}" == "-only" && -n "${2:-}" ]]; then
  ONLY_ARGS=(-only-testing "$2")
fi

# --- pick a concrete, available simulator -------------------------------------------------------
# Prefer the requested name; fall back to the first available iPhone if it's missing.
pick_device() {
  local want="$1"
  local line
  line="$(xcrun simctl list devices available | grep -F "$want (" | head -1 || true)"
  if [[ -z "$line" ]]; then
    echo "note: '$want' not available; falling back to first available iPhone." >&2
    line="$(xcrun simctl list devices available | grep -E 'iPhone .*\(' | head -1 || true)"
  fi
  # Extract the UDID in parentheses.
  echo "$line" | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/'
}

UDID="$(pick_device "$SIM_NAME")"
if [[ -z "$UDID" ]]; then
  echo "error: no available iPhone simulators found." >&2
  exit 2
fi
echo "▸ Simulator: $SIM_NAME  ($UDID)"
echo "▸ Scheme:    $SCHEME"
echo "▸ DEVELOPER_DIR=$DEVELOPER_DIR"

rm -rf "$RESULT_BUNDLE"

# The generated app project (Rawloom.xcodeproj, gitignored) shadows the SwiftPM package's auto
# scheme, so `xcodebuild` would resolve the app project instead of the package. Stash it for the
# duration of the package test and always restore it (trap covers interrupts).
STASH=""
restore_project() { if [[ -n "$STASH" && -d "$STASH" ]]; then mv "$STASH" "$ROOT/Rawloom.xcodeproj"; fi; }
trap restore_project EXIT
if [[ -d "$ROOT/Rawloom.xcodeproj" ]]; then
  STASH="$ROOT/.build/.Rawloom.xcodeproj.stashed"
  rm -rf "$STASH"; mkdir -p "$ROOT/.build"
  mv "$ROOT/Rawloom.xcodeproj" "$STASH"
fi

set +e
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -quiet \
  ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"}
XC_EXIT=$?
set -e

# --- summarise results from the result bundle ---------------------------------------------------
echo
echo "================ Simulator test summary ================"
if [[ -d "$RESULT_BUNDLE" ]]; then
  /usr/bin/python3 "$ROOT/scripts/summarize-xcresult.py" "$RESULT_BUNDLE" || true
fi
echo "  bundle : $RESULT_BUNDLE"
echo "========================================================"

exit $XC_EXIT
