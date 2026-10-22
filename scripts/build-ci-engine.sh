#!/bin/bash
# Isolated ci-checks engine. Never overwrite build/lib or target/release shipping artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ci-lib
if [[ "$(uname)" == Darwin ]]; then
  export MACOSX_DEPLOYMENT_TARGET=14.0
  for arch in aarch64 x86_64; do
    cargo build --release --locked -p spacelyzer-engine --features ci-checks --target-dir target/ci-checks --target "$arch-apple-darwin" --lib
  done
  lipo -create -output build/ci-lib/libspacelyzer_ci.a target/ci-checks/{aarch64,x86_64}-apple-darwin/release/libspacelyzer_engine.a
else
  cargo build --release --locked -p spacelyzer-engine --features ci-checks --target-dir target/ci-checks --lib
  cp target/ci-checks/release/libspacelyzer_engine.a build/ci-lib/libspacelyzer_ci.a
fi
# Each required CI symbol must be present. Byte presence (tool-independent) is mandatory.
# When nm runs it must also show a DEFINITION (T) for each; when nm cannot run (Apple nm exited
# non-zero on a lipo'd universal archive in Mac run 39832527366) its exit status and stderr are
# printed and only presence is proven, never a silent pass. nm output is retained in files:
# pipefail must not mistake grep -q SIGPIPE for absence.
ci=build/ci-lib/libspacelyzer_ci.a
[ -s "$ci" ] || { echo "missing or empty CI archive $ci"; exit 1; }
for symbol in spz_ci_scan_start_parked spz_ci_scan_gate_state spz_ci_scan_gate_release; do
  grep -a -F -q "$symbol" "$ci" || { echo "missing CI symbol $symbol"; exit 1; }
done
rc=0; nm -g "$ci" > build/ci-lib/symbols.txt 2> build/ci-lib/nm-stderr.txt || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "notice: nm -g exited $rc on $ci; only byte presence of the CI symbols is proven (not T definitions). nm stderr (first 10 lines):" >&2
  head -10 build/ci-lib/nm-stderr.txt >&2 || true
else
  for symbol in spz_ci_scan_start_parked spz_ci_scan_gate_state spz_ci_scan_gate_release; do
    grep -E "[[:space:]]T[[:space:]]_?$symbol$" build/ci-lib/symbols.txt >/dev/null || { echo "missing CI symbol definition $symbol"; exit 1; }
  done
fi
