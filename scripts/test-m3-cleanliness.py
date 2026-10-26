#!/usr/bin/env python3
"""Linux compile + behavior control for the REAL AX failure ledger in scripts/m3-interaction-bench.swift (extracted verbatim). A failing diagnostic-dump read must NOT flip status;
a failing per-key (non-dump) read still does; inconclusive events still do. Also checks the wiring text (dump scope opened and closed around the dump block). Not a Mac result."""
import pathlib, subprocess, os, tempfile
src = pathlib.Path('scripts/m3-interaction-bench.swift').read_text()
a = src.index('// BEGIN pure AX failure ledger'); b = src.index('// END pure AX failure ledger'); block = src[a:b]
i0 = src.index('ledger.inDump = footerMatches.count != 1'); i1 = src.index('ledger.inDump = false')
dump = src[i0:i1]
assert 'footerEntry(' in dump and 'let strict = footerMatches.filter' in dump, 'dump reads must sit inside the dump scope'
assert src.index('guard footers.count == 1, let footer') > i1 and src.index('func footerRead') > i1, 'scope closed before footer reads and the key loop'
assert 'let clean = ledger.clean(inconclusive: inconclusive)' in src and 'ledger.note(site, err.rawValue)' in src
test = 'import Foundation\n' + block + '''
var bad = 0
func check(_ c: Bool, _ m: String) { if !c { print("FAIL " + m); bad += 1 } }
var l = AxLedger()
l.inDump = true; l.note("attr:AXSubrole", -25200); l.inDump = false
check(l.clean(inconclusive: 0), "a failing dump read must not flip the status")
check(l.dumpFailures == 1 && l.failures == 0 && l.dumpSites == ["attr:AXSubrole(err=-25200)"], "dump failure recorded separately with its site")
l.note("attr:AXValue", -25200)
check(!l.clean(inconclusive: 0), "a per-key read failure still fails the leg")
check(l.failures == 1 && l.sites == ["attr:AXValue(err=-25200)"], "per-key failure counted with its site")
var m = AxLedger()
check(m.clean(inconclusive: 0), "clean when nothing failed")
check(!m.clean(inconclusive: 1), "inconclusive events still fail the leg")
if bad > 0 { exit(1) }
print("ok")
'''
d = tempfile.mkdtemp(); f = pathlib.Path(d) / 'main.swift'; f.write_text(test)
swift = pathlib.Path(os.environ.get('SWIFT_BIN', '/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin')) / 'swiftc'
r = subprocess.run([str(swift), str(f), '-o', d + '/t'], capture_output=True, text=True); assert r.returncode == 0, r.stderr
o = subprocess.run([d + '/t'], capture_output=True, text=True)
assert o.returncode == 0 and 'ok' in o.stdout, o.stdout
print('PASS m3 AX failure ledger: dump read failures do not flip status, per-key failures and inconclusive events still do (real ledger code compiled on Linux; dump scope checked by text; not a Mac result)')
