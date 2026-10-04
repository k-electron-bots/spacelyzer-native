#!/usr/bin/env bash
# Local macOS check runner for the ordering driver. Run from the repo root on a Mac with Xcode/Swift and Rust.
#
#   scripts/local-mac-check.sh --setup     one-time, EXPLICIT network step: rustup target add + cargo fetch --locked
#   scripts/local-mac-check.sh             validation: offline and --locked; never modifies the toolchain
#   --expect-tree <sha>                    reviewed source tree (default below). The runner file itself is excluded from the comparison.
#
# Every section prints RAN PASS / RAN FAIL / NOT-RUN so a log cannot imply a Mac pass it did not earn.
# Logs go OUTSIDE the repo: ${SPZ_LOCAL_LOGS:-$HOME/spz-local-logs}/<UTC stamp>/.
# Each driver launch can take up to ~6 minutes; it opens a real window and takes focus, so do not use the Mac meanwhile.
# The app under test uses a unique bundle id and a unique path; only the PID launched from that path is ever killed.
set -uo pipefail
cd "$(dirname "$0")/.."
EXPECT_TREE=5b22de43198a254d7ff0a9b469432e07e3209eeb
SETUP=0
while [ $# -gt 0 ]; do case "$1" in
  --setup) SETUP=1;; --expect-tree) shift; EXPECT_TREE="${1:?need sha}";; *) echo "unknown arg $1" >&2; exit 64;; esac; shift; done
if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOT-RUN: this is $(uname -s), not macOS. Swift/UI/AX/PNG checks need a Mac; a Linux run is not a Mac pass." >&2; exit 2
fi
if [ "$SETUP" = 1 ]; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin && cargo fetch --locked
  echo "setup finished (network + toolchain changes happened only in this mode)"; exit $?
fi

