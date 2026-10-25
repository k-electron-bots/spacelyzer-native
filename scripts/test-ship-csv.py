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

INV = {v: k for k, v in m.KEYCODES.items()}

class FakeUI:
    """Models the real panel: the name field only accepts what the fake is told it accepts (paste / real keys / go-to-folder).
    A successful Save shows the export alert sheet; the app is 'frontmost' only while no alert is up (run 40232750584)."""
    def __init__(s, root_holder, **k):
        s.h = root_holder; s.polls = 0; s.largest = False; s.panel = False; s.pressed = []; s.name = None; s.selected = False
        s.sdir = k.pop('sdir'); s.k = k; s.clip = ''; s.alert = False; s.goto = False; s.goto_text = ''; s.folder = None; s.keylog = []; s.clicked = 0
        s.default = 'spacelyzer-largest'
    def trusted(s): return s.k.get('trusted', True)
    def tree(s, pid):
        s.polls += 1
        nodes = [] if s.k.get('no_export_button') else [{'role': 'AXButton', 'desc': s.k.get('export_desc', 'Export CSV'), 'enabled': s.largest and s.polls > 2 and not s.k.get('never_enabled')}]
        if not s.k.get('no_tab'):
            nodes += [{'role': s.k.get('tab_role', 'AXRadioButton'), 'title': t} for t in ('Treemap', 'Kinds', 'Largest', 'Folders')]
        if s.panel and not s.k.get('no_panel'):
            nodes += [{'role': 'AXTextField', 'id': 'saveAsNameTextField', 'value': (os.path.splitext(os.path.basename(s.name))[0] if os.path.isabs(s.name) else s.name) if s.name is not None else s.default}, {'role': 'AXButton', 'title': 'Save'}, {'role': 'AXButton', 'title': 'Cancel'}]
        if s.alert:
            nodes += [{'role': 'AXSheet', 'desc': 'alert'}, {'role': 'AXStaticText', 'value': 'Exported 6 items (UTF-8, no byte order mark).'}]
        return nodes
    def press(s, pid, role, needle):
        s.pressed.append(needle)
        if needle == '=Largest':
            if s.k.get('tab_press_fails'): return {'found': True, 'axError': -25205}
            s.largest = True; return {'found': True, 'axError': 0}
        if needle.lstrip('=').startswith('Export'): s.panel = True; s.name = None; s.selected = False; return {'found': True, 'axError': 0}
        if needle.lstrip('=') == 'Save':
            if s.k.get('save_not_found'): return {'found': False}
            s.do_save(); return {'found': True, 'axError': 0}
        if needle == 'Cancel':
            if s.k.get('cancel_writes'): s.write_to(pathlib.Path(s.sdir) / 'cancelled.csv', b'x')
            s.panel = False; s.name = None; s.selected = False; return {'found': True, 'axError': 0}
        return {'found': False}
    def press_sheet(s, pid):
        if not s.alert: return {'sheet': False, 'found': False, 'axError': 0}
        if not s.k.get('alert_stuck'): s.alert = False
        return {'sheet': True, 'found': True, 'axError': 0}
    def click_el(s, pid, role, needle): s.clicked += 1; return {'found': True, 'clicked': True, 'x': 10.0, 'y': 20.0}
    def focus_el(s, pid, role, needle): return {'found': True, 'axError': 0}
    def write_to(s, dest, data=None): dest.write_bytes(data if data is not None else s.h['raw']())
    def do_save(s):
        if s.k.get('save_writes_nothing'): s.panel = False; return
        nm = s.name if s.name is not None else s.default
        if os.path.isabs(nm): nm = os.path.basename(nm)   # real panel keeps only the NAME of a pasted full path
        dest = pathlib.Path(s.folder or s.sdir) / ('spacelyzer-largest.csv' if '/' in nm else (nm if nm.endswith('.csv') else nm + '.csv'))
        s.write_to(dest); s.panel = False
        if not s.k.get('no_alert'): s.alert = True
    def key_tap(s, pid, code, *mods):
        s.keylog.append((code, mods)); mods = set(mods)
        if s.goto:
            if code == m.KEY_A and 'cmd' in mods: s.goto_text = ''
            elif code == m.KEY_V and 'cmd' in mods: s.goto_text = s.clip
            elif code == m.KEY_RETURN:
                if s.k.get('accept_goto'): s.folder = s.goto_text
                s.goto = False
            return {'eventsPosted': 2}
        if code == m.KEY_G and mods == {'cmd', 'shift'}: s.goto = True; return {'eventsPosted': 2}
        if code == m.KEY_A and 'cmd' in mods: s.selected = True
        elif code == m.KEY_V and 'cmd' in mods:
            if s.k.get('accept_paste'): s.name = s.clip if s.selected else (s.name or s.default) + s.clip
            s.selected = False
        elif code == m.KEY_RETURN:
            if s.alert and not s.k.get('alert_stuck'): s.alert = False
            elif s.panel and not s.k.get('save_writes_nothing'): s.do_save()
        elif code in INV and s.k.get('accept_keys') and not (mods - {'shift'}):
            ch = INV[code].upper() if 'shift' in mods and INV[code].isalpha() else ('_' if 'shift' in mods and INV[code] == '-' else INV[code])
            s.name = ch if s.selected else (s.name or s.default) + ch
            s.selected = False
        return {'eventsPosted': 2}
    key = key_tap
    def frontmost(s): return 'Finder' if (s.alert and s.k.get('front_by_alert', True)) else s.k.get('front', 'Spacelyzer')

