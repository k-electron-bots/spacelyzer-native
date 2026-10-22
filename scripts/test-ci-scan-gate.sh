#!/bin/bash
# Real Rust behavior + single-mechanism negative control. No Mac or Swift claims.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo test --locked -p spacelyzer-engine --features ci-checks --test ci_scan_gate
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp Cargo.toml Cargo.lock "$W/"
cp -R engine "$W/"
python3 - "$W/engine/src/scan.rs" <<'PY'
import sys
p=sys.argv[1];s=open(p).read()
n='    if let Some(gate) = &ctx.progress.ci_gate { gate.rendezvous(); }'
assert s.count(n)==1
s=s.replace(n,'    if let Some(_gate) = &ctx.progress.ci_gate { /* negative control: no rendezvous */ }')
open(p,'w').write(s)
PY
set +e
CARGO_TARGET_DIR="$W/target" cargo test --locked --manifest-path "$W/Cargo.toml" -p spacelyzer-engine --features ci-checks --test ci_scan_gate parked_real_cancel_is_partial_and_other_session_is_independent > "$W/control.log" 2>&1
rc=$?
set -e
[ "$rc" = 101 ] && grep -q 'per-session park never reached' "$W/control.log" || { cat "$W/control.log"; exit 1; }
echo 'PASS negative control: removing actual rendezvous fails its real-FFI check'

# Same real parked worker, but do not call the cancellation C ABI. It must not look cancelled.
cp engine/src/scan.rs "$W/engine/src/scan.rs"
python3 - "$W/engine/tests/ci_scan_gate.rs" <<'PY2'
import sys
p=sys.argv[1];s=open(p).read();needle='spz_scan_cancel(a); spz_ci_scan_gate_release(a);'
assert needle in s
s=s.replace(needle,'/* negative control: no cancel call */ spz_ci_scan_gate_release(a);',1)
open(p,'w').write(s)
PY2
set +e
CARGO_TARGET_DIR="$W/target" cargo test --locked --manifest-path "$W/Cargo.toml" -p spacelyzer-engine --features ci-checks --test ci_scan_gate parked_real_cancel_is_partial_and_other_session_is_independent > "$W/no-cancel.log" 2>&1
rc=$?
set -e
[ "$rc" = 101 ] && grep -q 'assertion.*failed' "$W/no-cancel.log" || { cat "$W/no-cancel.log"; exit 1; }
echo 'PASS negative control: omitting real cancel fails cancelled-tree assertion'
