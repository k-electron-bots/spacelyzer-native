#!/usr/bin/env python3
"""Real save-panel CSV export check for the ship-candidate run. Launches the TEST-ONLY app on a disposable fixture, presses the
real Export CSV toolbar button, drives the real NSSavePanel through accessibility, then judges the file bytes. Also checks that
Cancel writes nothing. Mac execution is not proved by Linux tests."""
import argparse, csv, io, os, pathlib, random, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from ship_common import ALLOWED_FRONTMOST, Checks, Fail, HelperUI, find, guarded_key, pid_of, poll, real_activate, real_clip, real_frontmost, stop_apps

REQUIRED = ['csv-ax-trusted', 'csv-app-launched', 'csv-largest-tab-selected', 'csv-toolbar-not-overflowed', 'csv-export-enabled', 'csv-panel-opened', 'csv-panel-saved',
            'csv-file-written', 'csv-utf8-no-bom-crlf', 'csv-header', 'csv-ranks-and-order', 'csv-roundtrip-names',
            'csv-sizes-plausible', 'csv-formula-row-marked', 'csv-cancel-panel-opened', 'csv-cancel-wrote-nothing']
HEADER = ['rank', 'size_bytes_on_disk_at_scan', 'path', 'note']
MB = 1024 * 1024
# name -> logical size. Distinct sizes so the order is unambiguous. Names exercise quoting, UTF-8, an embedded newline and a formula start.
FIXTURE = [('big,comma.bin', 9 * MB), ('say "hi".bin', 8 * MB), ('caf\u00e9-\u65e5\u672c.bin', 7 * MB),
           ('line\nbreak.bin', 6 * MB), ('=formula.bin', 5 * MB), ('plain.bin', 4 * MB)]
PANEL_NEEDLE_FIELD = 'saveAsNameTextField'
KEY_A = 0
KEY_V = 9
KEY_G = 5
KEY_RETURN = 36
# US-layout virtual keycodes (real keys, no unicode override). The temp path is ASCII: letters, digits, / . - _
_LETTERS = {'a': 0, 's': 1, 'd': 2, 'f': 3, 'h': 4, 'g': 5, 'z': 6, 'x': 7, 'c': 8, 'v': 9, 'b': 11, 'q': 12, 'w': 13, 'e': 14, 'r': 15, 'y': 16, 't': 17,
            'o': 31, 'u': 32, 'i': 34, 'p': 35, 'l': 37, 'j': 38, 'k': 40, 'n': 45, 'm': 46}
_DIGITS = {'1': 18, '2': 19, '3': 20, '4': 21, '6': 22, '5': 23, '9': 25, '7': 26, '8': 28, '0': 29}
KEYCODES = {**_LETTERS, **_DIGITS, '-': 27, '/': 44, '.': 47}


def keys_for(text):
    """[(keycode, mods)] for an ASCII string on a US layout, or None when a character has no mapped key."""
    out = []
    for ch in text:
        if ch in KEYCODES: out.append((KEYCODES[ch], ()))
        elif ch.isalpha() and ch.lower() in KEYCODES and ch.isascii(): out.append((KEYCODES[ch.lower()], ('shift',)))
        elif ch == '_': out.append((KEYCODES['-'], ('shift',)))
        else: return None
    return out


def make_fixture(root, rng=random.Random(7)):
    root = pathlib.Path(root); root.mkdir(parents=True, exist_ok=True)
    for name, size in FIXTURE:
        (root / name).write_bytes(rng.randbytes(size))  # random bytes: no sparse or compressed allocation
    return root


