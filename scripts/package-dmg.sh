#!/bin/bash
# Assemble Spacelyzer.app from the SwiftPM build, sign it, and wrap it in a DMG.
# Usage: package-dmg.sh <version> [signing-identity]   (identity "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version}"
IDENTITY="${2:--}"
# Output folder; the ship-candidate run sets SPZ_DIST so packaging cannot delete the demo evidence in dist/.
DIST="${SPZ_DIST:-dist}"
bash scripts/shipping-swift.sh -c release --arch arm64 --arch x86_64
BIN="$(bash scripts/shipping-swift.sh -c release --arch arm64 --arch x86_64 --show-bin-path)/Spacelyzer"
bash scripts/check-no-ci-symbols.sh build/lib/libspacelyzer_engine.a "$BIN"
APP="$DIST/Spacelyzer.app"
rm -rf "$DIST" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spacelyzer"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
if [[ -d Resources/AppIcon.iconset ]]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
else
  echo "error: no app icon source (Resources/AppIcon.iconset or Resources/AppIcon.icns)" >&2
  exit 1
fi
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" \
  --entitlements Resources/Spacelyzer.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority|Signature|TeamIdentifier|Identifier" || true
mkdir -p "$DIST/dmg" && cp -R "$APP" "$DIST/dmg/"
ln -s /Applications "$DIST/dmg/Applications"
# Install-window art + Finder layout: 660x400 window, icon size 128,
# Spacelyzer.app at (190,185), Applications alias at (470,185).
BG="Resources/dmg-background.png"
BG2X="Resources/dmg-background@2x.png"
if [[ ! -f "$BG" || ! -f "$BG2X" ]]; then
  echo "error: missing DMG background ($BG and/or $BG2X)" >&2
  exit 1
fi
RW="$DIST/Spacelyzer-$VERSION-rw.dmg"
VOLUME="Spacelyzer $VERSION"
hdiutil create -volname "$VOLUME" -srcfolder "$DIST/dmg" -ov -format UDRW "$RW"
hdiutil attach -readwrite -noverify "$RW" >/dev/null
MOUNT="${SPZ_DMG_MOUNT_ROOT:-/Volumes}/$VOLUME"
trap 'hdiutil detach "$MOUNT" -force 2>/dev/null || true' EXIT
mkdir -p "$MOUNT/.background"
cp "$BG" "$MOUNT/.background/background.png"
cp "$BG2X" "$MOUNT/.background/background@2x.png"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 760, 500}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.png"
    set position of item "Spacelyzer.app" of container window to {190, 185}
    set position of item "Applications" of container window to {470, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
sleep 2
hdiutil detach "$MOUNT" >/dev/null
trap - EXIT
hdiutil convert "$RW" -format UDZO -ov -o "$DIST/Spacelyzer-$VERSION.dmg"
rm "$RW"
( cd "$DIST" && shasum -a 256 "Spacelyzer-$VERSION.dmg" | tee "Spacelyzer-$VERSION.dmg.sha256" )
