#!/bin/bash
# Fail closed on unreadable nm output or ANY reference/definition of a CI rendezvous symbol.
set -euo pipefail
[ "$#" -gt 0 ] || { echo 'need archive or binary path' >&2; exit 64; }
for file in "$@"; do
  symbols=$(nm -g "$file" 2>/dev/null) || { echo "cannot inspect shipping symbols: $file" >&2; exit 1; }
  if printf '%s\n' "$symbols" | grep -E '(^|[[:space:]])_?spz_ci_scan_[[:alnum:]_]*([[:space:]]|$)' >/dev/null; then
    echo "CI rendezvous symbol in shipping artifact: $file" >&2; exit 1
  fi
done
