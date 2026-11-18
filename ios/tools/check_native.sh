#!/bin/zsh
# Mac fallback uses the production Swift files. This does not substitute for iOS simulator/device tests.
set -eu
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEV="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
mkdir -p ios/build/LogicTests.xctest/Contents/MacOS
/usr/libexec/PlistBuddy -c 'Clear dict' ios/build/LogicTests.xctest/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Add CFBundleExecutable string LogicTests' ios/build/LogicTests.xctest/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Add CFBundleIdentifier string cc.outman.birdcm.nativechecks' ios/build/LogicTests.xctest/Contents/Info.plist
xcrun swiftc -emit-library -O -disable-sandbox -D NATIVE_CHECK -module-cache-path ios/build/ModuleCache \
  -I "$DEV/usr/lib" -L "$DEV/usr/lib" -F "$DEV/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Library/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  ios/BirdCM/{DisplayCrop,Engine,Pixels,Confirm,Geo,GeoNetwork,Place,Rarity,Diagnostics,Store}.swift ios/Tests/{LogicTests,DisplayCropTests}.swift \
  -o ios/build/LogicTests.xctest/Contents/MacOS/LogicTests
FIXTURES="$PWD/ios/Tests/Fixtures" RESOURCE_DIR="$PWD/ios/BirdCM/Resources" xcrun xctest ios/build/LogicTests.xctest
