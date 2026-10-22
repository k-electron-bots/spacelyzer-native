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
# The CI archive must DEFINE all three rendezvous symbols (T) in EVERY architecture slice, read with
# LLVM nm (scripts/dump-symbols.sh fails closed on tool absence/failure/empty output).
ci=build/ci-lib/libspacelyzer_ci.a
symdir=build/ci-lib/symbols; rm -rf "$symdir"
bash scripts/dump-symbols.sh "$ci" "$symdir" || { echo "cannot inspect CI engine symbols: $ci"; exit 1; }
for f in "$symdir"/*.txt; do
  for symbol in spz_ci_scan_start_parked spz_ci_scan_gate_state spz_ci_scan_gate_release; do
    grep -E "(^|[[:space:]])T[[:space:]]+_?$symbol$" "$f" >/dev/null || { echo "missing CI symbol definition $symbol in slice $(basename "$f" .txt)"; exit 1; }
  done
done
