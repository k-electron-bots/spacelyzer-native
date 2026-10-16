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

if fails:
    print("UI COPY CHECK FAILED:")
    for x in fails:
        print(" -", x)
    sys.exit(1)
print(f"UI copy check passed: US English, {len(SHEET_VIEWS)} sheets with Done, no wrapping labels")
