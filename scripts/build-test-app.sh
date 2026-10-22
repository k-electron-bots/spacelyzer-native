#!/bin/bash
# Build a TEST-ONLY app with -DSPZ_CI_TESTS (scripted demo + regression suites). Never packaged, uploaded or released.
# Usage: build-test-app.sh <outdir> [signing-identity]   (identity "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?outdir}"; IDENTITY="${2:--}"
SCRATCH=".build-citests-rendezvous"
# Separate library name AND cargo/Swift caches prevent shipping/test archive mixups.
shipping_before=$(shasum -a 256 build/lib/libspacelyzer_engine.a | awk '{print $1}')
bash scripts/build-ci-engine.sh
shipping_after=$(shasum -a 256 build/lib/libspacelyzer_engine.a | awk '{print $1}')
[ "$shipping_before" = "$shipping_after" ] || { echo "shipping engine bytes changed"; exit 1; }
nm -g build/lib/libspacelyzer_engine.a > build/ci-lib/shipping-symbols.txt 2>/dev/null
if grep -E '[[:space:]]T[[:space:]]_?spz_ci_scan_' build/ci-lib/shipping-symbols.txt >/dev/null; then
  echo "CI rendezvous leaked into shipping library"; exit 1
fi
export SPZ_CI_ENGINE=1
# Optional extra compile flags (space-separated names, e.g. "SPZ_CI_PERF SPZ_CI_SHOTS"). Empty by default: the ordinary test build is unchanged.
EXTRA=(); for d in ${SPZ_TEST_EXTRA_DEFINES:-}; do EXTRA+=(-Xswiftc "-D$d"); done
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DSPZ_CI_TESTS ${EXTRA[@]+"${EXTRA[@]}"} --scratch-path "$SCRATCH"
BIN="$(swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DSPZ_CI_TESTS ${EXTRA[@]+"${EXTRA[@]}"} --scratch-path "$SCRATCH" --show-bin-path)/Spacelyzer"
APP="$OUT/Spacelyzer.app"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spacelyzer"
sed "s/__VERSION__/0.0.0-citests/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" --entitlements Resources/Spacelyzer.entitlements "$APP"
codesign --verify --deep --strict "$APP"
