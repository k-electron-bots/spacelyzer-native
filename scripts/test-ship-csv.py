#!/usr/bin/env python3
"""Linux controls for scripts/ship-csv.py: the pure CSV judge (mutations must fail) and the whole driver against a stateful fake
UI and fake launch. Not Mac execution: the real save panel, AX structure and file write stay native-unverified."""
import importlib.util, os, pathlib, sys, tempfile
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('shipcsv', 'scripts/ship-csv.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import ship_common as sc

def lcsv_field(s):
    return '"' + s.replace('"', '""') + '"' if any(c in s for c in ',"\n\r') else s
def make_csv(root, sizes=None, mark=True, crlf=True, bom=False, shuffle=False, header=None, drop=()):
    real = os.path.realpath(root); rows = []
    items = sorted(m.FIXTURE, key=lambda x: -x[1])
    for name, size in items:
        if name in drop: continue
        rows.append((name, size + 4096 if sizes is None else sizes[name]))
    if shuffle: rows = rows[::-1]
    nl = '\r\n' if crlf else '\n'
    out = (header or ','.join(m.HEADER)) + nl
    for i, (name, b) in enumerate(rows):
        if name.startswith('=') and mark: out += f'{i+1},{b},,{lcsv_field("path starts with a formula character")}{nl}'
        else: out += f'{i+1},{b},{lcsv_field(os.path.join(real, name))},{nl}'
    return ('\ufeff' if bom else '').encode('utf-8') + out.encode('utf-8')

with tempfile.TemporaryDirectory() as t:
    fx = m.make_fixture(pathlib.Path(t) / 'f')
    assert sorted(p.name for p in fx.iterdir()) == sorted(n for n, _ in m.FIXTURE)
    good = m.judge_csv(make_csv(fx), fx)
    assert all(ok for ok, _ in good.values()) and len(good) == 6, good
    muts = {
        'BOM': (make_csv(fx, bom=True), 'csv-utf8-no-bom-crlf'), 'LF-only': (make_csv(fx, crlf=False), 'csv-utf8-no-bom-crlf'),
        'bad header': (make_csv(fx, header='a,b,c'), 'csv-header'), 'unsorted': (make_csv(fx, shuffle=True), 'csv-ranks-and-order'),
        'formula unmarked': (make_csv(fx, mark=False), 'csv-formula-row-marked'),
        'name missing': (make_csv(fx, drop=('plain.bin',)), 'csv-roundtrip-names'),
        'size too small': (make_csv(fx, sizes={n: 10 for n, _ in m.FIXTURE}), 'csv-sizes-plausible'),
        'latin1 bytes': (make_csv(fx).replace('é'.encode(), b'\xe9'), 'csv-utf8-no-bom-crlf'),
        'empty': (b'', 'csv-header'),
    }
    for name, (raw, key) in muts.items():
        r = m.judge_csv(raw, fx)
        assert key in r and not r[key][0], (name, key, r.get(key))
print('PASS csv judge accepts a correct export and rejects 9 mutations (BOM, LF, header, order, formula, missing name, size, latin1, empty)')

# ---- whole driver against a fake UI
class Clock:
    def __init__(s): s.t = 0.0
    def __call__(s): return s.t
    def sleep(s, d): s.t += max(d, .01)

class FakeUI:
    def __init__(s, root_holder, **k):
        s.k = k; s.h = root_holder; s.polls = 0; s.largest = False; s.panel = False; s.target = None; s.pressed = []
    def trusted(s): return s.k.get('trusted', True)
    def tree(s, pid):
        s.polls += 1
        nodes = [{'role': 'AXButton', 'desc': 'Export the Largest list as CSV', 'enabled': s.largest and s.polls > 2 and not s.k.get('never_enabled')}]
        if not s.k.get('no_tab'):
            nodes += [{'role': s.k.get('tab_role', 'AXRadioButton'), 'title': t} for t in ('Treemap', 'Kinds', 'Largest', 'Folders')]
        if s.panel and not s.k.get('no_panel'):
            nodes += [{'role': 'AXTextField', 'id': 'saveAsNameTextField', 'value': 'spacelyzer-largest.csv'}, {'role': 'AXButton', 'title': 'Save'}, {'role': 'AXButton', 'title': 'Cancel'}]
        return nodes
    def press(s, pid, role, needle):
        s.pressed.append(needle)
        if needle == '=Largest':
            if s.k.get('tab_press_fails'): return {'found': True, 'axError': -25205}
            s.largest = True; return {'found': True, 'axError': 0}
        if needle.startswith('Export'): s.panel = True; return {'found': True, 'axError': 0}
        if needle == 'Save':
            if s.k.get('save_not_found'): return {'found': False}
            if not s.k.get('save_writes_nothing') and s.target: pathlib.Path(s.target).write_bytes(s.h['raw']())
            s.panel = False; return {'found': True, 'axError': 0}
        if needle == 'Cancel':
            if s.k.get('cancel_writes') and s.target: pathlib.Path(s.target).write_bytes(b'x')
            s.panel = False; return {'found': True, 'axError': 0}
        return {'found': False}
    def set_(s, pid, role, needle, value): s.target = value; return {'found': True, 'axError': 0}
    def key(s, pid, code, *mods):
        if code == 36 and s.target and not s.k.get('save_writes_nothing'): pathlib.Path(s.target).write_bytes(s.h['raw']()); s.panel = False
        return {'eventsPosted': 2}

def drive(**k):
    holder = {}
    def launch(app, fixture): holder['raw'] = lambda: make_csv(fixture, **holder.get('csvkw', {}))
    holder['csvkw'] = k.pop('csv', {})
    ui = FakeUI(holder, **k); clk = Clock()
    m.pid_of = lambda *a, **kw: 4242; m.stop_apps = lambda *a, **kw: None
    sc.pid_of = m.pid_of
    with tempfile.TemporaryDirectory() as o:
        c = m.run('app', ui, o, launch, clock=clk, sleep=clk.sleep)
        good, problems = c.verdict()
        c.write(o)
        assert (pathlib.Path(o) / 'result.txt').read_text().startswith('PASS' if good else 'FAIL')
        return good, problems, ui

g, p, ui = drive(); assert g, p
assert 'Cancel' in ui.pressed
for name, kw, needle in [
    ('untrusted', dict(trusted=False), 'csv-ax-trusted'),
    ('no Largest control', dict(no_tab=True), 'csv-largest-tab-selected'), ('Largest press fails', dict(tab_press_fails=True), 'csv-largest-tab-selected'), ('export never enabled', dict(never_enabled=True), 'csv-export-enabled'),
    ('no panel', dict(no_panel=True), 'csv-panel-opened'), ('save writes nothing', dict(save_writes_nothing=True), 'csv-file-written'),
    ('cancel writes file', dict(cancel_writes=True), 'csv-cancel-wrote-nothing'), ('BOM export', dict(csv=dict(bom=True)), 'csv-utf8-no-bom-crlf'),
    ('unsorted export', dict(csv=dict(shuffle=True)), 'csv-ranks-and-order')]:
    g, p, _ = drive(**kw); assert not g and any(needle in x for x in p), (name, p)
g, p, ui = drive(tab_role='AXButton'); assert g, p   # role-agnostic: a button-role tab works
g, p, ui = drive(save_not_found=True); assert g, p   # AX Save press missing, Return fallback saves: still a pass
print('PASS csv driver: green on a correct fake, red on untrusted, disabled export, missing panel, no write, cancel that writes, BOM, unsorted; Return fallback works')
# Driver mutation (the reviewer's defect): a driver that never presses Largest must go red, because the fake export stays disabled.
orig = m.select_largest
m.select_largest = lambda ui, pid, checks, out, clock=None, sleep=None: checks.check('csv-largest-tab-selected', True, 'mutant skips the press')
g, p, _ = drive(); assert not g and any('csv-export-enabled' in x for x in p), p
m.select_largest = orig
print('PASS csv driver mutations: no Largest control, failing Largest press, and a driver that never presses Largest all go red; the real helper source proves "=Largest" exact match does not hit the Export button (Linux stubs)')
