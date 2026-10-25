#!/usr/bin/env python3
"""Linux controls for scripts/ship-input.py against a stateful fake UI: green path, and red for each broken behavior.
Not Mac execution: real key delivery, panels and focus traversal stay native-unverified."""
import importlib.util, importlib.machinery, pathlib, sys, tempfile
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('shipinput', 'scripts/ship-input.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import ship_common as sc

class Clock:
    def __init__(s): s.t = 0.0
    def __call__(s): return s.t
    def sleep(s, d): s.t += max(d, .01)

class FakeUI:
    ORDER = [{'role': 'AXButton', 'desc': 'Scan', 'path': '/0'}, {'role': 'AXButton', 'desc': 'Export', 'path': '/1'}, {'role': 'AXOutline', 'desc': 'Items', 'path': '/2'}]
    def __init__(s, clk=None, **k): s.k = k; s.panel = False; s.i = 0; s.clk = clk; s.opened_at = None; s.esc_seen = 0; s.log = []
    def keyed(s): return s.clk is not None and s.opened_at is not None and s.clk.t - s.opened_at >= s.k.get('key_after', 0)
    def trusted(s): return s.k.get('trusted', True)
    def press(s, pid, role, needle):
        if needle == '=Cancel' and s.panel: s.panel = False; return {'found': True, 'axError': 0}
        return {'found': False}
    def tree(s, pid):
        n = [{'role': 'AXWindow', 'title': 'Spacelyzer', 'depth': 1}]
        if s.panel: n.append({'role': 'AXWindow', 'subrole': 'AXDialog', 'title': 'Open', 'depth': 1, 'focused': bool(s.keyed() and not s.k.get('no_focused_attr'))})
        return n
    def focus(s, pid): return {} if s.k.get('no_focus') else {'node': s.ORDER[s.i % 3]}
    def key_tap(s, pid, code, *mods): return s.key(pid, code, *mods, _tap=True)
    def key(s, pid, code, *mods, _tap=False):
        s.log.append(('tap' if _tap else 'pid', code))
        if s.k.get('no_events'): return {'eventsPosted': 0}
        # a remote panel only sees session-tap events for Escape/Tab (the run 40226372270 hypothesis); Cmd-O works either way
        if code != m.KEY_O and not _tap and not s.k.get('accept_pid_events'): return {'eventsPosted': 2}
        if code == m.KEY_O and 'cmd' in mods and not s.k.get('cmdo_dead'): s.panel = True; s.opened_at = s.clk.t if s.clk else None
        if code == m.KEY_ESC and not s.k.get('esc_dead') and s.keyed():
            s.esc_seen += 1
            if s.esc_seen > s.k.get('drop_escapes', 0): s.panel = False
        if code == m.KEY_TAB and not s.k.get('tab_dead'): s.i += -1 if 'shift' in mods and not s.k.get('shift_dead') else (0 if 'shift' in mods else 1)
        return {'eventsPosted': 2}

def drive(mod=None, front=None, **k):
    mod = mod or m
    clk = Clock(); ui = FakeUI(clk, **k)
    mod.stop_apps = lambda *a, **kw: None; mod.pid_of = lambda *a, **kw: 77
    with tempfile.TemporaryDirectory() as o:
        c = mod.run('app', ui, o, lambda a, f: None, lambda pid: None, lambda: 'sources', lambda pid: not k.get('dead'), clock=clk, sleep=clk.sleep, frontmost=front or (lambda: 'Spacelyzer'))
        g, p = c.verdict(); c.write(o); drive.checks = c; drive.ui = ui
        assert (pathlib.Path(o) / 'result.txt').read_text().startswith('PASS' if g else 'FAIL')
        return g, p

g, p = drive(); assert g, p
for name, kw, needle in [('untrusted', dict(trusted=False), 'input-ax-trusted'), ('no focus', dict(no_focus=True), 'input-focus-readable'),
        ('cmd-o dead', dict(cmdo_dead=True), 'input-cmd-o-opens-panel'), ('no events', dict(no_events=True), 'input-cmd-o-opens-panel'),
        ('escape dead', dict(esc_dead=True), 'input-escape-closes-panel'), ('tab dead', dict(tab_dead=True), 'input-tab-moves-focus'),
        ('shift-tab does not reverse', dict(shift_dead=True), 'input-shift-tab-reverses'), ('app died', dict(dead=True), 'input-app-alive-after')]:
    g, p = drive(**kw); assert not g and any(needle in x for x in p), (name, p)
# Escape before the dialog is key (a real-Mac hypothesis): green only with the key-state wait / settle and the retry.
g, p = drive(key_after=1.2); assert g, p
g, p = drive(key_after=1.2, no_focused_attr=True); assert g, p                      # the 1.5s settle path
g, p = drive(key_after=1.2, drop_escapes=1); assert g, p                              # first Escape dropped, the retry closes it
assert 'escape_posts=2' in str(drive.checks.rows), drive.checks.rows
src = open('scripts/ship-input.py').read()
def variant(a, b):
    assert a in src, a
    sp = importlib.util.spec_from_loader('v', loader=None); v = importlib.util.module_from_spec(sp); v.__file__ = 'scripts/ship-input.py'
    exec(compile(src.replace(a, b), 'v', 'exec'), v.__dict__); return v
nowait = variant("if not keyed: sleep(1.5)", "pass"); nowait = variant("if not keyed: sleep(1.5)", "pass") if False else nowait
nowait_src = src.replace("if not keyed: sleep(1.5)", "pass").replace("for tries in range(1, 4):", "for tries in range(1, 2):")
assert "for n in ui.tree(pid)) or None, 5, .5" in nowait_src
nowait_src = nowait_src.replace("for n in ui.tree(pid)) or None, 5, .5", "for n in ui.tree(pid)) or None, 0, .5")
sp = importlib.util.spec_from_loader('v2', loader=None); nowait = importlib.util.module_from_spec(sp); nowait.__file__ = 'scripts/ship-input.py'
exec(compile(nowait_src, 'v2', 'exec'), nowait.__dict__)             # driver mutation: Escape posted at once, no settle, no retry
g, p = drive(nowait, key_after=1.2, no_focused_attr=True); assert not g and any('input-escape-closes-panel' in x for x in p), p
noretry = variant("for tries in range(1, 4):", "for tries in range(1, 2):")   # driver mutation: no retry
g, p = drive(noretry, key_after=1.2, drop_escapes=1); assert not g and any('input-escape-closes-panel' in x for x in p), p
# Escape never closes: red, the Tab legs are red because the panel is open, and Cancel is only a NOTE after the FAIL.
g, p = drive(esc_dead=True); assert not g
need = [x for x in p if 'input-escape-closes-panel' in x] and [x for x in p if 'input-tab-moves-focus' in x and 'panel still open' in x] and [x for x in p if 'input-shift-tab-reverses' in x]
assert need, p
assert 'input-cleanup-cancel' in str(drive.checks.rows) and 'input-dialog-key-state' in str(drive.checks.rows), drive.checks.rows
assert m.panel_open([{'role': 'AXWindow', 'title': 'Spacelyzer'}]) is False and m.panel_open([{'role': 'AXSheet'}]) is True and m.panel_open([{'role': 'AXButton', 'title': 'Open'}]) is False
print('PASS input driver: green on a correct fake, red for untrusted, unreadable focus, Cmd-O dead, no events, Escape dead, Tab dead, Shift-Tab not reversing, dead app; Escape before the dialog is key goes green only with the key-state wait or settle plus retry (a driver without both goes red); Escape that never closes goes red with Tab legs red and Cancel only a NOTE after the FAIL')

# The new delivery path is really exercised: Escape/Tab went through the session tap, Cmd-O through the pid; a driver that still
# posts Escape/Tab to the pid goes red against the tap-only fake (and is green only when the fake accepts pid events).
g, p = drive(); assert g, p
assert ('tap', m.KEY_ESC) in drive.ui.log and ('tap', m.KEY_TAB) in drive.ui.log and ('pid', m.KEY_O) in drive.ui.log and not any(c == ('pid', m.KEY_ESC) for c in drive.ui.log), drive.ui.log
src2 = open('scripts/ship-input.py').read()
for a in ("KEY_ESC, (), True,", "KEY_TAB, (), True,", "KEY_TAB, ('shift',), True,"):
    assert a in src2, a
    src2 = src2.replace(a, a.replace('True,', 'False,'))     # driver mutation: Escape/Tab back on the app-pid path
sp = importlib.util.spec_from_loader('v3', loader=None); oldpath = importlib.util.module_from_spec(sp); oldpath.__file__ = 'scripts/ship-input.py'
exec(compile(src2, 'v3', 'exec'), oldpath.__dict__)
g, p = drive(oldpath); assert not g and any('input-escape-closes-panel' in x for x in p), p   # old pid delivery: red
g, p = drive(oldpath, accept_pid_events=True); assert g, p                                      # control: the fake itself is not the reason
print('PASS input delivery: Escape and Tab go through the session tap (Cmd-O stays pid-posted); a tap-only fake turns the old postToPid delivery red, and the same driver is green when the fake accepts pid events')

# Frontmost guard: a session tap keys whatever is frontmost, so nothing is posted unless Spacelyzer is frontmost.
g, p = drive(front=lambda: 'Finder'); assert not g
assert drive.ui.log == [], drive.ui.log                                   # no key of any kind was posted
assert any("input-cmd-o-opens-panel" in x and "frontmost='Finder'" in x for x in p), p
seq = iter(['Spacelyzer'] + ['Terminal'] * 50)                             # frontmost changes after Cmd-O
g, p = drive(front=lambda: next(seq)); assert not g
assert [c for c in drive.ui.log if c[1] in (m.KEY_ESC, m.KEY_TAB)] == [], drive.ui.log     # Escape and Tab were refused, never posted
assert any("input-escape-closes-panel" in x and "REFUSED" in x and "Terminal" in x for x in p), p
g, p = drive(); assert g, p
assert "path=session-tap frontmost='Spacelyzer'" in str(drive.checks.rows) and "path=pid frontmost='Spacelyzer'" in str(drive.checks.rows), drive.checks.rows
print('PASS input guard: no key is posted unless Spacelyzer is frontmost (all-refused and frontmost-changes-mid-run both red with zero Escape/Tab posts); every check detail records the delivery path and the frontmost name')

# Widened guard: exactly 'Spacelyzer' or 'Open and Save Panel Service (Spacelyzer)'; nothing else (no substring, prefix or case variant).
g, p = drive(front=lambda: 'Open and Save Panel Service (Spacelyzer)'); assert g, p
assert ('tap', m.KEY_ESC) in drive.ui.log
for bad in ('Open and Save Panel Service', 'Open and Save Panel Service (Spacelyzer) ', 'open and save panel service (spacelyzer)', 'Spacelyzer Helper',
            'Open and Save Panel Service (Other)', 'Spacelyzer2', ''):
    g, p = drive(front=lambda b=bad: b); assert not g and drive.ui.log == [], (bad, p, drive.ui.log)
assert sc.ALLOWED_FRONTMOST == ('Spacelyzer', 'Open and Save Panel Service (Spacelyzer)')
print('PASS input guard widening: the exact panel-service name is allowed (green); 7 near-miss names (substring, prefix, trailing space, case, other app, empty) are refused with zero posts')
