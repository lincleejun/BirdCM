#!/bin/bash
# Build 观羽.app and macos/dist/观羽-<version>-arm64.dmg (Apple Silicon only).
# Needs on the build Mac: uv, npm (Node), swift (Command Line Tools are enough), network for the first build.
#   macos/build.sh                      ad-hoc signed (runs here; blocked by Gatekeeper elsewhere until notarized)
#   SIGN_ID="Developer ID Application: … (TEAMID)" macos/build.sh    signed for distribution (then notarize: README)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
M=$ROOT/macos
B=$M/build
APP="$B/dmg/观羽.app"
C=$APP/Contents
E=$C/Resources/engine
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' engine/pyproject.toml | head -1)
PY=3.12.11                                       # the dev venv's Python (python-build-standalone via uv)
EXIFTOOL=13.64
EXIFTOOL_SHA=dcb9f6be1f6705ee826a92d1522e3fec1d0b3749cdc061b03c46873d5fe204fc   # exiftool.org/checksums.txt
SIGN_ID=${SIGN_ID:--}
DMG="$M/dist/观羽-$VERSION-arm64.dmg"
step() { printf '\n== %s\n' "$*"; }

[ "$(uname -m)" = arm64 ] || { echo "build on Apple Silicon"; exit 1; }
rm -rf "$B"
mkdir -p "$C/MacOS" "$E" "$C/Resources/licenses" "$M/dist" "$M/.cache"

step "web UI"
(cd web && npm ci --no-audit --no-fund --loglevel=error && npm run build)
cp -R web/dist "$E/web"

step "Python $PY + locked dependencies"
uv python install "$PY"
PYHOME=$(dirname "$(dirname "$(uv python find --managed-python "$PY")")")
cp -R "$PYHOME" "$E/python"
rm -f "$E/python/lib/python3.12/EXTERNALLY-MANAGED"
(cd engine && uv export --frozen --no-dev --no-emit-project --no-hashes --quiet -o "$B/requirements.txt")
uv pip install --python "$E/python/bin/python3" --no-deps --quiet -r "$B/requirements.txt"
uv pip install --python "$E/python/bin/python3" --no-deps --quiet --reinstall-package birdcm ./engine
SP=$E/python/lib/python3.12/site-packages
# not needed at run time: C headers, pip, console scripts with build-machine shebangs, Tk
rm -rf "$SP/torch/include" "$SP"/pip "$SP"/pip-*.dist-info "$E/python/include" "$E/python/share" \
       "$E/python/lib/python3.12/idlelib" "$E/python/lib/python3.12/tkinter" "$E/python/lib"/tcl* "$E/python/lib"/tk* \
       "$E/python/lib"/itcl* "$E/python/lib"/thread*
find "$E/python/bin" -mindepth 1 ! -name 'python3*' -delete
find "$E/python" -name __pycache__ -prune -exec rm -rf {} +
"$E/python/bin/python3" -I -m compileall -q -j0 "$E/python/lib" > "$B/compileall.log" 2>&1 || true

step "exiftool $EXIFTOOL"
T="$M/.cache/Image-ExifTool-$EXIFTOOL.tar.gz"
[ -f "$T" ] || curl -fsSL -o "$T" "https://sourceforge.net/projects/exiftool/files/Image-ExifTool-$EXIFTOOL.tar.gz/download"
echo "$EXIFTOOL_SHA  $T" | shasum -a 256 -c - >/dev/null
tar -xzf "$T" -C "$B"
mkdir -p "$E/exiftool"
cp -R "$B/Image-ExifTool-$EXIFTOOL/exiftool" "$B/Image-ExifTool-$EXIFTOOL/lib" "$E/exiftool/"

step "menu-bar app, icon, bundle"
swift build -c release --package-path "$M" --arch arm64 -q
cp "$M/.build/arm64-apple-macosx/release/BirdCMMenu" "$C/MacOS/BirdCM"
swift "$M/tools/icon.swift" "$B/icon"
iconutil -c icns "$B/icon/AppIcon.iconset" -o "$C/Resources/AppIcon.icns"
cp "$B/icon/MenuIcon.png" "$B/icon/MenuIcon@2x.png" "$C/Resources/"
sed "s/__VERSION__/$VERSION/g" "$M/Info.plist" > "$C/Info.plist"
install -m 755 "$M/launcher.sh" "$E/birdcm"
cp models.toml "$E/models.toml"
mkdir -p "$E/data" && cp data/species-map.sqlite "$E/data/"     # online.py finds it next to the bundled python
L=$C/Resources/licenses
cp LICENSE "$L/BirdCM-LICENSE.txt"
cp NOTICE.md "$L/NOTICE.md"
cp "$E/python/lib/python3.12/LICENSE.txt" "$L/Python-LICENSE.txt"
# ExifTool: "same terms as Perl itself" = Artistic License or GPL; both texts from the system Perl's pods
POD=$(dirname "$(find /System/Library/Perl -name perlartistic.pod | head -1)")
{ echo "ExifTool $EXIFTOOL by Phil Harvey (https://exiftool.org), bundled unmodified in Resources/engine/exiftool."
  echo "\"This is free software; you can redistribute it and/or modify it under the same terms as Perl itself\":"
  echo "either the Artistic License (below) or the GNU General Public License, version 1 or later (ExifTool-GPL.pod)."
  echo; cat "$POD/perlartistic.pod"; } > "$L/ExifTool-LICENSE.txt"
cp "$POD/perlgpl.pod" "$L/ExifTool-GPL.pod"
cp "$B/Image-ExifTool-$EXIFTOOL/README" "$L/ExifTool-README.txt"
cp "$M/THIRD-PARTY.md" "$L/"

step "sign ($SIGN_ID)"
xattr -cr "$APP"
ENT=$M/entitlements.plist                # empty: Python/torch need no JIT or unsigned-memory exceptions
if [ "$SIGN_ID" = - ]; then
  # ad-hoc signatures carry no Team ID, so the hardened runtime's library validation would refuse libpython itself
  ENT=$B/entitlements-adhoc.plist
  cp "$M/entitlements.plist" "$ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENT"
fi
sign() { codesign -f -s "$SIGN_ID" -o runtime $([ "$SIGN_ID" = - ] || echo --timestamp) "$@"; }
# every Mach-O inside first (libraries, extension modules, the python executable), then the app itself
find "$C/Resources" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q Mach-O; then echo "$f"; fi
  done > "$B/macho.txt"
while IFS= read -r f; do sign --entitlements "$ENT" "$f" 2>/dev/null; done < "$B/macho.txt"
sign --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
echo "signed $(wc -l < "$B/macho.txt" | tr -d ' ') nested Mach-O files"

step "dmg"
ln -s /Applications "$B/dmg/Applications"
# retried: on CI runners hdiutil sometimes fails once with "Resource busy"
for try in 1 2 3; do
  rm -f "$DMG"
  hdiutil create -quiet -volname "观羽" -srcfolder "$B/dmg" -fs HFS+ -format ULMO "$DMG" && break
  [ "$try" = 3 ] && exit 1; echo "hdiutil failed, retrying"; sleep 10
done
[ "$SIGN_ID" = - ] || codesign -s "$SIGN_ID" --timestamp "$DMG"
echo "app $(du -sh "$APP" | cut -f1)   dmg $(du -h "$DMG" | cut -f1)   $DMG"
