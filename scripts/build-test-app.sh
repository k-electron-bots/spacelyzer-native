#!/bin/bash
# Build a TEST-ONLY app with -DSPZ_CI_TESTS (scripted demo + regression suites). Never packaged, uploaded or released.
# Usage: build-test-app.sh <outdir> [signing-identity]   (identity "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?outdir}"; IDENTITY="${2:--}"
SCRATCH=".build-citests"
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DSPZ_CI_TESTS --scratch-path "$SCRATCH"
BIN="$(swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DSPZ_CI_TESTS --scratch-path "$SCRATCH" --show-bin-path)/Spacelyzer"
APP="$OUT/Spacelyzer.app"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spacelyzer"
sed "s/__VERSION__/0.0.0-citests/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" --entitlements Resources/Spacelyzer.entitlements "$APP"
codesign --verify --deep --strict "$APP"
