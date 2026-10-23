#!/bin/bash
# Linux real model -> CI engine cancellation checks; never a Mac/UI responsiveness proof.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export PATH="${SWIFT_BIN:-/tmp/sw/usr/bin}:$HOME/.cargo/bin:$PATH"
[[ "$(uname)" == Linux ]] || { echo 'Linux harness only' >&2; exit 4; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
shipping="$REPO/target/release/libspacelyzer_engine.a"
before=absent
[[ ! -f "$shipping" ]] || before=$(sha256sum "$shipping" | cut -d ' ' -f1)
# Explicit separate target dir: CARGO_TARGET_DIR must not redirect this into shipping.
(cd "$REPO" && cargo build --release --locked -p spacelyzer-engine --features ci-checks --target-dir "$work/ci-target" --lib)
after=absent
[[ ! -f "$shipping" ]] || after=$(sha256sum "$shipping" | cut -d ' ' -f1)
[[ "$before" == "$after" ]] || { echo 'shipping archive changed' >&2; exit 4; }
SPZ_WITH_CANCEL_CHECKS=1 SPZ_ENGINE_LIB="$work/ci-target/release/libspacelyzer_engine.a" 
export SPZ_WITH_CANCEL_CHECKS SPZ_ENGINE_LIB
bash "$HERE/build-engine-checks.sh" "$work/checks"
# A zero process exit without all three named end states is not coverage.
timeout 100 "$work/checks" | tee "$work/results.txt"
python3 - "$work/results.txt" <<'PY_VERIFY'
import sys
lines=open(sys.argv[1]).read().splitlines()
results=[line.split(' ',2)[:2] for line in lines if line.startswith(('PASS ','FAIL '))]
expected=['scan-cancel-stops-promptly-and-publishes-partial-tree',
          'scan-cancel-before-progress-returns-promptly','rescan-after-model-cancel-is-complete']
for name in expected:
    assert [status for status,n in results if n==name]==['PASS'], f'missing, duplicated or failed: {name}'
passed=sum(status=='PASS' for status,n in results);failed=sum(status=='FAIL' for status,n in results)
assert [l for l in lines if l.startswith('DONE ')]==[f'DONE passes={passed} fails={failed}'], 'missing/inconsistent DONE line'
assert failed==0, 'failing checks'
print('CANCEL GATE PASS: all three named end states exactly once; DONE counts match')
PY_VERIFY
