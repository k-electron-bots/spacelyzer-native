#!/bin/bash
# Fail closed on ANY reference/definition of a CI rendezvous symbol in a shipping artifact.
#
# Authoritative check = tool-independent byte scan of the artifact itself (archive symbol
# tables and string tables are plain text), with a POSITIVE CONTROL: the artifact must
# contain a known shipping export, so an unreadable/empty/wrong file can never pass.
# The platform `nm` is a second, best-effort reader: when it runs it must agree (a CI symbol
# in its output fails). When it cannot run (Mac run 39832527366: Apple nm exited non-zero on
# the lipo'd universal archive with its stderr discarded) its exit status and stderr are
# PRINTED and the byte scan alone decides. nm failure is never silent and never a pass by itself.
set -euo pipefail
[ "$#" -gt 0 ] || { echo 'need archive or binary path' >&2; exit 64; }
CONTROL='spz_scan_start'
PATTERN='spz_ci_scan_[A-Za-z0-9_]*'
for file in "$@"; do
  [ -f "$file" ] && [ -r "$file" ] && [ -s "$file" ] || { echo "cannot inspect shipping symbols: missing, unreadable or empty: $file" >&2; exit 1; }
  grep -a -F -q "$CONTROL" "$file" || { echo "cannot inspect shipping symbols: positive control '$CONTROL' not found in $file (wrong, stripped or unreadable artifact)" >&2; exit 1; }
  if grep -a -E -q "$PATTERN" "$file"; then
    echo "CI rendezvous symbol in shipping artifact (byte scan): $file" >&2
    grep -a -E -o "$PATTERN" "$file" | sort -u | head -5 >&2 || true
    exit 1
  fi
  errf=$(mktemp); rc=0
  symbols=$(nm -g "$file" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "notice: nm -g exited $rc on $file; byte scan (control present, no CI symbol) is the authority. nm stderr (first 10 lines):" >&2
    head -10 "$errf" >&2 || true
  elif printf '%s\n' "$symbols" | grep -E '(^|[[:space:]])_?spz_ci_scan_[[:alnum:]_]*([[:space:]]|$)' >/dev/null; then
    rm -f "$errf"; echo "CI rendezvous symbol in shipping artifact (nm): $file" >&2; exit 1
  fi
  rm -f "$errf"
done
