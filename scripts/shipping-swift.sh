#!/bin/bash
# Shipping Swift entrypoint: ignore ambient CI selection and reject contaminated archives.
set -euo pipefail
cd "$(dirname "$0")/.."
unset SPZ_CI_ENGINE
bash scripts/check-no-ci-symbols.sh build/lib/libspacelyzer_engine.a
swift build "$@"
# Every shipping invocation also checks the actual linked executable. --show-bin-path
# is read-only; matching args preserve arch/config/scratch selection.
case " $* " in *" --show-bin-path "*) ;; *)
  bin=$(swift build "$@" --show-bin-path)/Spacelyzer
  bash scripts/check-no-ci-symbols.sh "$bin"
;; esac
