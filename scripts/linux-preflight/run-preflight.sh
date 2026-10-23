#!/bin/bash
# REQUIRED offline Swift preflight for the Mac helpers (user directive: Linux catches everything it can BEFORE any
# Mac run; a Mac run is never spent on a Linux-catchable error). The toolchain is REQUIRED: no swiftc = FAIL, never
# a skip-as-green. Install (free, no account): https://www.swift.org/install/linux/ - e.g.
#   curl -O https://download.swift.org/swift-6.1.2-release/ubuntu2204/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu22.04.tar.gz
# Verified on Swift 5.10.1 (reviewer) and 6.1.2 (builder); both compile the helpers in Swift 5 language mode.
set -u; cd "$(dirname "$0")/../.." || exit 1
P=scripts/linux-preflight; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; rc=0
SWIFTC="${SWIFTC:-$(command -v swiftc || true)}"
[ -z "$SWIFTC" ] && SWIFTC=$(ls -d /tmp/swift-*-RELEASE-*/usr/bin/swiftc 2>/dev/null | head -1)
if [ -z "$SWIFTC" ] || [ ! -x "$SWIFTC" ]; then echo "FAIL preflight: swiftc REQUIRED, not found (install: https://www.swift.org/install/linux/)"; exit 1; fi
echo "preflight toolchain: $($SWIFTC --version | head -1)"
# Layer 0 - syntax parse of EVERY Swift source (app + helpers; no SDK needed for -parse). Catches syntax errors
# across the whole tree offline; the app targets themselves were last compiled by the Mac job (run 39961036509 step 7).
l0fail=0
for f in $(find Sources -name '*.swift') scripts/*.swift; do
  "$SWIFTC" -parse "$f" > /dev/null 2>&1 || { echo "FAIL L0-parse $f"; "$SWIFTC" -parse "$f" 2>&1 | head -3; l0fail=1; }
done
[ $l0fail -eq 0 ] && echo "PASS L0-parse-all-swift" || rc=1
# L0 non-vacuity: a syntax-broken copy MUST fail parsing.
cp scripts/docs-capture.swift "$W/mut-parse.swift"; printf 'func broken(\n' >> "$W/mut-parse.swift"
"$SWIFTC" -parse "$W/mut-parse.swift" > /dev/null 2>&1 && { echo "FAIL L0-non-vacuity: syntax breakage not caught"; rc=1; } || echo "PASS L0-non-vacuity"
# Layer 1 - idiom lint on the real helper sources (no toolchain): no single-value CF/AX conditional downcast,
# no bool literal as CFTypeRef (the two Mac-compile-risk idioms; both burned or were unproven in run 39961036509).
if bash "$P/cf-idiom-lint.sh" scripts/docs-capture.swift scripts/ax-client.swift > "$W/lint.log" 2>&1; then
  echo "PASS L1-idiom-lint"
else
  echo "FAIL L1-idiom-lint"; cat "$W/lint.log"; rc=1
fi
# Layer 2 - real-CoreFoundation reproduction: the error class MUST fire (old) and the fixed idiom MUST pass (new).
# If repro-old ever passes, the toolchain/stub path is broken and the whole gate is non-vacuous-failed.
"$SWIFTC" -typecheck "$P/repro-old.swift" > "$W/l2old.log" 2>&1 && { echo "FAIL L2-old-fail: repro-old COMPILED - gate broken"; rc=1; } || grep -q "will always succeed" "$W/l2old.log" && echo "PASS L2-old-fail (hard error reproduced)" || { echo "FAIL L2-old-fail (wrong error)"; rc=1; }
"$SWIFTC" -typecheck "$P/repro-fixed.swift" > "$W/l2new.log" 2>&1 && echo "PASS L2-new-pass" || { echo "FAIL L2-new-pass"; cat "$W/l2new.log"; rc=1; }
# Layer 3 - full-helper typecheck, NS-alias stub SDK (catches syntax/symbol/type errors; CANNOT catch the CF class).
sed -e 's/^import AppKit$/import Glibc/' -e '/^import ApplicationServices$/d' -e '/^import CoreGraphics$/d' -e '/^import Darwin$/d' scripts/docs-capture.swift > "$W/main.swift"
"$SWIFTC" -typecheck "$W/main.swift" "$P/stubs.swift" > "$W/l3.log" 2>&1 && echo "PASS L3-stub-typecheck docs-capture" || { echo "FAIL L3-stub-typecheck docs-capture"; cat "$W/l3.log"; rc=1; }
# L3 non-vacuity: an injected unknown symbol MUST fail the same typecheck.
cp "$W/main.swift" "$W/mut.swift"; echo 'thisSymbolDoesNotExist()' >> "$W/mut.swift"
"$SWIFTC" -typecheck "$W/mut.swift" "$P/stubs.swift" > /dev/null 2>&1 && { echo "FAIL L3-non-vacuity: injected error not caught"; rc=1; } || echo "PASS L3-non-vacuity"
# Layer 3b - real-CF-typed stub SDK (AXUIElement=CFDictionary, AXValue=CFArray): ALSO catches the CF error class at
# compile level (verified: d10bbf4 fails at the same line:column as run 39961036509). Declared transforms:
# ` as CFString` removed (Linux lacks String->CFString literal bridging) and `import CoreFoundation` added
# (Darwin Foundation re-exports CF symbols; Linux does not). Neither touches CF cast semantics.
mkdir -p "$W/m"
for m in ApplicationServices CoreGraphics AppKit Darwin; do "$SWIFTC" -emit-module -module-name "$m" -parse-as-library "$P/realcf/$m.swift" -emit-module-path "$W/m/$m.swiftmodule" || { echo "FAIL L3b stub build $m"; rc=1; }; done
sed 's/ as CFString//g; s/^import Foundation$/import Foundation\nimport CoreFoundation/' scripts/docs-capture.swift > "$W/helper3b.swift"
"$SWIFTC" -typecheck -I "$W/m" "$W/helper3b.swift" > "$W/l3b.log" 2>&1 && echo "PASS L3b-realcf docs-capture" || { echo "FAIL L3b-realcf docs-capture"; cat "$W/l3b.log"; rc=1; }
sed 's/ as CFString//g; s/^import Foundation$/import Foundation\nimport CoreFoundation/; s/func attribute(_ element: AXUIElement, _ name: CFString)/func attribute(_ element: AXUIElement, _ name: String)/' scripts/ax-client.swift > "$W/axclient3b.swift"
"$SWIFTC" -typecheck -I "$W/m" "$W/axclient3b.swift" > "$W/l3b2.log" 2>&1 && echo "PASS L3b-realcf ax-client" || { echo "FAIL L3b-realcf ax-client"; cat "$W/l3b2.log"; rc=1; }
# Layer 4 - preserve the REAL stateLine and observer conditional layout in BOTH
# shipping/test configurations. Isolated function extraction alone missed this
# symbol-visibility regression on Mac run40027695341. Missing compiler is red.
SWIFT_BIN="$(dirname "$SWIFTC")" python3 scripts/test-sheet-build-modes.py > "$W/l4.log" 2>&1 && { echo "PASS L4-sheet-build-modes"; cat "$W/l4.log"; } || { echo "FAIL L4-sheet-build-modes"; cat "$W/l4.log"; rc=1; }
# HONEST LIMIT: stub SDKs are hand-written; native macOS SDK behavior, availability and AX semantics stay unproven
# until a Mac run. This gate proves the helpers are free of Linux-catchable compile errors - nothing more.
[ $rc -eq 0 ] && echo "PREFLIGHT GREEN (Linux-catchable compile errors excluded; NOT a macOS SDK proof)" || echo "PREFLIGHT FAILED"
exit $rc
