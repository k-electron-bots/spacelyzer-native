#!/usr/bin/env bash
# Local macOS check runner. Replaces the GitHub ordering workflow for local use; makes NO network calls and pushes nothing.
# Run from the repo root on a Mac with Xcode/Swift and Rust. Every section prints RAN or NOT-RUN so a log cannot imply a Mac pass it did not earn.
# Results go to logs/local-mac/<UTC stamp>/. Exit status is nonzero if any section that ran failed OR could not run.
set -uo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOT-RUN: this is $(uname -s), not macOS. Swift/UI/AX/PNG checks need a Mac; a Linux run is not a Mac pass." >&2; exit 2
fi
OUT="logs/local-mac/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"; FAILED=0
{ echo "commit: $(git rev-parse HEAD)"; echo "tree: $(git rev-parse 'HEAD^{tree}')"; echo "dirty: $(git status --porcelain | wc -l | tr -d ' ') changed paths"
  sw_vers; xcodebuild -version; swift --version; rustc --version; cargo --version; } 2>&1 | tee "$OUT/toolchain.log" >/dev/null
step() { # step <name> <cmd...>
  local name="$1"; shift
  if "$@" >"$OUT/$name.log" 2>&1; then echo "RAN PASS  $name" | tee -a "$SUMMARY"
  else echo "RAN FAIL  $name (see $OUT/$name.log)" | tee -a "$SUMMARY"; FAILED=1; fi
}
step manifest python3 scripts/check-ordering-manifest.py
step deps ./scripts/check-deps.sh
step build-engine ./scripts/build-engine.sh
step cargo-default cargo test --manifest-path engine/Cargo.toml
step cargo-failpoints cargo test --manifest-path engine/Cargo.toml --features failpoints
step swift-build-tests bash -c 'swift build -c release -Xswiftc -DSPZ_CI_TESTS && cp "$(swift build -c release -Xswiftc -DSPZ_CI_TESTS --show-bin-path)/Spacelyzer" /tmp/spz-tests-bin'
step swift-build-normal swift build -c release --scratch-path .build-normal

run_driver() { # run_driver <label> [extra env args...]
  local label="$1"; shift
  local APP=/tmp/spz-ordering/Spacelyzer.app RES FIX
  rm -rf /tmp/spz-ordering && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || return 1
  cp /tmp/spz-tests-bin "$APP/Contents/MacOS/Spacelyzer" || return 1
  sed "s/__VERSION__/0.0.0-local/g" Resources/Info.plist > "$APP/Contents/Info.plist"
  codesign --force --deep --sign - --entitlements Resources/Spacelyzer.entitlements "$APP" && codesign --verify --deep --strict "$APP" || return 1
  RES=$(mktemp -d /tmp/spz-local-result.XXXXXX); FIX=$(mktemp -d /tmp/spz-local-fixture.XXXXXX)
  mkdir -p "$FIX/d" && head -c 200000 /dev/zero > "$FIX/a.bin" && head -c 100000 /dev/zero > "$FIX/d/b.bin"
  pkill Spacelyzer 2>/dev/null; sleep 1
  open -n "$APP" --stdout "$PWD/$OUT/$label-stdout.log" --stderr "$PWD/$OUT/$label-stderr.log" \
    --env SPZ_AUTOSCAN="$FIX" --env SPZ_DEMO=1 --env SPZ_CHECKS=ordering --env SPZ_RESULT_DIR="$RES" "$@"
  for _ in $(seq 1 360); do [ -s "$RES/result.txt" ] && break; sleep 1; done
  pkill Spacelyzer 2>/dev/null
  mkdir -p "$OUT/$label" && cp "$RES"/* "$OUT/$label/" 2>/dev/null
  [ -s "$RES/assertions.txt" ]
}
if [ -x /tmp/spz-tests-bin ] && grep -q 'RAN PASS  swift-build-tests' "$SUMMARY"; then
  step driver-main run_driver main
  # Verdict: first line must be "PASS N required checks, each exactly once" and no FAIL rows. N is printed by the app from its own required list; this script does not re-derive it (run scripts/check-ordering-manifest.py for the source count).
  step driver-main-verdict bash -c "head -1 '$OUT/main/result.txt' | grep -q '^PASS [0-9]* required checks, each exactly once' && ! grep -q '^FAIL' '$OUT/main/assertions.txt'"
  step driver-poison-variant run_driver variant --env SPZ_CI_DISABLE_POISON_RELOAD=1
  step driver-poison-expects-two-fails bash -c "[ \$(grep -c '^FAIL' '$OUT/variant/assertions.txt') = 2 ] && grep -q '^FAIL view-poison-outline-cells-show-unavailable-not-stale-names' '$OUT/variant/assertions.txt' && grep -q '^FAIL view-poison-outline-latch-persists-in-mounted-table' '$OUT/variant/assertions.txt'"
else
  echo "NOT-RUN   driver (no test binary: the Swift test build failed)" | tee -a "$SUMMARY"; FAILED=1
fi
echo "NOT-COVERED regardless of result: real Trash, real-OS input, VoiceOver, shipped DMG, performance, crash-freedom. Read PNGs in $OUT/main by eye before accepting any visual check." | tee -a "$SUMMARY"
exit $FAILED
