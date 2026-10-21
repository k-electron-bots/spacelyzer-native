#!/bin/bash
# Executes the REAL Sources/Spacelyzer/AXActionName.swift on Linux against raw strings (observed and synthetic). Pure logic only:
# whether the real AX API vends these strings, what VoiceOver speaks, and AXUIElementPerformAction are Mac-only and NOT tested here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export PATH="${SWIFT_BIN:-/tmp/sw/usr/bin}:$PATH"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/main.swift" <<'SW'
import Foundation
var fails = 0
func t(_ n: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + n); if !ok { fails += 1 } }
let want = "Show locations not scanned"
let observed = "Name:Show locations not scanned|Target:0x0|Selector:(null)"   // verbatim from run 39451419467 ui-timing.txt
t("observed wrapper yields the authored name", AXActionName.authored(observed) == want)
t("newline-separated wrapper yields the authored name", AXActionName.authored("Name:Show locations not scanned\nTarget:0x0\nSelector:(null)") == want)
t("bare authored name passes through", AXActionName.authored(want) == want)
t("run 38993434887 style leak yields its OWN (wrong) name", AXActionName.authored("Name:1 location not readable\nTarget:0x0\nSelector:(null)") == "1 location not readable")
t("empty string is malformed", AXActionName.authored("") == nil)
t("Name: with nothing after is malformed", AXActionName.authored("Name:") == nil)
t("wrapper without a separator is malformed", AXActionName.authored("Name:Show locations not scanned") == nil)
t("empty name in wrapper is malformed", AXActionName.authored("Name:|Target:0x0|Selector:(null)") == nil)
t("wrapper missing Target: is malformed", AXActionName.authored("Name:Show locations not scanned|Selector:(null)") == nil)
t("wrapper missing Selector: is malformed", AXActionName.authored("Name:Show locations not scanned|Target:0x0") == nil)
t("isOnly accepts the observed single action", AXActionName.isOnly([observed], authored: want))
t("isOnly accepts the bare single action", AXActionName.isOnly([want], authored: want))
t("isOnly rejects no actions", !AXActionName.isOnly([], authored: want))
t("isOnly rejects a wrong authored name", !AXActionName.isOnly(["Name:1 location not readable|Target:0x0|Selector:(null)"], authored: want))
t("isOnly rejects an extra action", !AXActionName.isOnly([observed, "AXPress"], authored: want))
t("isOnly rejects a malformed string", !AXActionName.isOnly(["Name:Show locations not scanned"], authored: want))
t("vended returns the exact raw string to perform", AXActionName.vended(in: ["AXPress", observed], authored: want) == observed)
t("vended finds nothing for a wrong name", AXActionName.vended(in: ["Name:Other|Target:0x0|Selector:(null)"], authored: want) == nil)
t("old behaviour for contrast: exact bare-name match misses the observed string", !["x", observed].contains(want))
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
SW
swiftc -O "$REPO/Sources/Spacelyzer/AXActionName.swift" "$W/main.swift" -o "$W/t" && "$W/t"
