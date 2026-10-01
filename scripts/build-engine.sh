#!/bin/bash
# Build the Rust engine as a universal (arm64 + x86_64) static library into build/lib.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/lib
if [[ "$(uname)" == "Darwin" ]]; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  export MACOSX_DEPLOYMENT_TARGET=14.0
  cargo build --release -p spacelyzer-engine --target aarch64-apple-darwin --lib
  cargo build --release -p spacelyzer-engine --target x86_64-apple-darwin --lib
  lipo -create -output build/lib/libspacelyzer_engine.a \
    target/aarch64-apple-darwin/release/libspacelyzer_engine.a \
    target/x86_64-apple-darwin/release/libspacelyzer_engine.a
else
  cargo build --release -p spacelyzer-engine --lib
  cp target/release/libspacelyzer_engine.a build/lib/
fi
echo "engine: $(ls -la build/lib/libspacelyzer_engine.a)"