def judge_csv(raw, root):
    """Pure judge. Returns {check_name: (ok, detail)}."""
    out = {}
    def put(k, ok, d=''): out[k] = (bool(ok), d)
    try:
        text = raw.decode('utf-8')   # strict
    except UnicodeDecodeError as e:
        put('csv-utf8-no-bom-crlf', False, f'not UTF-8: {e}'); return out
    nobom = not raw.startswith(b'\xef\xbb\xbf')
    # every line break outside quotes must be CRLF: remove quoted fields, then look for a bare LF
    unquoted = ''.join(part for i, part in enumerate(text.split('"')) if i % 2 == 0)
    crlf = '\n' in unquoted and '\r\n' in unquoted and unquoted.replace('\r\n', '').count('\n') == 0 and unquoted.endswith('\r\n')
    put('csv-utf8-no-bom-crlf', nobom and crlf, f'bom={not nobom} crlf_only={crlf}')
    rows = list(csv.reader(io.StringIO(text, newline='')))
    put('csv-header', bool(rows) and rows[0] == HEADER, f'header={rows[0] if rows else None}')
    data = rows[1:] if rows else []
    ranks = [r[0] for r in data if r]
    sizes = []
    for r in data:
        try: sizes.append(int(r[1]))
        except (ValueError, IndexError): sizes.append(-1)
    put('csv-ranks-and-order', bool(data) and all(len(r) == 4 for r in data) and ranks == [str(i + 1) for i in range(len(data))]
        and all(s >= 0 for s in sizes) and all(a >= b for a, b in zip(sizes, sizes[1:])), f'rows={len(data)} sizes={sizes[:8]}')
    real = os.path.realpath(root)
    by_path = {r[2]: r for r in data if len(r) == 4 and r[2]}
    missing = []
    for name, size in FIXTURE:
        if name.startswith('='): continue
        if os.path.join(real, name) not in by_path: missing.append(name)
    put('csv-roundtrip-names', not missing, f'missing={missing!r}')
    bad = []
    for name, size in FIXTURE:
        r = by_path.get(os.path.join(real, name))
        if r is None: continue
        b = int(r[1])
        if not (size <= b <= size + 2 * MB): bad.append((name, b, size))
    put('csv-sizes-plausible', not bad and bool(by_path), f'out_of_range={bad!r}')
    # The app marks (empty path + note) only a path whose FIRST character is a formula character. The engine's paths are absolute, so
    # '=formula.bin' is exported exactly as '<root>/=formula.bin' with an empty note, and no path cell may start with a formula character.
    frow = by_path.get(os.path.join(real, '=formula.bin'))
    bare = [r[2] for r in data if len(r) == 4 and r[2][:1] in ('=', '+', '-', '@', '\t', '\r')]
    put('csv-formula-row-marked', frow is not None and frow[3] == '' and not bare and len(data) == len(FIXTURE), f'formula_row_exact={frow is not None and frow[3] == ""} cells_starting_with_formula_char={bare!r} rows={len(data)}')
    return out


def panel_gone(nodes):
    """The Save panel is gone when its name field and any dialog window are gone. An alert sheet is NOT a panel."""
    return find(nodes, 'AXTextField', PANEL_NEEDLE_FIELD) is None and not any(n.get('role') == 'AXWindow' and n.get('subrole') == 'AXDialog' for n in nodes)


def has_alert(nodes):
    return any(n.get('role') == 'AXSheet' for n in nodes)


def status_text(nodes, limit=500):
    """Visible text a non-gating diagnostic can quote: static texts, alerts and sheet titles from the tree."""
    bits = [str(n.get('value') or n.get('title') or '') for n in nodes if n.get('role') in ('AXStaticText', 'AXSheet', 'AXAlert') and (n.get('value') or n.get('title'))]
    return ' | '.join(b.replace('\n', ' ')[:120] for b in bits)[:limit]


def new_csvs(dest, docs, pre):
    return {'dest': sorted(x.name for x in pathlib.Path(dest).glob('*.csv')) if pathlib.Path(dest).exists() else [],
            'documents': sorted(x.name for x in pathlib.Path(docs).glob('*.csv') if str(x) not in pre) if pathlib.Path(docs).exists() else []}


def landed(value, target):
    """True when the field holds the target. Run 40235311568 (real Mac): after a pasted full path the panel shows only the file stem
    ('export') and navigates to the folder, and the file did land at the pasted path. So accept the full path, the base name or its stem."""
    if not value: return False
    base = os.path.basename(target)
    return value in (target, base, os.path.splitext(base)[0])


def read_back(ui, pid):
    f = find(ui.tree(pid), 'AXTextField', PANEL_NEEDLE_FIELD)
    return (f or {}).get('value')


