#!/bin/bash
# Fail closed on ANY reference/definition of a CI rendezvous symbol in a shipping artifact.
#
# Authority = scripts/defined-symbols.py, a tool-independent reader of the artifact's own
# Mach-O/ELF symbol tables (thin or universal, archive or linked binary, EVERY slice). It
# must (a) parse the whole artifact, (b) find the shipping export spz_scan_start DEFINED in
# every slice (positive control: unreadable/stripped/wrong files cannot pass) and (c) find no
# defined spz_ci_scan_*. A byte scan additionally rejects ANY occurrence (references too).
# The platform `nm` is advisory: when it runs it must agree; when it fails (Mac run
# 39832527366: Apple nm exited non-zero on the lipo'd universal archive, stderr was
# discarded) its exit status and stderr are PRINTED. nm failure alone is never a pass:
# the parser must still succeed or the check fails.
set -euo pipefail
[ "$#" -gt 0 ] || { echo 'need archive or binary path' >&2; exit 64; }
here="$(cd "$(dirname "$0")" && pwd)"
for file in "$@"; do
  [ -f "$file" ] && [ -r "$file" ] && [ -s "$file" ] || { echo "cannot inspect shipping symbols: missing, unreadable or empty: $file" >&2; exit 1; }
  if grep -a -E -q 'spz_ci_scan_[A-Za-z0-9_]*' "$file"; then
    echo "CI rendezvous symbol in shipping artifact (byte scan): $file" >&2; exit 1
  fi
  errf=$(mktemp); rc=0
  syms=$(python3 "$here/defined-symbols.py" "$file" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then echo "cannot inspect shipping symbols: $file: $(cat "$errf")" >&2; rm -f "$errf"; exit 1; fi
  # symbol lists are large: grep -q on a pipe can SIGPIPE the writer under pipefail (false negative), so use a file
  symf=$(mktemp); printf '%s\n' "$syms" > "$symf"
  slices=$(cut -d' ' -f1 "$symf" | sort -u)
  for sl in $slices; do
    grep -qx "$sl spz_scan_start" "$symf" || { echo "cannot inspect shipping symbols: positive control spz_scan_start not defined in slice $sl of $file" >&2; rm -f "$errf" "$symf"; exit 1; }
  done
  if grep -Eq ' spz_ci_scan_' "$symf"; then echo "CI rendezvous symbol defined in shipping artifact: $file" >&2; rm -f "$errf"; exit 1; fi
  rc=0; out=$(nm -g "$file" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "notice: nm -g exited $rc on $file (parser verified every slice). nm stderr (first 10 lines):" >&2; head -10 "$errf" >&2 || true
  elif printf '%s\n' "$out" | grep -E '(^|[[:space:]])_?spz_ci_scan_[[:alnum:]_]*([[:space:]]|$)' >/dev/null; then
    rm -f "$errf"; echo "CI rendezvous symbol in shipping artifact (nm): $file" >&2; exit 1
  fi
  rm -f "$errf" "$symf"
done
