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
timeout 100 "$work/checks"