def drive_panel(ui, pid, target, checks, prefix, out, clock=time.time, sleep=time.sleep, wait=20, frontmost=real_frontmost, clip=real_clip, dest=None):
    """Press Export, wait for the Save panel, put `target` in the name field with a ladder: click, Cmd-A (real keycode), paste (Cmd-V),
    then real US-layout keys, then (save leg only, when dest is given) Cmd-Shift-G go-to-folder keeping the default name. Each rung is
    skipped once the read-back equals the target. Returns (panel nodes, expected file path) or (None, None)."""
    ex = ui.press(pid, 'AXButton', '=' + EXPORT_DESC)
    if not ex.get('found') or ex.get('axError') != 0:
        checks.bad(f'{prefix}-panel-opened', f'press export failed {ex}'); return None, None
    def panel():
        nodes = ui.tree(pid)
        f = find(nodes, 'AXTextField', PANEL_NEEDLE_FIELD)
        return (nodes, f) if f else None
    got = poll(panel, wait, 0.5, clock, sleep)
    if not got:
        nodes = ui.tree(pid)
        (out / f'{prefix}-no-panel-tree.jsonl').write_text('\n'.join(map(repr, nodes)))
        checks.bad(f'{prefix}-panel-opened', 'no Save panel name field appeared'); return None, None
    nodes, field = got
    (out / f'{prefix}-panel-tree.jsonl').write_text('\n'.join(map(repr, nodes)))
    checks.ok(f'{prefix}-panel-opened', f"field={field.get('id')}")
    default_name = str(field.get('value') or '')
    bad_name = f'{prefix}-panel-saved' if prefix == 'csv' else f'{prefix}-wrote-nothing'
    # Rung 1: a real click into the field (AXFocused alone may not make it first responder in the remote panel view).
    ck = ui.click_el(pid, 'AXTextField', PANEL_NEEDLE_FIELD)
    sleep(.3)
    checks.note(f'{prefix}-name-click', f"found={ck.get('found')} clicked={ck.get('clicked')} point=({ck.get('x')},{ck.get('y')}) frontmost={frontmost()!r}")
    def select_all():
        a, _, fm = guarded_key(ui, pid, KEY_A, ('cmd',), True, frontmost)
        return a, fm
    a, fm = select_all()
    if a.get('refused') is not None:
        checks.bad(bad_name, f"refused: frontmost={a.get('refused')!r}, nothing posted"); return None, None
    # Rung 2: paste the path with real keycodes (Cmd-V).
    method, value = 'paste', None
    try:
        clip(target)
        v, _, fm = guarded_key(ui, pid, KEY_V, ('cmd',), True, frontmost)
        if v.get('refused') is not None:
            checks.bad(bad_name, f"refused: frontmost={v.get('refused')!r}, nothing posted"); return None, None
    except (OSError, subprocess.SubprocessError) as e:
        checks.note(f'{prefix}-name-paste-error', repr(e)[:160])
    sleep(.5); value = read_back(ui, pid)
    checks.note(f'{prefix}-name-readback', f'method=paste typed={target!r} field_value={value!r} frontmost={fm!r}')
    # Rung 3: real US-layout keys, only if the paste did not land.
    if not landed(value, target):
        seq = keys_for(target)
        if seq is None:
            checks.note(f'{prefix}-name-readback', 'method=keys skipped: a character has no mapped US keycode')
        else:
            a, fm = select_all()
            fm2 = frontmost()
            if a.get('refused') is not None or fm2 not in ALLOWED_FRONTMOST:
                checks.bad(bad_name, f"refused: frontmost={a.get('refused') or fm2!r}, nothing posted"); return None, None
            posted = 0
            for code, mods in seq: posted += ui.key_tap(pid, code, *mods).get('eventsPosted', 0)
            sleep(.5); value = read_back(ui, pid)
            checks.note(f'{prefix}-name-readback', f'method=keys events={posted} typed={target!r} field_value={value!r} frontmost={frontmost()!r}')
    expected = target
    name_landed = landed(value, target)
    # Folder: run 40238740556 (real Mac) showed the panel keeps only the file NAME from a pasted full path and saves into its own default folder
    # (~/Documents). So the save leg always goes to the destination folder with Cmd-Shift-G. If no name landed, keep the default name and expect it in dest.
    if dest is not None:
        try:
            g, _, gf = guarded_key(ui, pid, KEY_G, ('cmd', 'shift'), True, frontmost)
            if g.get('refused') is None:
                sleep(1.0); clip(str(dest))
                guarded_key(ui, pid, KEY_A, ('cmd',), True, frontmost); guarded_key(ui, pid, KEY_V, ('cmd',), True, frontmost); sleep(.5)
                guarded_key(ui, pid, KEY_RETURN, (), True, frontmost); sleep(1.0)
                if not name_landed: expected = str(pathlib.Path(dest) / (default_name if default_name.endswith('.csv') else default_name + '.csv'))
                checks.note(f'{prefix}-name-goto', f'go-to-folder dest={str(dest)!r} name_landed={name_landed} default_name={default_name!r} expected={expected!r} field_value={read_back(ui, pid)!r}')
            else:
                checks.note(f'{prefix}-name-goto', f"refused: frontmost={g.get('refused')!r}")
        except (OSError, subprocess.SubprocessError) as e:
            checks.note(f'{prefix}-name-goto', f'error {e!r}'[:200])
    return nodes, expected


