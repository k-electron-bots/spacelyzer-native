#!/bin/bash
# cf-idiom-lint.sh - offline idiom lint for Swift helpers touching CoreFoundation/AX.
# Catches the exact class that failed run 39961036509 (as? AXUIElement at 185:54)
# WITHOUT any toolchain. Run from the repo root: bash scripts/cf-idiom-lint.sh [file ...]
# Exit 0 = clean, 1 = deviation found. Deviations are not necessarily errors, but any
# hit is a CF/API form that is NOT a Mac-compile-proven idiom and must be justified
# or switched to the proven idiom before it ships uncompiled-on-Mac.
set -u
files=("$@"); [ ${#files[@]} -eq 0 ] && files=(scripts/*.swift)
rc=0
for f in "${files[@]}"; do
  # Rule 1: single-value conditional downcast to a CF/AX type (hard error on real CF types).
  # Proven-safe idioms: array casts `as? [T]`, forced casts `as! T`.
  while IFS= read -r line; do
    echo "DEVIATION $f: single-value conditional CF/AX downcast (Mac error class; use nil-guard + as!): $line"; rc=1
  done < <(grep -nE 'as\? +(AX|CF|CG)[A-Z]' "$f" | grep -vE 'as\? +\[')
  # Rule 2: boolean literal bridged to CFTypeRef (compiles, but the Mac-proven idiom
  # for boolean AX attributes in this file is kCFBooleanTrue).
  while IFS= read -r line; do
    echo "DEVIATION $f: boolean literal as CFTypeRef (proven idiom is kCFBooleanTrue): $line"; rc=1
  done < <(grep -nE '\b(true|false) as CFTypeRef' "$f")
done
[ $rc -eq 0 ] && echo "cf-idiom-lint: clean"
exit $rc
