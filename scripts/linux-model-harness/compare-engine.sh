#!/bin/bash
# usage: compare-engine.sh <base-ref> <failing-check>[,<failing-check>...]
# Real-Rust-engine folders/derived checks (build-engine.sh). Claim shown on success: on <base-ref>'s sources EXACTLY the named checks fail,
# every declared check is emitted, and on HEAD all declared checks pass. Crash, missing DONE or odd exit code is a gate failure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="${SPZ_REPO:-$(cd "$HERE/../.." && pwd)}"
BASE="${1:?base ref}"; WANT="$(echo "${2:?failing checks}" | tr ',' '\n' | sort)"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Declared names: every Check.expect("literal" inside foldersChecks() in HEAD's SpacelyzerApp.swift, plus the names[] array literals of that function.
decl() { awk '/private static func foldersChecks\(\) async/{p=1} p&&/private final class Box/{exit} p' "$1/SpacelyzerApp.swift" | grep -o 'Check\.expect("[a-z0-9-]*"' | sed 's/Check\.expect("//; s/"$//' | sort -u; }
HEAD_SRC="$REPO/Sources/Spacelyzer"; decl "$HEAD_SRC" > "$T/declared"
mkdir "$T/b"; git -C "$REPO" archive "$BASE" Sources | tar -x -C "$T/b"
runone() { "$HERE/build-engine.sh" "$T/$1.bin" "$2" >"$T/$1.build" 2>&1 || { echo "GATE FAIL: $1 build failed"; tail -5 "$T/$1.build"; exit 2; }
  set +e; "$T/$1.bin" >"$T/$1.out" 2>"$T/$1.err"; RC=$?; set -e
  grep -q '^DONE passes=' "$T/$1.out" || { echo "GATE FAIL: $1 no DONE (crash/truncated) rc=$RC"; tail -3 "$T/$1.err"; exit 3; }
  [ "$RC" = 0 ] || [ "$RC" = 1 ] || { echo "GATE FAIL: $1 rc=$RC"; exit 3; }
  p=$(grep -c '^PASS ' "$T/$1.out" || true); f=$(grep -c '^FAIL ' "$T/$1.out" || true)
  [ "$(grep '^DONE' "$T/$1.out")" = "DONE passes=$p fails=$f" ] || { echo "GATE FAIL: $1 DONE disagrees"; exit 3; }
  grep '^\(PASS\|FAIL\) ' "$T/$1.out" | awk '{print $2}' | sort > "$T/$1.names"; }
runone new "$HEAD_SRC"; NEWRC=$RC; runone old "$T/b/Sources/Spacelyzer"; OLDRC=$RC
[ "$NEWRC" = 0 ] || { echo "GATE FAIL: HEAD has failing checks"; grep '^FAIL' "$T/new.out"; exit 1; }
diff "$T/new.names" "$T/declared" >/dev/null || { echo "GATE FAIL: HEAD emitted names differ from declared"; diff "$T/new.names" "$T/declared"; exit 1; }
[ "$OLDRC" = 1 ] || { echo "GATE FAIL: $BASE exit $OLDRC, expected failures"; exit 1; }
diff "$T/old.names" "$T/declared" >/dev/null || { echo "GATE FAIL: $BASE run did not emit every declared check"; exit 1; }
[ "$(grep '^FAIL ' "$T/old.out" | awk '{print $2}' | sort)" = "$WANT" ] || { echo "GATE FAIL: failing set on $BASE is not exactly the named checks"; grep '^FAIL' "$T/old.out"; exit 1; }
echo "REGRESSION SHOWN (real Rust engine, Linux): on $BASE exactly [$(echo $WANT|tr ' ' ',')] fail; on HEAD all $(wc -l < "$T/declared") declared checks pass."; grep '^FAIL' "$T/old.out"