EXPORT_DESC = 'Export CSV'   # the REAL AX description seen on the Mac (run 40226372270 tree); the accessibilityLabel text is not what AX reports


def find_export(nodes):
    for n in nodes:
        if n.get('role') == 'AXButton' and n.get('desc') == EXPORT_DESC: return n
    return None


TAB_ROLES = ('AXRadioButton', 'AXButton', 'AXTab', 'AXSegment', 'AXMenuItem')


def find_tab(nodes, name='Largest'):
    """Role-agnostic: the segmented Picker item can surface as a radio button, button or tab. Exact name match, so the
    toolbar button 'Export the Largest list as CSV' is never mistaken for it."""
    for n in nodes:
        if n.get('role') in TAB_ROLES and name in (n.get('title'), n.get('desc'), n.get('value')): return n
    return None


def select_largest(ui, pid, checks, out, clock=time.time, sleep=time.sleep):
    """The Export button is disabled unless the Largest tab is selected, and the app opens on Treemap."""
    node = poll(lambda: find_tab(ui.tree(pid)), 30, 1, clock, sleep)
    if not node:
        (out / 'no-largest-tab-tree.jsonl').write_text('\n'.join(map(repr, ui.tree(pid))))
        checks.bad('csv-largest-tab-selected', 'no Largest tab control in the AX tree (tree dumped)'); return False
    r = ui.press(pid, node['role'], '=Largest')
    ok = bool(r.get('found')) and r.get('axError') == 0
    if not ok: (out / 'largest-press-tree.jsonl').write_text('\n'.join(map(repr, ui.tree(pid))))
    return checks.check('csv-largest-tab-selected', ok, f"role={node['role']} press={r.get('axError')} found={r.get('found')}")


def dismiss_alert(ui, pid, checks, label, clock, sleep, frontmost, wait=8):
    """Wait up to `wait`s for an alert sheet, record its text, dismiss it via the sheet's default button (Return as a guarded fallback)
    and wait until the sheet is gone. Returns True when no alert is left."""
    seen = poll(lambda: (lambda n: n if has_alert(n) else None)(ui.tree(pid)), wait, .5, clock, sleep)
    if not seen:
        checks.note(f'{label}-alert', 'no alert sheet appeared'); return True
    checks.note(f'{label}-alert', f'text={status_text(seen)!r}')
    r = ui.press_sheet(pid); fallback = 0
    if not r.get('found') or r.get('axError') != 0:
        fallback = guarded_key(ui, pid, KEY_RETURN, (), True, frontmost)[0].get('eventsPosted', 0)
    gone = poll(lambda: not has_alert(ui.tree(pid)), 5, .5, clock, sleep)
    checks.note(f'{label}-alert-dismissed', f"gone={bool(gone)} sheet_press={r.get('axError')} found={r.get('found')} returnFallbackEvents={fallback}")
    return bool(gone)


