#!/bin/bash
# Fail closed on ANY reference/definition of a CI rendezvous symbol in a shipping artifact, in EVERY
# architecture slice, and require the shipping export spz_scan_start DEFINED in every slice (positive
# control: an unreadable, stripped or wrong file cannot pass). Symbols come from LLVM nm via
# scripts/dump-symbols.sh (see there for arch/tool selection and failure behavior).
# Line contract (llvm-nm default BSD format): `[ADDRESS ]TYPE NAME`; ADDRESS is hex digits or dashes and is
# optional; TYPE is one letter (uppercase = external; U = undefined). Defined = T D S W B R.
set -euo pipefail
[ "$#" -gt 0 ] || { echo 'need archive or binary path' >&2; exit 64; }
here="$(cd "$(dirname "$0")" && pwd)"
for file in "$@"; do
  d=$(mktemp -d)
  bash "$here/dump-symbols.sh" "$file" "$d" || { echo "cannot inspect shipping symbols: $file" >&2; rm -rf "$d"; exit 1; }
  for f in "$d"/*.txt; do
    if grep -Eq '(^|[[:space:]])_?spz_ci_scan_[[:alnum:]_]*([[:space:]]|$)' "$f"; then
      echo "CI rendezvous symbol in shipping artifact ($(basename "$f" .txt)): $file" >&2; rm -rf "$d"; exit 1
    fi
    grep -Eq '^([0-9a-fA-F-]+[[:space:]]+)?[TDSWBR][[:space:]]+_?spz_scan_start$' "$f" || { echo "cannot inspect shipping symbols: positive control spz_scan_start not defined in slice $(basename "$f" .txt) of $file" >&2; rm -rf "$d"; exit 1; }
  done
  rm -rf "$d"
done
