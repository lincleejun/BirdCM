#!/bin/bash
# Requires the selected team's Apple ID in Xcode > Settings > Accounts.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == '--help' ]]; then
  echo 'Usage: TEAM_ID=3U353L39GB MODEL_SOURCE=/local/mobile/build RARITY_SOURCE=/local/rarity-global.sqlite tools/install_on_device.sh DEVICE_UDID [TEAM_ID]'
  echo 'Unlock and trust the device. Free teams require one-time trust in Settings > General > VPN & Device Management.'
  exit 0
fi
DEVICE_UDID="${1:?Supply the connected unlocked iPhone UDID}"
TEAM_ID="${2:-${TEAM_ID:-3U353L39GB}}"
"$IOS_DIR/tools/fetch_models.sh"
xcodebuild -project "$IOS_DIR/BirdCM.xcodeproj" -scheme BirdCM \
  -configuration Release -destination "id=$DEVICE_UDID" -derivedDataPath "$IOS_DIR/DerivedData-device" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
APP="$IOS_DIR/DerivedData-device/Build/Products/Release-iphoneos/BirdCM.app"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"
echo 'Installed. For a free Personal Team, trust the developer once under Settings > General > VPN & Device Management.'
