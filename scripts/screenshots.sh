#!/usr/bin/env bash
#
# screenshots.sh — build the app, run it on the Simulator, and capture screenshots of the camera UI
# and a processed result (driven by the app's `-autoshoot` launch argument, which fires the shutter
# on appear so the synthetic capture → pipeline → display path is shown).
#
set -euo pipefail
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SIM_NAME="${SIM_NAME:-iPhone 17}"
BUNDLE_ID="com.rawloom.app"
DD="$ROOT/.build/app-dd"
OUT="${OUT:-$ROOT/.build/screenshots}"
mkdir -p "$OUT"

# Ensure project + app build exist.
[[ -d "$ROOT/Rawloom.xcodeproj" ]] || xcodegen generate
APP="$(/usr/bin/find "$DD/Build/Products" -maxdepth 3 -name 'RawloomApp.app' 2>/dev/null | head -1 || true)"
if [[ -z "$APP" ]]; then
  echo "▸ Building app…"
  xcodebuild build -scheme RawloomApp -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$DD" -quiet
  APP="$(/usr/bin/find "$DD/Build/Products" -maxdepth 3 -name 'RawloomApp.app' | head -1)"
fi
echo "▸ App: $APP"

# Boot the simulator.
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_NAME" || true

# Install and launch with -autoshoot so a processed result is on screen for the capture.
xcrun simctl install "$SIM_NAME" "$APP"
xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID" -autoshoot >/dev/null

# Give the pipeline a moment to run, then grab the screen.
sleep 4
xcrun simctl io "$SIM_NAME" screenshot "$OUT/result.png"
echo "▸ Screenshot → $OUT/result.png"
