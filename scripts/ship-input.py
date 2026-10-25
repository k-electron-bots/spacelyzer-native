#!/usr/bin/env python3
"""Real keyboard input check for the ship-candidate run. Posts REAL key events (CGEvent, posted to the app's pid) and judges what
the app's accessibility tree shows afterwards: Cmd-O opens the real Open panel, Escape closes it, Tab and Shift-Tab move keyboard
focus. IME composition is NOT driven here (a shared runner cannot be shown to run one): the enabled input sources are recorded as a
NOTE only. Mac execution is not proved by Linux tests."""
import argparse, pathlib, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from ship_common import Checks, Fail, HelperUI, guarded_key, pid_of, poll, real_frontmost, stop_apps

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


def run(app, ui, out, launch, activate, ime_probe, alive, clock=time.time, sleep=time.sleep, frontmost=real_frontmost):
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
        sleep(4); checks.note('input-activate', activate(pid)); sleep(1)
        base = ui.tree(pid)
        f0 = ui.focus(pid).get('node')
        checks.check('input-focus-readable', bool(f0), f'focus={f0}')
        k, o_path, o_front = guarded_key(ui, pid, KEY_O, ('cmd',), False, frontmost)
        opened = poll(lambda: panel_open(ui.tree(pid)) or None, 10, .5, clock, sleep)
        checks.check('input-cmd-o-opens-panel', k.get('eventsPosted') == 2 and opened and not panel_open(base),
                     f"events={k.get('eventsPosted')} opened={bool(opened)} baselinePanel={panel_open(base)} path={o_path} frontmost={o_front!r} refused={k.get('refused')!r}")
        (out / 'after-cmd-o-tree.jsonl').write_text('\n'.join(map(repr, ui.tree(pid))))
        # Escape (cancelOperation) needs a KEY window; Cmd-O does not. Wait until the dialog is focused (or settle), never post at once.
        keyed = poll(lambda: any(n.get('role') == 'AXWindow' and n.get('subrole') in ('AXDialog', 'AXSystemDialog') and n.get('focused')
                                 for n in ui.tree(pid)) or None, 5, .5, clock, sleep)
        if not keyed: sleep(1.5)
        checks.note('input-dialog-key-state', f'dialog focused before Escape={bool(keyed)} (else a 1.5s settle was used)')
        closed, tries, refused, e_path, e_front = False, 0, None, 'session-tap', None
        for tries in range(1, 4):
            checks.note(f'input-escape-activate-{tries}', activate(pid))   # the panel must be frontmost before a session-tap key
            r, e_path, e_front = guarded_key(ui, pid, KEY_ESC, (), True, frontmost)
            if r.get('refused') is not None: refused = r['refused']; break   # nothing was posted: never key another process
            closed = bool(poll(lambda: (not panel_open(ui.tree(pid))) or None, 3, .5, clock, sleep))
            if closed: break
        checks.check('input-escape-closes-panel', closed, f'closed={closed} escape_posts={tries} path={e_path} frontmost={e_front!r}' + (f' REFUSED (not frontmost, nothing posted): {refused!r}' if refused is not None else ''))
        still_open = panel_open(ui.tree(pid))
        if still_open:
            # cleanup only AFTER the FAIL is recorded; never part of the Escape verdict
            cx = ui.press(pid, 'AXButton', '=Cancel'); sleep(1)
            checks.note('input-cleanup-cancel', f'Cancel pressed after the Escape FAIL: found={cx.get("found")} axError={cx.get("axError")} panelStillOpen={panel_open(ui.tree(pid))}')
            checks.bad('input-tab-moves-focus', 'panel still open: the Tab leg did not run')
            checks.bad('input-shift-tab-reverses', 'panel still open: the Tab leg did not run')
            moved = None
        else:
            # Tab moves focus: judged against the focus read right before each key (a bounded retry on an unreadable read).
            before = {}
            for _ in range(3):
                before = ui.focus(pid).get('node') or {}
                if before: break
                sleep(.5)
            moved = None; t_front = None
            for _ in range(3):
                r, t_path, t_front = guarded_key(ui, pid, KEY_TAB, (), True, frontmost)
                if r.get('refused') is not None: break
                sleep(.6)
                after = (ui.focus(pid).get('node') or {})
                if before and after and focus_key(after) != focus_key(before): moved = after; break
            checks.check('input-tab-moves-focus', bool(moved), f'before={focus_key(before)} after={focus_key(moved or {})} path=session-tap frontmost={t_front!r}')
        if still_open: pass
        elif moved:
            rr, _, sh_front = guarded_key(ui, pid, KEY_TAB, ('shift',), True, frontmost)
            sleep(.6)
            back = (ui.focus(pid).get('node') or {})
            checks.check('input-shift-tab-reverses', bool(back) and focus_key(back) != focus_key(moved), f'moved={focus_key(moved)} back={focus_key(back)} path=session-tap frontmost={sh_front!r} refused={rr.get("refused")!r}')
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
    r = subprocess.run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'], capture_output=True, text=True, timeout=20)
    f = subprocess.run(['osascript', '-e', 'tell application "System Events" to get name of first process whose frontmost is true'], capture_output=True, text=True, timeout=20)
    return f'activate rc={r.returncode} err={r.stderr.strip()[:120]!r} frontmost={f.stdout.strip()!r}'

def real_ime():
    p = subprocess.run(['defaults', 'read', 'com.apple.HIToolbox', 'AppleEnabledInputSources'], capture_output=True, text=True, timeout=20)
    return ' '.join((p.stdout or p.stderr).split())[:600]

def real_alive(pid):
    return subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode == 0


def main():
    p = argparse.ArgumentParser(); p.add_argument('--app', required=True); p.add_argument('--ui', required=True); p.add_argument('--output', required=True)
    a = p.parse_args()
    checks = run(a.app, HelperUI(a.ui), a.output, real_launch, real_activate, real_ime, real_alive, frontmost=real_frontmost)
    good = checks.write(a.output)
    print(open(pathlib.Path(a.output) / 'result.txt').read(), end='')
    return 0 if good else 1

if __name__ == '__main__':
    sys.exit(main())