OUT="${SPZ_LOCAL_LOGS:-$HOME/spz-local-logs}/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"; FAILED=0
WORK=$(mktemp -d /tmp/spz-local.XXXXXX); APP="$WORK/Spacelyzer.app"; OWNPID=""
cleanup() { [ -n "$OWNPID" ] && kill "$OWNPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
say() { echo "$*" | tee -a "$SUMMARY"; }
fail_stop() { say "$*"; say "NOT-RUN   everything after this point"; exit 1; }

# 1. Source identity: clean tree, no untracked files, exact reviewed tree excluding this runner (temp index; real index untouched).
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then git status --porcelain --untracked-files=all > "$OUT/dirty.txt"; fail_stop "RAN FAIL  source-clean (tracked changes or untracked files; see $OUT/dirty.txt)"; fi
IDX="$WORK/idx"; GOT=$(GIT_INDEX_FILE="$IDX" bash -c 'git read-tree HEAD && git rm --cached -q --ignore-unmatch scripts/local-mac-check.sh && git write-tree')
{ echo "commit: $(git rev-parse HEAD)"; echo "tree (runner excluded): $GOT"; echo "expected: $EXPECT_TREE"; sw_vers; xcodebuild -version; swift --version; rustc --version; cargo --version; } > "$OUT/toolchain.log" 2>&1
[ "$GOT" = "$EXPECT_TREE" ] || fail_stop "RAN FAIL  reviewed-tree (got $GOT, expected $EXPECT_TREE)"
say "RAN PASS  reviewed-tree $GOT"

# 2. Refuse to run next to any other Spacelyzer process (it could be the user's real app; we never touch it).
if pgrep -x Spacelyzer >/dev/null; then fail_stop "RAN FAIL  no-conflicting-app (a Spacelyzer process is already running; quit it yourself, this script will not)"; fi
# 3. Offline preflight: required Rust targets must already be installed.
for t in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed 2>/dev/null | grep -qx "$t" || fail_stop "RAN FAIL  preflight (rust target $t missing; run once: $0 --setup)"
done

step() { local name="$1"; shift
  if "$@" >"$OUT/$name.log" 2>&1; then say "RAN PASS  $name"; else say "RAN FAIL  $name (see $OUT/$name.log)"; FAILED=1; fi; }
export CARGO_NET_OFFLINE=true MACOSX_DEPLOYMENT_TARGET=14.0
build_engine() { mkdir -p build/lib &&
  cargo build --locked --offline --release -p spacelyzer-engine --target aarch64-apple-darwin --lib &&
  cargo build --locked --offline --release -p spacelyzer-engine --target x86_64-apple-darwin --lib &&
  lipo -create -output build/lib/libspacelyzer_engine.a target/aarch64-apple-darwin/release/libspacelyzer_engine.a target/x86_64-apple-darwin/release/libspacelyzer_engine.a; }
step manifest python3 scripts/check-ordering-manifest.py
N=$(sed -n 's/^OK \([0-9]*\) required == \([0-9]*\) declared$/\1/p' "$OUT/manifest.log")
[ -n "$N" ] || fail_stop "RAN FAIL  manifest-count (could not read N)"; say "pinned required count N=$N"
step deps ./scripts/check-deps.sh
step build-engine build_engine
step cargo-default cargo test --locked --offline --manifest-path engine/Cargo.toml
step cargo-failpoints cargo test --locked --offline --manifest-path engine/Cargo.toml --features failpoints
TESTSBIN="$WORK/spz-tests-bin"
swift_tests() { swift build -c release -Xswiftc -DSPZ_CI_TESTS --scratch-path "$WORK/build-tests" && cp "$(swift build -c release -Xswiftc -DSPZ_CI_TESTS --scratch-path "$WORK/build-tests" --show-bin-path)/Spacelyzer" "$TESTSBIN"; }
NORMALBIN=""
swift_normal() { swift build -c release --scratch-path "$WORK/build-normal" && NORMALBIN="$(swift build -c release --scratch-path "$WORK/build-normal" --show-bin-path)/Spacelyzer" && echo "$NORMALBIN" > "$WORK/normalbin"; }
step swift-build-tests swift_tests
step swift-build-normal swift_normal
tripwires() { local nb; nb=$(cat "$WORK/normalbin") || return 1
  strings "$nb" > "$WORK/s-normal.txt"; strings "$TESTSBIN" > "$WORK/s-tests.txt"
  for m in 'SPZ_RESULT_DIR missing' 'commit-order-real-scan-published' 'async-removal-forgets-after-success' 'SPZ_CI_DISABLE_POISON_RELOAD' 'SPZ_CI_DISABLE_SELECTION_REVISION'; do
    if grep -q -- "$m" "$WORK/s-normal.txt"; then echo "tripwire: '$m' found in NORMAL build"; return 1; fi
    grep -q -- "$m" "$WORK/s-tests.txt" || { echo "sanity: '$m' missing from tests build"; return 1; }
  done; echo "tripwires passed (strings can miss literals; this is NOT proof of absence)"; }
if [ -f "$WORK/normalbin" ] && [ -x "$TESTSBIN" ]; then step normal-binary-tripwires tripwires; else say "NOT-RUN   normal-binary-tripwires (a Swift build failed)"; FAILED=1; fi

# 4. Driver launches. Unique bundle id + unique path; only the PID found under that path is killed.
run_driver() { local label="$1"; shift
  local RES="$WORK/res-$label" FIX="$WORK/fix-$label"; mkdir -p "$RES" "$FIX/d"
  head -c 200000 /dev/zero > "$FIX/a.bin"; head -c 100000 /dev/zero > "$FIX/d/b.bin"
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" && cp "$TESTSBIN" "$APP/Contents/MacOS/Spacelyzer" || return 1
  sed -e "s/__VERSION__/0.0.0-localcheck/g" -e "s|com.k-electron.spacelyzer-native|com.k-electron.spacelyzer-native.localcheck.$$|" Resources/Info.plist > "$APP/Contents/Info.plist"
  codesign --force --deep --sign - --entitlements Resources/Spacelyzer.entitlements "$APP" && codesign --verify --deep --strict "$APP" || return 1
  open -n "$APP" --stdout "$OUT/$label-stdout.log" --stderr "$OUT/$label-stderr.log" \
    --env SPZ_AUTOSCAN="$FIX" --env SPZ_DEMO=1 --env SPZ_CHECKS=ordering --env SPZ_RESULT_DIR="$RES" "$@"
  for _ in $(seq 1 30); do OWNPID=$(pgrep -f "$APP/Contents/MacOS/Spacelyzer" | head -1); [ -n "$OWNPID" ] && break; sleep 1; done
  [ -n "$OWNPID" ] || { echo "own app process never appeared"; return 1; }
  for _ in $(seq 1 360); do [ -s "$RES/result.txt" ] && break; sleep 1; done
  kill "$OWNPID" 2>/dev/null; OWNPID=""
  mkdir -p "$OUT/$label" && cp "$RES"/* "$OUT/$label/" 2>/dev/null
  [ -s "$RES/assertions.txt" ]; }
verdict_main() { local d="$OUT/main"
  [ "$(head -1 "$d/result.txt")" = "PASS $N required checks, each exactly once" ] || { echo "first line != PASS $N required checks, each exactly once"; return 1; }
  ! grep -q '^FAIL' "$d/assertions.txt" && [ "$(grep -c '^PASS' "$d/assertions.txt")" -ge "$N" ]; }
verdict_variant() { local f="$OUT/variant/assertions.txt"
  [ "$(grep -c '^FAIL' "$f")" = 2 ] && grep -q '^FAIL view-poison-outline-cells-show-unavailable-not-stale-names' "$f" && grep -q '^FAIL view-poison-outline-latch-persists-in-mounted-table' "$f" && [ "$(grep -c '^PASS' "$f")" -ge $((N-2)) ]; }
if [ -x "$TESTSBIN" ]; then
  step driver-main run_driver main
  step driver-main-verdict verdict_main
  step driver-poison-variant run_driver variant --env SPZ_CI_DISABLE_POISON_RELOAD=1
  step driver-poison-verdict verdict_variant
else say "NOT-RUN   driver (no test binary)"; FAILED=1; fi
say "NOT-COVERED regardless of result: real Trash, real-OS input, VoiceOver, shipped DMG, performance, crash-freedom. Inspect PNGs in $OUT/main by eye before accepting any visual check."
say "logs: $OUT"
exit $FAILED
