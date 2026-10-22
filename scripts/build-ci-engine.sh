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
# nm output is retained in files: pipefail must not mistake grep -q SIGPIPE for absence.
nm -g build/ci-lib/libspacelyzer_ci.a > build/ci-lib/symbols.txt 2>/dev/null
for symbol in spz_ci_scan_start_parked spz_ci_scan_gate_state spz_ci_scan_gate_release; do
  grep -E "[[:space:]]T[[:space:]]_?$symbol$" build/ci-lib/symbols.txt >/dev/null || { echo "missing CI symbol $symbol"; exit 1; }
done
