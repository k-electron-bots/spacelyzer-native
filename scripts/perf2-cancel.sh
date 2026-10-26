#!/bin/bash
# Cancel-latency leg (n=3) through the in-app PerfDriver (no accessibility). Usage: perf2-cancel.sh TESTAPP ROOT OUT SCRIPTS_DIR [CANCEL_AT] [RUNS]
# TESTAPP = dist-test/Spacelyzer.app built with SPZ_CI_TESTS + SPZ_CI_PERF. ROOT = 200k-item tree. Cancels at CANCEL_AT items (default 20000) so the scan is provably alive.
set +e
TESTAPP="$1"; ROOT="$2"; OUT="$3"; SD="$4"; AT="${5:-20000}"; RUNS="${6:-3}"
mkdir -p "$OUT"
W=$(mktemp -d); RES="$W/res"; mkdir -p "$RES"
APP="$W/app/Spacelyzer.app"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TESTAPP/Contents/MacOS/Spacelyzer" "$APP/Contents/MacOS/Spacelyzer" || { printf 'INCONCLUSIVE\ntest-only perf app missing: %s\n' "$TESTAPP" > "$OUT/verdict.txt"; exit 0; }
sed -e "s/__VERSION__/0.0.0-perf/g" -e "s|com.k-electron.spacelyzer-native|com.k-electron.spacelyzer-native.perf.$$|" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - --entitlements Resources/Spacelyzer.entitlements "$APP" && codesign --verify --deep --strict "$APP" || { printf 'INCONCLUSIVE\nperf app codesign failed\n' > "$OUT/verdict.txt"; exit 0; }
pkill Spacelyzer; sleep 2
open -n "$APP" --stdout "$W/stdout.log" --stderr "$W/stderr.log" \
  --env SPZ_DEMO=1 --env SPZ_CHECKS=perf --env SPZ_RESULT_DIR="$RES" --env SPZ_PERF_ROOT="$ROOT" --env SPZ_PERF_CANCEL_AT="$AT" --env SPZ_PERF_CANCEL_RUNS="$RUNS"
for _ in $(seq 1 200); do [ -s "$RES/result.txt" ] && break; sleep 1; done
pkill -f "$APP/Contents/MacOS/Spacelyzer"; sleep 1; pkill -9 -f "$APP/Contents/MacOS/Spacelyzer"
cp "$RES"/* "$OUT/" 2>/dev/null; cp "$W/stderr.log" "$OUT/stderr.log" 2>/dev/null
python3 "$SD/perf2-cancel-verdict.py" "$RES" "$OUT/verdict.txt" "$RUNS" > "$OUT/verdict-detail.txt" 2>&1
exit 0
