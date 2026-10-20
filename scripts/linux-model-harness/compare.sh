#!/bin/bash
# Two distinct modes. Both are gates: a nonzero exit means the stated claim is NOT shown.
#   compare.sh baseline                         HEAD sources, HEAD checks. Claim: every declared check passes. This is NOT fix proof.
#   compare.sh regress <base-ref> <check-name>  Claim: <check-name> fails on <base-ref>'s AppModel.swift and passes on HEAD's, and nothing else differs.
# Declared check names come from the Check.expect("...") literals in the checks source of the tree being run, never from grep totals of output.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="${SPZ_REPO:-$(cd "$HERE/../.." && pwd)}"
MODE="${1:?mode: baseline | regress}"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
declared() { grep -o 'Check\.expect("[^"]*"' "$1/MultiSelectChecks.swift" | sed 's/Check\.expect("//; s/"$//' | sort; }
# run <label> <sources-dir> -> sets RC and writes $T/<label>.txt; a crash/signal or missing DONE line is a gate failure, never a masked result
run() { "$HERE/build.sh" "$T/$1.bin" "$2" >"$T/$1.build.txt" 2>&1 || { echo "GATE FAIL: $1 build failed"; tail -5 "$T/$1.build.txt"; exit 2; }
        set +e; "$T/$1.bin" >"$T/$1.txt" 2>"$T/$1.err"; RC=$?; set -e; }
verify_complete() { # <label> ; requires DONE line consistent with PASS/FAIL lines and an exit code of 0 or 1 only
  local f="$T/$1.txt"; grep -q '^DONE passes=' "$f" || { echo "GATE FAIL: $1 has no DONE line (crash or truncated output), rc=$RC"; tail -5 "$T/$1.err"; exit 3; }
  [ "$RC" = 0 ] || [ "$RC" = 1 ] || { echo "GATE FAIL: $1 exit code $RC"; exit 3; }
  local p=$(grep -c '^PASS ' "$f" || true) fl=$(grep -c '^FAIL ' "$f" || true)
  [ "$(grep '^DONE' "$f")" = "DONE passes=$p fails=$fl" ] || { echo "GATE FAIL: $1 DONE line disagrees with PASS/FAIL lines"; exit 3; }
  [ "$fl" -gt 0 ] && [ "$RC" = 0 ] && { echo "GATE FAIL: $1 FAIL lines but exit 0"; exit 3; } || true; }
names_of() { grep '^\(PASS\|FAIL\) ' "$1" | awk '{print $2}' | sort; }
HEAD_SRC="$REPO/Sources/Spacelyzer"; declared "$HEAD_SRC" > "$T/declared.txt"; N=$(wc -l < "$T/declared.txt")
case "$MODE" in
 baseline)
   run new "$HEAD_SRC"; verify_complete new
   [ "$RC" = 0 ] || { echo "GATE FAIL: baseline has failing checks"; cat "$T/new.txt"; exit 1; }
   diff <(names_of "$T/new.txt") "$T/declared.txt" >/dev/null || { echo "GATE FAIL: emitted names differ from declared names"; diff <(names_of "$T/new.txt") "$T/declared.txt"; exit 1; }
   echo "BASELINE OK: $N/$N declared checks pass on HEAD. This does not show that any fix works."; ;;
 regress)
   BASE="${2:?base ref}"; CHK="${3:?check name}"
   grep -qx "$CHK" "$T/declared.txt" || { echo "GATE FAIL: $CHK is not a declared check in HEAD's source"; exit 1; }
   cp -r "$HEAD_SRC" "$T/old"; git -C "$REPO" show "$BASE:Sources/Spacelyzer/AppModel.swift" > "$T/old/AppModel.swift"
   run new "$HEAD_SRC"; verify_complete new; NEWRC=$RC
   run old "$T/old"; verify_complete old; OLDRC=$RC
   [ "$NEWRC" = 0 ] || { echo "GATE FAIL: HEAD has failing checks"; cat "$T/new.txt"; exit 1; }
   diff <(names_of "$T/new.txt") "$T/declared.txt" >/dev/null || { echo "GATE FAIL: HEAD emitted names differ from declared"; exit 1; }
   [ "$OLDRC" = 1 ] || { echo "GATE FAIL: expected $BASE to fail $CHK but the run exited $OLDRC"; exit 1; }
   diff <(names_of "$T/old.txt") "$T/declared.txt" >/dev/null || { echo "GATE FAIL: $BASE run did not emit every declared check"; exit 1; }
   [ "$(grep '^FAIL ' "$T/old.txt" | awk '{print $2}')" = "$CHK" ] || { echo "GATE FAIL: on $BASE the failing set is not exactly {$CHK}"; grep '^FAIL ' "$T/old.txt"; exit 1; }
   echo "REGRESSION SHOWN: on $BASE only $CHK fails ($((N-1))/$N others pass); on HEAD all $N pass."; grep "^FAIL $CHK" "$T/old.txt"; ;;
 *) echo "unknown mode $MODE" >&2; exit 64;; esac
