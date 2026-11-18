#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SHOT_DIR=${SCREENSHOT_DIR:-"$PWD/screenshots/round3-preview"}
mkdir -p "$SHOT_DIR"
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/BirdCM.app
# Deterministic Debug-only presentation states; all fixture photos are CC0.
for state in home normal multiple uncertain genus rare unknown-prior no-location no-bird loading; do
  xcrun simctl terminate booted cc.outman.birdcm 2>/dev/null || true
  xcrun simctl launch booted cc.outman.birdcm -previewState "$state" -previewImage "$PWD/Tests/Fixtures/photo-0.jpg"
  sleep 2
  xcrun simctl io booted screenshot "$SHOT_DIR/$state.png"
done
