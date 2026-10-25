#!/usr/bin/env python3
"""Real save-panel CSV export check for the ship-candidate run. Launches the TEST-ONLY app on a disposable fixture, presses the
real Export CSV toolbar button, drives the real NSSavePanel through accessibility, then judges the file bytes. Also checks that
Cancel writes nothing. Mac execution is not proved by Linux tests."""
import argparse, csv, io, os, pathlib, random, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from ship_common import Checks, Fail, HelperUI, find, guarded_key, pid_of, poll, real_frontmost, stop_apps

REQUIRED = ['csv-ax-trusted', 'csv-app-launched', 'csv-largest-tab-selected', 'csv-toolbar-not-overflowed', 'csv-export-enabled', 'csv-panel-opened', 'csv-panel-saved',
            'csv-file-written', 'csv-utf8-no-bom-crlf', 'csv-header', 'csv-ranks-and-order', 'csv-roundtrip-names',
            'csv-sizes-plausible', 'csv-formula-row-marked', 'csv-cancel-panel-opened', 'csv-cancel-wrote-nothing']
HEADER = ['rank', 'size_bytes_on_disk_at_scan', 'path', 'note']
MB = 1024 * 1024
# name -> logical size. Distinct sizes so the order is unambiguous. Names exercise quoting, UTF-8, an embedded newline and a formula start.
FIXTURE = [('big,comma.bin', 9 * MB), ('say "hi".bin', 8 * MB), ('caf\u00e9-\u65e5\u672c.bin', 7 * MB),
           ('line\nbreak.bin', 6 * MB), ('=formula.bin', 5 * MB), ('plain.bin', 4 * MB)]
PANEL_NEEDLE_FIELD = 'saveAsNameTextField'


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
    marked = [r for r in data if len(r) == 4 and r[2] == '' and 'formula' in r[3]]
    put('csv-formula-row-marked', len(marked) == 1 and not any(os.path.join(real, '=formula.bin') == r[2] for r in data), f'marked={len(marked)}')
    return out


def drive_panel(ui, pid, target, checks, prefix, out, clock=time.time, sleep=time.sleep, wait=20):
    """Press Export, wait for the Save panel, put `target` in the name field. Returns the panel nodes (or None)."""
    ex = ui.press(pid, 'AXButton', '=' + EXPORT_DESC)
    if not ex.get('found') or ex.get('axError') != 0:
        checks.bad(f'{prefix}-panel-opened', f'press export failed {ex}'); return None
    def panel():
        nodes = ui.tree(pid)
        f = find(nodes, 'AXTextField', PANEL_NEEDLE_FIELD)
        return (nodes, f) if f else None
    got = poll(panel, wait, 0.5, clock, sleep)
    if not got:
        nodes = ui.tree(pid)
        (out / f'{prefix}-no-panel-tree.jsonl').write_text('\n'.join(map(repr, nodes)))
        checks.bad(f'{prefix}-panel-opened', 'no Save panel name field appeared'); return None
    nodes, field = got
    (out / f'{prefix}-panel-tree.jsonl').write_text('\n'.join(map(repr, nodes)))
    checks.ok(f'{prefix}-panel-opened', f"field={field.get('id')}")
    s = ui.set_(pid, 'AXTextField', PANEL_NEEDLE_FIELD, target)
    if not s.get('found') or s.get('axError') != 0:
        checks.bad(f'{prefix}-panel-saved' if prefix == 'csv' else f'{prefix}-wrote-nothing', f'set name failed {s}'); return None
    return nodes


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


def run(app, ui, out, launch, clock=time.time, sleep=time.sleep, root=None, frontmost=real_frontmost):
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    checks = Checks(REQUIRED)
    work = pathlib.Path(tempfile.mkdtemp(prefix='spz-csv-'))
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
        nodes = drive_panel(ui, pid, str(target), checks, 'csv', out, clock, sleep)
        if nodes is not None:
            sv = ui.press(pid, 'AXButton', 'Save')
            pressed = bool(sv.get('found')) and sv.get('axError') == 0
            fallback = 0
            if not pressed:
                fallback = guarded_key(ui, pid, 36, (), True, frontmost)[0].get('eventsPosted', 0)   # Return as the fallback for a default button the AX press could not reach
            checks.check('csv-panel-saved', pressed or fallback > 0, f"save press={sv.get('axError')} found={sv.get('found')} fallbackKeyEvents={fallback}")
            wrote = poll(lambda: target.is_file() and target.stat().st_size > 0 and target, 20, .5, clock, sleep)
            if checks.check('csv-file-written', wrote, str(target)):
                raw = target.read_bytes(); shutil.copy2(target, out / 'export.csv')
                for k, (ok, d) in judge_csv(raw, fixture).items(): checks.check(k, ok, d)
        # Cancel path: a second panel, a distinct target, then Cancel. Nothing may be written.
        ctarget = dest / 'cancelled.csv'
        nodes = drive_panel(ui, pid, str(ctarget), checks, 'csv-cancel', out, clock, sleep, wait=20)
        if nodes is not None:
            cx = ui.press(pid, 'AXButton', 'Cancel')
            if not cx.get('found'): guarded_key(ui, pid, 53, (), True, frontmost)   # Escape
            sleep(2)
            checks.check('csv-cancel-wrote-nothing', not ctarget.exists(), f'exists={ctarget.exists()}')
    except Fail as e:
        checks.bad('csv-driver', str(e))
    finally:
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
