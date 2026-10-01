#!/bin/bash
# Assemble Spacelyzer.app from the SwiftPM build, sign it, and wrap it in a DMG.
# Usage: package-dmg.sh <version> [signing-identity]   (identity "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version}"
IDENTITY="${2:--}"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Spacelyzer"
APP="dist/Spacelyzer.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spacelyzer"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" \
  --entitlements Resources/Spacelyzer.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority|Signature|TeamIdentifier|Identifier" || true
mkdir -p dist/dmg && cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Spacelyzer $VERSION" -srcfolder dist/dmg -ov -format UDZO "dist/Spacelyzer-$VERSION.dmg"
shasum -a 256 "dist/Spacelyzer-$VERSION.dmg" | tee "dist/Spacelyzer-$VERSION.dmg.sha256"
