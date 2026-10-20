#!/bin/bash
# usage: compare.sh <base-ref>   Runs the HEAD checks against HEAD's AppModel (new) and against <base-ref>'s AppModel.swift (old).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; BASE="${1:?base ref}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$REPO/Sources/Spacelyzer" "$T/old"; git -C "$REPO" show "$BASE:Sources/Spacelyzer/AppModel.swift" > "$T/old/AppModel.swift"
"$HERE/build.sh" "$T/new"; "$HERE/build.sh" "$T/old.bin" "$T/old"
echo "== NEW (HEAD AppModel)"; "$T/new" | tee "$T/new.txt"; echo "== OLD ($BASE AppModel, HEAD checks)"; "$T/old.bin" | tee "$T/old.txt" || true
echo "new FAIL=$(grep -c '^FAIL' "$T/new.txt") old FAIL=$(grep -c '^FAIL' "$T/old.txt")"
