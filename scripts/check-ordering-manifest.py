#!/usr/bin/env python3
"""Source-only, run-independent check: the OrderingDriver.required list must equal the check names the
ordering/coherence suites declare in source. Never reads a run log. Suites live across Sources/**/*.swift;
a suite's declared names are its Check.expect("...") literals plus its `let names = [...]` arrays (the
fixture-failure fallback emission lists). Dynamic names (containing \( ) are expanded below by hand and
must be edited with the check. Exit 1 on any difference."""
import re, sys, glob
app = open('Sources/Spacelyzer/SpacelyzerApp.swift').read()
m = re.search(r'static let required: \[String\] = \[(.*?)\n    \]', app, re.S)
required = re.findall(r'"([^"]+)"', m.group(1))
dup = {n for n in required if required.count(n) > 1}
SUITES = ['PublicationRegression', 'CommitOrderingRegression', 'ZeroMatchRegression', 'AsyncRemovalRegression',
          'MountedViewRegression', 'MountedOutlineRegression', 'BatchRemovalChecks', 'BatchRemovalExecutionChecks',
          'BatchUndoChecks', 'DuplicatesChecks', 'DuplicatesRemovalChecks', 'ExclusionsChecks', 'FullDiskAccessChecks',
          'IdentityGateChecks', 'ItemReviewChecks', 'MultiSelectChecks', 'OutlineSelectionSyncChecks',
          'QuickLookBatchChecks', 'QuickLookChecks', 'RemovalHistoryChecks', 'SkippedListChecks', 'VolumeChecks']
files = {f: open(f).read() for f in glob.glob('Sources/**/*.swift', recursive=True)}
declared, dynamic = set(), []
for s in SUITES:
    body = None
    for f, txt in files.items():
        b = re.search(r'enum %s\b.*?\n}\n' % s, txt, re.S)
        if b:
            body = b.group(0)
            break
    if body is None:
        print('suite not found', s); sys.exit(1)
    for n in re.findall(r'Check\.expect\("([^"]+)"', body):
        (dynamic.append(n) if '\\(' in n else declared.add(n))
    for arr in re.findall(r'(?:static )?let names = \[(.*?)\]', body, re.S):
        declared.update(re.findall(r'"([^"]+)"', arr))
expanded = set()
for n in dynamic:
    if 'async-removal-commit-\\(label)' in n:
        expanded |= {n.replace('\\(label)', l) for l in ('busy', 'stale')}
    elif 'race-old-\\(stage)' in n:
        expanded |= {n.replace('\\(stage)', l) for l in ('scan-progress', 'scan-completion')}
    else:
        print('UNEXPANDED dynamic name (edit this script and required together):', n); sys.exit(1)
declared |= expanded
# Names emitted ONLY as a failure (setup could not run). Deliberately not required; the driver reports them as unlisted FAIL.
declared -= {'async-removal-fixture', 'commit-order-fixture-ready', 'commit-order-removal-accepted'}
req = set(required)
ok = True
for n in sorted(declared - req): print('declared in source, not in required:', n); ok = False
for n in sorted(req - declared): print('required, not declared in source:', n); ok = False
for n in sorted(dup): print('duplicate in required:', n); ok = False
print('OK %d required == %d declared' % (len(req), len(declared)) if ok else 'MISMATCH')
sys.exit(0 if ok else 1)
