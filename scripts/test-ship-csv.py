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
        s.k = k; s.h = root_holder; s.polls = 0; s.largest = False; s.panel = False; s.target = None; s.pressed = []; s.name = None; s.selected = False; s.typed = []; s.sdir = k.pop('sdir', None); s.k = k
    def trusted(s): return s.k.get('trusted', True)
    def tree(s, pid):
        s.polls += 1
        nodes = [] if s.k.get('no_export_button') else [{'role': 'AXButton', 'desc': s.k.get('export_desc', 'Export CSV'), 'enabled': s.largest and s.polls > 2 and not s.k.get('never_enabled')}]
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
        if needle.lstrip('=').startswith('Export'): s.panel = True; return {'found': True, 'axError': 0}
        if needle.lstrip('=') == 'Save':
            if s.k.get('save_not_found'): return {'found': False}
            if not s.k.get('save_writes_nothing'): s.write_saved()
            s.panel = False; return {'found': True, 'axError': 0}
        if needle == 'Cancel':
            if s.k.get('cancel_writes'): s.write_saved(b'x', cancel=True)
            s.panel = False; s.name = None; s.selected = False; return {'found': True, 'axError': 0}
        return {'found': False}
    def set_(s, pid, role, needle, value): s.target = value; return {'found': True, 'axError': 0}   # an AX value write does NOT commit (run 40229545863)
    def focus_el(s, pid, role, needle): return {'found': True, 'axError': 0}
    def type_text(s, pid, text):
        s.typed.append(text)
        s.name = text if s.selected else 'spacelyzer-largest.csv' + text    # without Cmd-A the typing lands after the default name
        return {'cmd': 'typetext', 'units': len(text.encode('utf-16-le')) // 2}
    def write_saved(s, data=None, cancel=False):
        ok = s.name and os.path.isabs(s.name) and not s.name.endswith('spacelyzer-largest.csv' + (s.typed[-1] if s.typed else ''))
        dest = pathlib.Path(s.name) if ok else pathlib.Path(s.sdir) / ('cancelled.csv' if cancel else 'spacelyzer-largest.csv')   # default name in the default folder
        dest.write_bytes(data if data is not None else s.h['raw']())
    def key_tap(s, pid, code, *mods): return s.key(pid, code, *mods)
    def key(s, pid, code, *mods):
        if code == m.KEY_A and 'cmd' in mods: s.selected = True
        if code == 36 and not s.k.get('save_writes_nothing'): s.write_saved(); s.panel = False
        return {'eventsPosted': 2}

def drive(**k):
    holder = {}
    def launch(app, fixture): holder['raw'] = lambda: make_csv(fixture, **holder.get('csvkw', {}))
    holder['csvkw'] = k.pop('csv', {})
    sd = tempfile.mkdtemp(); front = k.pop('front', 'Spacelyzer')
    ui = FakeUI(holder, sdir=sd, **k); clk = Clock()
    m.pid_of = lambda *a, **kw: 4242; m.stop_apps = lambda *a, **kw: None
    sc.pid_of = m.pid_of
    with tempfile.TemporaryDirectory() as o:
        c = m.run('app', ui, o, launch, clock=clk, sleep=clk.sleep, frontmost=lambda: front, strays=[pathlib.Path(sd) / n for n in ('spacelyzer-largest.csv', 'export.csv', 'cancelled.csv')])
        drive.checks = c
        good, problems = c.verdict()
        c.write(o)
        assert (pathlib.Path(o) / 'result.txt').read_text().startswith('PASS' if good else 'FAIL')
        return good, problems, ui

g, p, ui = drive(); assert g, p
assert 'Cancel' in ui.pressed and len(ui.typed) == 2 and all(os.path.isabs(t) for t in ui.typed), ui.typed
assert all(k in str(drive.checks.rows) for k in ('csv-name-readback', 'csv-post-save', 'csv-new-csv-files', 'csv-cancel-panel-closed')), drive.checks.rows
assert 'csv-name-readback' in str(drive.checks.rows) and 'path=session-tap' in str(drive.checks.rows)
for name, kw, needle in [
    ('untrusted', dict(trusted=False), 'csv-ax-trusted'),
    ('Export carries the old wrong description', dict(export_desc='Export the Largest list as CSV'), 'csv-toolbar-not-overflowed'), ('toolbar overflow hides Export', dict(no_export_button=True), 'csv-toolbar-not-overflowed'), ('no Largest control', dict(no_tab=True), 'csv-largest-tab-selected'), ('Largest press fails', dict(tab_press_fails=True), 'csv-largest-tab-selected'), ('export never enabled', dict(never_enabled=True), 'csv-export-enabled'),
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
calls = []
m.subprocess.run = lambda cmd, **kw: calls.append(cmd)
m.real_launch('A.app', '/tmp/fx')
assert 'SPZ_WINDOW_SIZE=1280x800' in calls[0] and 'SPZ_AUTOSCAN=/tmp/fx' in calls[0], calls
assert 'csv-toolbar-not-overflowed' in m.REQUIRED
print('PASS csv: the real launch sets SPZ_WINDOW_SIZE=1280x800; an Export button collapsed into the toolbar overflow goes red on the new required check csv-toolbar-not-overflowed')

# Run 40229545863 failure, modeled: an AX value write does not commit, so Save writes the default name in the default folder.
real_gt, real_gk = m.guarded_type, m.guarded_key
m.guarded_type = lambda ui, pid, text, fm: (ui.set_(pid, 'AXTextField', 'x', text) and {'units': len(text.encode('utf-16-le')) // 2}, 'Spacelyzer')
g, p, ui = drive(); assert not g and any('csv-file-written' in x for x in p), p
assert 'csv-stray-files' in str(drive.checks.rows) and 'spacelyzer-largest.csv' in str(drive.checks.rows), drive.checks.rows   # the diagnostic names where the file went
m.guarded_type = real_gt
m.guarded_key = lambda *a, **k: ({'eventsPosted': 2}, 'session-tap', 'Spacelyzer')            # driver mutation: no select-all, typing lands after the default name
g, p, ui = drive(); assert not g and any('csv-file-written' in x for x in p), p
m.guarded_key = real_gk
g, p, ui = drive(front='Finder'); assert not g and ui.typed == [] and any('csv-panel-saved' in x and 'refused' in x for x in p), (p, ui.typed)
g, p, ui = drive(cancel_writes=True); assert not g and any('csv-cancel-wrote-nothing' in x for x in p), p
g, p, ui = drive(front='Open and Save Panel Service (Spacelyzer)'); assert g, p
print('PASS csv entry: the target is typed through the session tap after focus and select-all and read back; an AX-set-only driver and a no-select-all driver both go red with the stray-file diagnostic naming the default-folder file; not-frontmost types nothing; a cancel that writes anywhere is red; the panel-service frontmost name is allowed')

# Diagnostics are non-gating NOTEs: pure helpers, and no new required names.
assert m.panel_gone([{'role': 'AXWindow', 'subrole': 'AXStandardWindow'}]) and not m.panel_gone([{'role': 'AXWindow', 'subrole': 'AXDialog'}]) and not m.panel_gone([{'role': 'AXSheet'}])
assert 'Export failed' in m.status_text([{'role': 'AXStaticText', 'value': 'Export failed: x'}, {'role': 'AXButton', 'title': 'Save'}]) and 'Save' not in m.status_text([{'role': 'AXButton', 'title': 'Save'}])
assert m.REQUIRED == ['csv-ax-trusted', 'csv-app-launched', 'csv-largest-tab-selected', 'csv-toolbar-not-overflowed', 'csv-export-enabled', 'csv-panel-opened', 'csv-panel-saved', 'csv-file-written', 'csv-utf8-no-bom-crlf', 'csv-header', 'csv-ranks-and-order', 'csv-roundtrip-names', 'csv-sizes-plausible', 'csv-formula-row-marked', 'csv-cancel-panel-opened', 'csv-cancel-wrote-nothing'], m.REQUIRED
print('PASS csv diagnostics: post-save panel-closed plus main-window text, new *.csv in dest and Documents, cancel-panel-closed are NOTEs; the required names are unchanged')
