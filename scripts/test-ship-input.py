#!/usr/bin/env python3
"""Linux controls for scripts/ship-input.py against a stateful fake UI: green path, and red for each broken behavior.
Not Mac execution: real key delivery, panels and focus traversal stay native-unverified."""
import importlib.util, pathlib, sys, tempfile
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('shipinput', 'scripts/ship-input.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import ship_common as sc

class Clock:
    def __init__(s): s.t = 0.0
    def __call__(s): return s.t
    def sleep(s, d): s.t += max(d, .01)

class FakeUI:
    ORDER = [{'role': 'AXButton', 'desc': 'Scan', 'path': '/0'}, {'role': 'AXButton', 'desc': 'Export', 'path': '/1'}, {'role': 'AXOutline', 'desc': 'Items', 'path': '/2'}]
    def __init__(s, **k): s.k = k; s.panel = False; s.i = 0
    def trusted(s): return s.k.get('trusted', True)
    def tree(s, pid):
        n = [{'role': 'AXWindow', 'title': 'Spacelyzer', 'depth': 1}]
        if s.panel: n.append({'role': 'AXWindow', 'subrole': 'AXDialog', 'title': 'Open', 'depth': 1})
        return n
    def focus(s, pid): return {} if s.k.get('no_focus') else {'node': s.ORDER[s.i % 3]}
    def key(s, pid, code, *mods):
        if s.k.get('no_events'): return {'eventsPosted': 0}
        if code == m.KEY_O and 'cmd' in mods and not s.k.get('cmdo_dead'): s.panel = True
        if code == m.KEY_ESC and not s.k.get('esc_dead'): s.panel = False
        if code == m.KEY_TAB and not s.k.get('tab_dead'): s.i += -1 if 'shift' in mods and not s.k.get('shift_dead') else (0 if 'shift' in mods else 1)
        return {'eventsPosted': 2}

def drive(**k):
    clk = Clock(); ui = FakeUI(**k)
    m.stop_apps = lambda *a, **kw: None; m.pid_of = lambda *a, **kw: 77
    with tempfile.TemporaryDirectory() as o:
        c = m.run('app', ui, o, lambda a, f: None, lambda pid: None, lambda: 'sources', lambda pid: not k.get('dead'), clock=clk, sleep=clk.sleep)
        g, p = c.verdict(); c.write(o)
        assert (pathlib.Path(o) / 'result.txt').read_text().startswith('PASS' if g else 'FAIL')
        return g, p

g, p = drive(); assert g, p
for name, kw, needle in [('untrusted', dict(trusted=False), 'input-ax-trusted'), ('no focus', dict(no_focus=True), 'input-focus-readable'),
        ('cmd-o dead', dict(cmdo_dead=True), 'input-cmd-o-opens-panel'), ('no events', dict(no_events=True), 'input-cmd-o-opens-panel'),
        ('escape dead', dict(esc_dead=True), 'input-escape-closes-panel'), ('tab dead', dict(tab_dead=True), 'input-tab-moves-focus'),
        ('shift-tab does not reverse', dict(shift_dead=True), 'input-shift-tab-reverses'), ('app died', dict(dead=True), 'input-app-alive-after')]:
    g, p = drive(**kw); assert not g and any(needle in x for x in p), (name, p)
assert m.panel_open([{'role': 'AXWindow', 'title': 'Spacelyzer'}]) is False and m.panel_open([{'role': 'AXSheet'}]) is True and m.panel_open([{'role': 'AXButton', 'title': 'Open'}]) is False
print('PASS input driver: green on a correct fake, red for untrusted, unreadable focus, Cmd-O dead, no events, Escape dead, Tab dead, Shift-Tab not reversing, dead app')
