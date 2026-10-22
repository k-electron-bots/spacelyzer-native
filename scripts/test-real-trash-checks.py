#!/usr/bin/env python3
"""Linux-provable wiring for RealTrashMoveChecks: the suite exists with its four declared names,
is invoked once in the main check sequence, is required by the ordering driver, is listed in the
manifest's SUITES, overrides NO seams (that is what makes the moves REAL), and carries the safety
gate (canonical temp prefix + spz-rtm- marker before any Trash call). Complements
check-ordering-manifest.py, which proves required == declared. Exits 1 on any failure."""
import re, sys
f = 'Sources/Spacelyzer/RealTrashMoveChecks.swift'
app = open('Sources/Spacelyzer/SpacelyzerApp.swift').read()
body = open(f).read()
names = ["real-trash-move-executes-and-journals", "real-trash-undo-restores-original",
         "real-trash-identity-replaced-refuses-move", "real-trash-restore-collision-keeps-both"]
ok = True
def need(cond, msg):
    global ok
    if not cond: print('FAIL:', msg); ok = False
need('#if SPZ_CI_TESTS' in body, 'suite must be test-only gated')
for n in names:
    need(body.count('Check.expect("%s"' % n) >= 1, 'at least one Check.expect for %s (mutually exclusive emission sites keep the exactly-once-per-run rule)' % n)
    need('"%s",' % n in body, '%s must appear in the names fallback array' % n)
    need('"%s",' % n in app, '%s missing from ordering-driver required list' % n)
need(app.count('await RealTrashMoveChecks.run()') == 1, 'suite must be invoked exactly once')
man = open('scripts/check-ordering-manifest.py').read()
need("'RealTrashMoveChecks'" in man, 'suite missing from manifest SUITES')
for seam in ['trashItem =', 'identityCheck =', 'restoreItem =', 'restoreCollisionProbe =']:
    need(seam not in body, 'suite must NOT override the %s seam - the seams are what make it real' % seam)
for guard in ['temporaryDirectory', 'spz-rtm-', 'hasPrefix(tmpRoot', 'realpath(', '.Trash', 'trashedLeftovers',
              'settleSurfaces', 'layoutPublished', 'requiredVersion == nil',
              'was replaced since the scan', 'something already exists at',
              'isExpectedFixtureTrashItem', '.putBack', '.notMoved',
              'options: .atomic', 'checkIdentity(', 'lstat(', 'st_ino', 'TrashedRef']:
    need(guard in body, 'missing safety-guard element: %s' % guard)
print('wiring OK' if ok else 'wiring FAILED')
sys.exit(0 if ok else 1)
