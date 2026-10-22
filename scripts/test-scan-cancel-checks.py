#!/usr/bin/env python3
"""Linux-provable wiring for ScanCancelChecks: the suite exists with its three declared names, is
invoked once in the main check sequence, is required by the ordering driver, is listed in the
manifest's SUITES, overrides NO seams (the cancel paths are what make it real), and carries the
safety gate (canonical temp prefix + spz-cxl- marker) plus explicit responsiveness bounds. Exits 1
on any failure."""
import sys
f = 'Sources/Spacelyzer/ScanCancelChecks.swift'
app = open('Sources/Spacelyzer/SpacelyzerApp.swift').read()
body = open(f).read()
names = ["scan-cancel-stops-promptly-and-publishes-partial-tree",
         "scan-cancel-before-progress-returns-promptly",
         "rescan-after-model-cancel-is-complete"]
ok = True
def need(cond, msg):
    global ok
    if not cond: print('FAIL:', msg); ok = False
need('#if SPZ_CI_TESTS' in body, 'suite must be test-only gated')
for n in names:
    need(body.count('Check.expect("%s"' % n) >= 1, 'at least one Check.expect for %s (mutually exclusive emission sites keep the exactly-once-per-run rule)' % n)
    need('"%s",' % n in body, '%s must appear in the names fallback array' % n)
    need('"%s",' % n in app, '%s missing from ordering-driver required list' % n)
need(app.count('await ScanCancelChecks.run()') == 1, 'suite must be invoked exactly once')
man = open('scripts/check-ordering-manifest.py').read()
need("'ScanCancelChecks'" in man, 'suite missing from manifest SUITES')
for seam in ['trashItem =', 'identityCheck =', 'restoreItem =', 'restoreCollisionProbe =']:
    need(seam not in body, 'suite must NOT override the %s seam - real paths only' % seam)
for el in ['temporaryDirectory', 'spz-cxl-', 'hasPrefix(tmpRoot', 'realpath(', 'wasCancelled',
           'm.cancel()', 's2.cancel()', 'wait(10)', 'wait(60)', 'nodeCount']:
    need(el in body, 'missing required element: %s' % el)
print('wiring OK' if ok else 'wiring FAILED')
sys.exit(0 if ok else 1)
