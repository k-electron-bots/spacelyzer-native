#!/usr/bin/env python3
"""Static UI copy and chrome checks. Linux-runnable, no build needed.

Guards the fixes from the v0.1.163 hands-on review:
1. US English in user-visible string literals (no colour/cancelled/...).
   Code symbols (Task.isCancelled) are not string literals and are not checked.
2. Every view presented via .sheet in ContentView exposes a visible Done/dismiss
   affordance (v0.1.163 shipped the Not-scanned and Duplicates sheets with Esc only).
3. Single-line truncation rule (AGENTS.md: truncate middle, never wrap): no
   lineLimit(n>1) outside the documented allowlist.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "Spacelyzer"

# Test-harness lines are not product copy: Check.expect names/diagnostics, Perf.log output,
# and bare check-name list entries keep their stable identifiers (renaming churns the gate list).
HARNESS_LINE = re.compile(r"Check\.expect\(|Perf\.log\(|DemoLog|^\s*\"[^\"]*\",?\s*(//.*)?$")

BRITISH = re.compile(
    r"\b(colour|colours|coloured|colouring|cancelled|cancelling|favour|favourite|behaviour|"
    r"organise|organised|organising|analyse|analysed|centre|centred|licence|grey|normalise|"
    r"prioritise|visualise|summarise|recognise|initialise)\b", re.I)

# String literals only: good enough for copy audit; interpolation contents are still text.
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

SHEET_VIEWS = {  # every view ContentView presents with .sheet must have a Done button,
    # and the Done must be the default action (Return closes, Esc already does).
    "SkippedListView.swift": 'Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)',
    "DuplicatesReviewView.swift": 'Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)',
    "ExclusionsView.swift": 'Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)',
}

LINELIMIT_ALLOWLIST = {  # file: lineLimit values above 1 that are deliberate, with the reason
    # ItemReview details popover: full selectable path in a read-only details view, wrapped on purpose.
    "ItemReview.swift": {3},
}

fails = []

for f in sorted(SRC.glob("*.swift")):
    if f.name.endswith("Checks.swift"):
        continue
    text = f.read_text()
    for i, line in enumerate(text.splitlines(), 1):
        if f.name == "SpacelyzerApp.swift" and HARNESS_LINE.search(line):
            continue
        for m in STRING_LITERAL.finditer(line):
            b = BRITISH.search(m.group(1))
            if b:
                fails.append(f"{f.name}:{i}: British spelling '{b.group(0)}' in user-visible string")
        lm = re.search(r"\.lineLimit\((\d+)\)", line)
        if lm and int(lm.group(1)) > 1 and int(lm.group(1)) not in LINELIMIT_ALLOWLIST.get(f.name, set()):
            fails.append(f"{f.name}:{i}: lineLimit({lm.group(1)}) wraps instead of truncating (AGENTS.md: never wrap)")

for name, needle in SHEET_VIEWS.items():
    body = (SRC / name).read_text()
    if needle not in body or "dismiss" not in body:
        fails.append(f"{name}: sheet is missing its visible Done/dismiss affordance")

# Batch-4 pins: the fixes below must not regress.
CONTENT = (SRC / "ContentView.swift").read_text()
APP_MODEL = (SRC / "AppModel.swift").read_text()
TREEMAP = (SRC / "TreemapView.swift").read_text()

if '.alert("Spacelyzer"' in CONTENT:
    fails.append('ContentView.swift: removal alert titled with the app name (must name the situation)')
if "removalAlertTitle" not in CONTENT or "removalAlertTitle" not in APP_MODEL:
    fails.append("removal alert: outcome title (Moved to Trash / Put Back / Not Moved) is missing")
if 'TextField("extension"' not in CONTENT:
    fails.append('ContentView.swift: extension filter lost its "extension" placeholder')
if 'TextField("ext"' in CONTENT:
    fails.append('ContentView.swift: cryptic "ext" placeholder is back')
for name, body in (("TreemapView.swift", TREEMAP), ("ContentView.swift", CONTENT)):
    if '"Check on disk…"' in body:
        fails.append(f"{name}: ellipsis on Check on disk (it opens its popover directly, no further input)")

# Outcome-to-title mapping: the removal alert title comes from the tracked outcome, not message text.
if "enum RemovalReportKind" not in APP_MODEL or 'case .uncertain: return "Removal Result"' not in APP_MODEL:
    fails.append("AppModel.swift: tracked removal outcome (moved/putBack/notMoved/uncertain) is missing")
bare = [l.strip() for l in APP_MODEL.splitlines()
        if re.search(r"(?<!\w)removalMessage = ", l) and "reportRemoval(" not in l]
if bare != ["removalMessage = message"]:
    fails.append(f"AppModel.swift: removalMessage set outside reportRemoval: {bare}")
if "removalReportKind" not in APP_MODEL:
    fails.append("AppModel.swift: removal outcome is not tracked (removalReportKind missing)")

# AGENTS.md: labels truncate in the middle, never wrap or clip. Head truncation hides the start of a path.
HEAD_TRUNC_ALLOWLIST = set()  # file names allowed to keep .truncationMode(.head), with a reason noted here
for f in sorted(SRC.glob("*.swift")):
    if f.name.endswith("Checks.swift") or f.name in HEAD_TRUNC_ALLOWLIST:
        continue
    for i, line in enumerate(f.read_text().splitlines(), 1):
        if ".truncationMode(.head)" in line:
            fails.append(f"{f.name}:{i}: head truncation (AGENTS.md: truncate middle)")

# Harness drift pin: the demo harness finds the extension field by its placeholder string;
# every placeholderString literal in the harness must match the product placeholder.
APP_HARNESS = (SRC / "SpacelyzerApp.swift").read_text()
ext_ph = re.search(r'TextField\("([^"]+)", text: \$model\.filterExt\)', CONTENT)
if not ext_ph:
    fails.append("ContentView.swift: extension filter TextField not found for the harness pin")
else:
    ph = ext_ph.group(1)
    harness_ph = re.findall(r'placeholderString[^\n"]*== "([^"]+)"', APP_HARNESS)
    if not harness_ph or any(h != ph for h in harness_ph):
        fails.append(f"SpacelyzerApp.swift: extension-field placeholder lookups {harness_ph} drifted from the product placeholder {ph!r}")

if fails:
    print("UI COPY CHECK FAILED:")
    for x in fails:
        print(" -", x)
    sys.exit(1)
print(f"UI copy check passed: US English, {len(SHEET_VIEWS)} sheets with Done, no wrapping labels")