def run(app, ui, out, launch, clock=time.time, sleep=time.sleep, root=None, frontmost=real_frontmost, strays=None, clip=real_clip, activate=real_activate):
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    checks = Checks(REQUIRED)
    work = pathlib.Path(tempfile.mkdtemp(prefix='spz-csv-'))
    docs = pathlib.Path.home() / 'Documents'
    strays = strays if strays is not None else [docs / n for n in ('spacelyzer-largest.csv', 'export.csv', 'cancelled.csv')]
    pre = {str(x) for x in strays if x.exists()}
    try:
        fixture = make_fixture(work / 'fixture'); dest = work / 'dest'; dest.mkdir()
        if not checks.check('csv-ax-trusted', ui.trusted(), 'AXIsProcessTrusted'): return checks
        stop_apps()
        launch(app, fixture)
        pid = poll(lambda: pid_of(), 30, .5, clock, sleep)
        if not checks.check('csv-app-launched', pid, f'pid={pid}'): return checks
        if not select_largest(ui, pid, checks, out, clock, sleep): return checks
        present = poll(lambda: find_export(ui.tree(pid)), 30, 1, clock, sleep)
        if not checks.check('csv-toolbar-not-overflowed', present, 'Export button present in the AX tree (not collapsed into the toolbar overflow)'):
            (out / 'no-export-button-tree.jsonl').write_text('\n'.join(map(repr, ui.tree(pid)))); return checks
        enabled = poll(lambda: (lambda n: n if n and n.get('enabled') else None)(
            find_export(ui.tree(pid))), 90, 1, clock, sleep)
        if not checks.check('csv-export-enabled', enabled, 'toolbar button enabled after the scan'):
            (out / 'no-export-tree.jsonl').write_text('\n'.join(map(repr, ui.tree(pid)))); return checks
        target = dest / 'export.csv'
        nodes, target = drive_panel(ui, pid, str(target), checks, 'csv', out, clock, sleep, frontmost=frontmost, clip=clip, dest=dest)
        target = pathlib.Path(target) if target else dest / 'export.csv'
        if nodes is not None:
            sv = ui.press(pid, 'AXButton', 'Save')
            pressed = bool(sv.get('found')) and sv.get('axError') == 0
            fallback = 0
            if not pressed:
                fallback = guarded_key(ui, pid, 36, (), True, frontmost)[0].get('eventsPosted', 0)   # Return as the fallback for a default button the AX press could not reach
            checks.check('csv-panel-saved', pressed or fallback > 0, f"save press={sv.get('axError')} found={sv.get('found')} fallbackKeyEvents={fallback}")
            sleep(1.5); post = ui.tree(pid)
            (out / 'csv-post-save-tree.jsonl').write_text('\n'.join(map(repr, post)))
            checks.note('csv-post-save', f"panel_closed={panel_gone(post)} alert_present={has_alert(post)} main_window_text={status_text(post)!r}")
            dismiss_alert(ui, pid, checks, 'csv-post-save', clock, sleep, frontmost)
            wrote = poll(lambda: target.is_file() and target.stat().st_size > 0 and target, 20, .5, clock, sleep)
            created = [str(x) for x in strays if x.exists() and str(x) not in pre]
            checks.note('csv-new-csv-files', f'{new_csvs(dest, docs, pre)}')
            if not wrote: checks.note('csv-stray-files', f'no file at the target; files that appeared in the default location instead: {created}')
            if checks.check('csv-file-written', wrote, str(target)):
                raw = target.read_bytes(); shutil.copy2(target, out / 'export.csv')
                for k, (ok, d) in judge_csv(raw, fixture).items(): checks.check(k, ok, d)
        # Cancel path: a second panel, a distinct target, then Cancel. Nothing may be written.
        snap = {str(x) for x in strays if x.exists()}     # strays that exist before the cancel leg are not blamed on it
        ctarget = dest / 'cancelled.csv'
        # The leftover export alert made Finder frontmost in run 40232750584: clear any alert and re-activate the app first.
        left = has_alert(ui.tree(pid)) and not dismiss_alert(ui, pid, checks, 'csv-pre-cancel', clock, sleep, frontmost, wait=2)
        act = activate(pid); sleep(1)
        checks.note('csv-pre-cancel-state', f'alert_gone={not (left or has_alert(ui.tree(pid)))} {act}')
        nodes, _ = drive_panel(ui, pid, str(ctarget), checks, 'csv-cancel', out, clock, sleep, wait=20, frontmost=frontmost, clip=clip)
        if nodes is not None:
            cx = ui.press(pid, 'AXButton', 'Cancel')
            if not cx.get('found'): guarded_key(ui, pid, 53, (), True, frontmost)   # Escape
            sleep(2)
            after = ui.tree(pid)
            new_default = [str(x) for x in strays if x.exists() and str(x) not in snap and str(x) not in pre]
            checks.note('csv-cancel-panel-closed', f'panel_closed={panel_gone(after)}')
            checks.check('csv-cancel-wrote-nothing', not ctarget.exists() and not new_default, f'exists={ctarget.exists()} new_in_default_folder={new_default}')
    except Fail as e:
        checks.bad('csv-driver', str(e))
    finally:
        for x in strays:
            if x.exists() and str(x) not in pre:
                try: x.unlink()
                except OSError: pass
        try: stop_apps()
        except Fail: pass
        shutil.rmtree(work, ignore_errors=True)
    return checks


def real_launch(app, fixture):
    subprocess.run(['open', '-n', str(app), '--env', f'SPZ_AUTOSCAN={fixture}', '--env', 'SPZ_WINDOW_SIZE=1280x800'], check=True, timeout=30)


def main():
    p = argparse.ArgumentParser(); p.add_argument('--app', required=True); p.add_argument('--ui', required=True); p.add_argument('--output', required=True)
    a = p.parse_args()
    checks = run(a.app, HelperUI(a.ui), a.output, real_launch)
    good = checks.write(a.output)
    print(open(pathlib.Path(a.output) / 'result.txt').read(), end='')
    return 0 if good else 1


if __name__ == '__main__':
    sys.exit(main())