def drive(**k):
    holder = {}
    def launch(app, fixture): holder['raw'] = lambda: make_csv(fixture, **holder.get('csvkw', {}))
    holder['csvkw'] = k.pop('csv', {})
    k.setdefault('accept_paste', True); k.setdefault('accept_goto', True)
    sd = tempfile.mkdtemp(); front = k.pop('front', None)
    ui = FakeUI(holder, sdir=sd, **({'front': front} if front else {}), **k); clk = Clock()
    m.pid_of = lambda *a, **kw: 4242; m.stop_apps = lambda *a, **kw: None
    sc.pid_of = m.pid_of
    with tempfile.TemporaryDirectory() as o:
        c = m.run('app', ui, o, launch, clock=clk, sleep=clk.sleep, frontmost=ui.frontmost, strays=[pathlib.Path(sd) / n for n in ('spacelyzer-largest.csv', 'export.csv', 'cancelled.csv')],
                  clip=lambda t: setattr(ui, 'clip', t), activate=lambda pid: 'activate ok')
        drive.checks = c
        good, problems = c.verdict()
        c.write(o)
        assert (pathlib.Path(o) / 'result.txt').read_text().startswith('PASS' if good else 'FAIL')
        drive.out = sorted(os.listdir(o))
        return good, problems, ui

g, p, ui = drive(); assert g, p
rows = str(drive.checks.rows)
assert 'Cancel' in ui.pressed and ui.clicked == 2 and all(k in rows for k in ('csv-name-click', 'csv-name-readback', 'method=paste', 'csv-post-save', 'csv-post-save-alert', 'csv-post-save-alert-dismissed', 'csv-pre-cancel-state', 'csv-new-csv-files', 'csv-cancel-panel-closed')), rows
assert 'method=keys' not in rows and 'csv-name-goto' in rows and 'name_landed=True' in rows, rows   # keys skipped after a landed paste; go-to-folder always runs on the save leg
assert ui.keylog[0] == (m.KEY_A, ('cmd',)) and (m.KEY_V, ('cmd',)) in ui.keylog
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

