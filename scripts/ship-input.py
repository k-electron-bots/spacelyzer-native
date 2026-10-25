#!/usr/bin/env python3
"""Real keyboard input check for the ship-candidate run. Posts REAL key events (CGEvent, posted to the app's pid) and judges what
the app's accessibility tree shows afterwards: Cmd-O opens the real Open panel, Escape closes it, Tab and Shift-Tab move keyboard
focus. IME composition is NOT driven here (a shared runner cannot be shown to run one): the enabled input sources are recorded as a
NOTE only. Mac execution is not proved by Linux tests."""
import argparse, pathlib, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from ship_common import Checks, Fail, HelperUI, pid_of, poll, stop_apps

REQUIRED = ['input-ax-trusted', 'input-app-launched', 'input-focus-readable', 'input-cmd-o-opens-panel', 'input-escape-closes-panel',
            'input-tab-moves-focus', 'input-shift-tab-reverses', 'input-app-alive-after']
KEY_O, KEY_ESC, KEY_TAB = 31, 53, 48


def panel_open(nodes):
    """An Open/Scan-folder panel is present when a sheet or dialog window exists, or a window is titled Open, Scan or Choose."""
    for n in nodes:
        if n.get('role') == 'AXSheet': return True
        if n.get('role') == 'AXWindow' and n.get('subrole') in ('AXDialog', 'AXSystemDialog'): return True
        if n.get('role') == 'AXWindow' and any(w in (n.get('title') or '') for w in ('Open', 'Scan', 'Choose')): return True
    return False


def focus_key(node):
    return (node.get('role'), node.get('subrole'), node.get('title'), node.get('desc'), node.get('id'), node.get('path'))


def run(app, ui, out, launch, activate, ime_probe, alive, clock=time.time, sleep=time.sleep):
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    checks = Checks(REQUIRED)
    work = pathlib.Path(tempfile.mkdtemp(prefix='spz-input-'))
    try:
        (work / 'fx').mkdir(); (work / 'fx' / 'a.bin').write_bytes(bytes(300000))
        if not checks.check('input-ax-trusted', ui.trusted(), 'AXIsProcessTrusted'): return checks
        checks.note('input-ime-sources', ime_probe())
        stop_apps(); launch(app, work / 'fx')
        pid = poll(lambda: pid_of(), 30, .5, clock, sleep)
        if not checks.check('input-app-launched', pid, f'pid={pid}'): return checks
        sleep(4); activate(pid); sleep(1)
        base = ui.tree(pid)
        f0 = ui.focus(pid).get('node')
        checks.check('input-focus-readable', bool(f0), f'focus={f0}')
        k = ui.key(pid, KEY_O, 'cmd')
        opened = poll(lambda: panel_open(ui.tree(pid)) or None, 10, .5, clock, sleep)
        checks.check('input-cmd-o-opens-panel', k.get('eventsPosted') == 2 and opened and not panel_open(base),
                     f"events={k.get('eventsPosted')} opened={bool(opened)} baselinePanel={panel_open(base)}")
        (out / 'after-cmd-o-tree.jsonl').write_text('\n'.join(map(repr, ui.tree(pid))))
        ui.key(pid, KEY_ESC)
        closed = poll(lambda: (not panel_open(ui.tree(pid))) or None, 10, .5, clock, sleep)
        checks.check('input-escape-closes-panel', bool(closed), f'closed={bool(closed)}')
        # Tab moves focus: judged against the focus read right before each key.
        before = (ui.focus(pid).get('node') or {})
        moved = None
        for _ in range(3):
            ui.key(pid, KEY_TAB); sleep(.6)
            after = (ui.focus(pid).get('node') or {})
            if after and focus_key(after) != focus_key(before): moved = after; break
        checks.check('input-tab-moves-focus', bool(moved), f'before={focus_key(before)} after={focus_key(moved or {})}')
        if moved:
            ui.key(pid, KEY_TAB, 'shift'); sleep(.6)
            back = (ui.focus(pid).get('node') or {})
            checks.check('input-shift-tab-reverses', bool(back) and focus_key(back) != focus_key(moved), f'moved={focus_key(moved)} back={focus_key(back)}')
        else:
            checks.bad('input-shift-tab-reverses', 'no Tab movement to reverse')
        checks.check('input-app-alive-after', alive(pid), f'pid={pid}')
    except Fail as e:
        checks.bad('input-driver', str(e))
    finally:
        try: stop_apps()
        except Fail: pass
        shutil.rmtree(work, ignore_errors=True)
    return checks


def real_launch(app, fx):
    subprocess.run(['open', '-n', str(app), '--env', f'SPZ_AUTOSCAN={fx}'], check=True, timeout=30)

def real_activate(pid):
    subprocess.run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'], timeout=20, check=False)

def real_ime():
    p = subprocess.run(['defaults', 'read', 'com.apple.HIToolbox', 'AppleEnabledInputSources'], capture_output=True, text=True, timeout=20)
    return ' '.join((p.stdout or p.stderr).split())[:600]

def real_alive(pid):
    return subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0


def main():
    p = argparse.ArgumentParser(); p.add_argument('--app', required=True); p.add_argument('--ui', required=True); p.add_argument('--output', required=True)
    a = p.parse_args()
    checks = run(a.app, HelperUI(a.ui), a.output, real_launch, real_activate, real_ime, real_alive)
    good = checks.write(a.output)
    print(open(pathlib.Path(a.output) / 'result.txt').read(), end='')
    return 0 if good else 1

if __name__ == '__main__':
    sys.exit(main())
