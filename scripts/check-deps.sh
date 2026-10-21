#!/usr/bin/env bash
# Fails if the Rust dependency set drifts from the reviewed allowlist (docs/DEPENDENCIES.md),
# or if any package comes from somewhere other than the crates.io registry.
set -euo pipefail
cd "$(dirname "$0")/.."
allowed="arc-swap crossbeam-deque crossbeam-epoch crossbeam-utils either libc rayon rayon-core rustversion spacelyzer-engine"
lock=Cargo.lock
bad=0
for n in $(awk '/^name = /{gsub(/"/,"",$3); print $3}' "$lock"); do
  case " $allowed " in *" $n "*) ;; *) echo "::error::crate '$n' is not on the reviewed allowlist (docs/DEPENDENCIES.md)"; bad=1;; esac
done
if grep -E '^source = ' "$lock" | grep -v 'registry+https://github.com/rust-lang/crates.io-index' ; then
  echo "::error::a dependency comes from a non-crates.io source"; bad=1
fi
if grep -q 'git+' "$lock"; then echo "::error::git dependencies are not allowed"; bad=1; fi
[ "$bad" = 0 ] && echo "dependency set matches the allowlist ($(echo $allowed | wc -w) crates, all crates.io)"
exit $bad