# The entry ladder. Each fake accepts only one way of getting the path into the field.
g, p, ui = drive(accept_paste=False, accept_keys=True); assert g, p
rows = str(drive.checks.rows); assert 'method=paste' in rows and 'method=keys' in rows and 'name_landed=True' in rows, rows
assert [c for c, mo in ui.keylog if c != m.KEY_A and c != m.KEY_V and c != m.KEY_RETURN] and all(isinstance(c, int) for c, _ in ui.keylog)
# keys use real keycodes only: the uppercase/underscore characters need shift, digits and / . - do not
assert m.keys_for('/a_B.c-9') == [(44, ()), (0, ()), (27, ('shift',)), (11, ('shift',)), (47, ()), (8, ()), (27, ()), (25, ())], m.keys_for('/a_B.c-9')
assert m.landed('export', '/t/dest/export.csv') and m.landed('export.csv', '/t/dest/export.csv') and m.landed('/t/dest/export.csv', '/t/dest/export.csv') and not m.landed('spacelyzer-largest', '/t/dest/export.csv') and not m.landed('', '/t/dest/export.csv') and not m.landed(None, '/t/dest/export.csv')
assert m.keys_for('a b') is None and m.keys_for('\u00e9') is None
# go-to-folder rung: neither paste nor keys land; the default name goes to dest and the judge still reads the bytes at dest/spacelyzer-largest.csv
g, p, ui = drive(accept_paste=False, accept_keys=False, accept_goto=True); assert g, p
rows = str(drive.checks.rows); assert 'name_landed=False' in rows and 'method=keys' in rows and 'dest/spacelyzer-largest.csv' in rows, rows
# Run 40238740556: the panel ignores the folder of a pasted full path, so without go-to-folder the file lands in the default folder: red with the stray named.
g, p, ui = drive(accept_goto=False); assert not g and any('csv-file-written' in x for x in p), p
assert 'csv-stray-files' in str(drive.checks.rows) and 'export.csv' in str(drive.checks.rows), drive.checks.rows
# nothing lands anywhere: red on csv-file-written, the stray diagnostic names the default-folder file, and every rung left a readback NOTE
g, p, ui = drive(accept_paste=False, accept_keys=False, accept_goto=False)
assert not g and any('csv-file-written' in x for x in p), p
rows = str(drive.checks.rows); assert 'csv-stray-files' in rows and 'spacelyzer-largest.csv' in rows and 'method=paste' in rows and 'method=keys' in rows and 'csv-name-goto' in rows, rows
# driver mutation: no select-all, so the paste appends to the default name and the file lands elsewhere
real_gk = m.guarded_key
m.guarded_key = lambda ui, pid, code, mods, tap, fm: ({'eventsPosted': 2}, 'session-tap', 'Spacelyzer') if code == m.KEY_A else real_gk(ui, pid, code, mods, tap, fm)
g, p, ui = drive(accept_goto=False); assert not g and any('csv-file-written' in x for x in p), p
g, p, ui = drive(); assert g, p   # with go-to-folder the default-name fallback still lands dest/spacelyzer-largest.csv
m.guarded_key = real_gk
# not frontmost: nothing is posted at all
g, p, ui = drive(front='Finder', front_by_alert=False); assert not g and ui.keylog == [] and any('csv-panel-saved' in x and 'refused' in x for x in p), (p, ui.keylog)
g, p, ui = drive(front='Open and Save Panel Service (Spacelyzer)', front_by_alert=False); assert g, p
g, p, ui = drive(cancel_writes=True); assert not g and any('csv-cancel-wrote-nothing' in x for x in p), p
# Alert handling: the export alert sheet must NOT read as an open panel, it is recorded and dismissed, and the cancel leg then works.
assert m.panel_gone([{'role': 'AXWindow', 'subrole': 'AXStandardWindow'}, {'role': 'AXSheet'}]) and m.has_alert([{'role': 'AXSheet'}])
assert not m.panel_gone([{'role': 'AXTextField', 'id': 'saveAsNameTextField'}]) and not m.panel_gone([{'role': 'AXWindow', 'subrole': 'AXDialog'}])
g, p, ui = drive(); rows = str(drive.checks.rows)
assert g and 'alert_present=True' in rows and 'panel_closed=True' in rows and "gone=True" in rows and 'alert_gone=True' in rows, rows
# mutation: the alert never goes away, so the cancel leg is refused (Finder frontmost) and goes red
g, p, ui = drive(alert_stuck=True)
assert not g and any('csv-cancel-wrote-nothing' in x and 'refused' in x for x in p), p
assert 'gone=False' in str(drive.checks.rows) and 'alert_gone=False' in str(drive.checks.rows), drive.checks.rows
print('PASS csv entry ladder: click, real-keycode Cmd-A, paste, real US keys, go-to-folder, each skipped once the read-back matches; nothing-lands is red with the stray diagnostic; no select-all is red; not-frontmost posts nothing; alert sheet is not a panel, is dismissed before the cancel leg, and a stuck alert goes red')

# Diagnostics are non-gating NOTEs: pure helpers, and no new required names.
assert m.panel_gone([{'role': 'AXWindow', 'subrole': 'AXStandardWindow'}]) and not m.panel_gone([{'role': 'AXWindow', 'subrole': 'AXDialog'}]) 
assert 'Export failed' in m.status_text([{'role': 'AXStaticText', 'value': 'Export failed: x'}, {'role': 'AXButton', 'title': 'Save'}]) and 'Save' not in m.status_text([{'role': 'AXButton', 'title': 'Save'}])
assert m.REQUIRED == ['csv-ax-trusted', 'csv-app-launched', 'csv-largest-tab-selected', 'csv-toolbar-not-overflowed', 'csv-export-enabled', 'csv-panel-opened', 'csv-panel-saved', 'csv-file-written', 'csv-utf8-no-bom-crlf', 'csv-header', 'csv-ranks-and-order', 'csv-roundtrip-names', 'csv-sizes-plausible', 'csv-formula-row-marked', 'csv-cancel-panel-opened', 'csv-cancel-wrote-nothing'], m.REQUIRED
print('PASS csv diagnostics: post-save panel-closed plus main-window text, new *.csv in dest and Documents, cancel-panel-closed are NOTEs; the required names are unchanged')
