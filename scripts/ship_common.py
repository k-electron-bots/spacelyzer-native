"""Shared helpers for the ship-candidate evidence drivers. Pure logic plus thin subprocess wrappers; every driver takes
an injectable `ui` object so Linux tests can drive it with a fake. Nothing here is macOS evidence by itself."""
import json, os, pathlib, subprocess, sys, time


class Fail(Exception):
    pass


class Checks:
    """Named PASS/FAIL records. A run is green only when every required name passed exactly once."""
    def __init__(self, required):
        self.required = list(required); self.rows = []
    def ok(self, name, detail=''):
        self.rows.append(('PASS', name, detail))
    def bad(self, name, detail=''):
        self.rows.append(('FAIL', name, detail))
    def note(self, name, detail=''):
        self.rows.append(('NOTE', name, detail))
    def check(self, name, cond, detail=''):
        (self.ok if cond else self.bad)(name, detail); return bool(cond)
    def verdict(self):
        names = [n for s_, n, _ in self.rows if s_ != 'NOTE']
        problems = []
        for r in self.required:
            if names.count(r) != 1: problems.append(f'{r}: recorded {names.count(r)} times')
        problems += [f'{n}: unlisted' for n in set(names) if n not in self.required]
        problems += [f'{n}: FAIL {d}' for s, n, d in self.rows if s == 'FAIL']
        return (not problems), problems
    def write(self, out):
        out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
        (out / 'assertions.txt').write_text(''.join(f'{s} {n} {d}\n' for s, n, d in self.rows))
        good, problems = self.verdict()
        (out / 'result.txt').write_text(
            (f'PASS {len(self.required)} required checks, each exactly once\n' if good else 'FAIL ' + '; '.join(problems) + '\n'))
        return good


def poll(fn, timeout, interval=0.5, clock=time.time, sleep=time.sleep):
    """Call fn until it returns a truthy value or the deadline passes. Returns the value or None. Never raises on timeout."""
    end = clock() + timeout
    while True:
        v = fn()
        if v: return v
        if clock() >= end: return None
        sleep(min(interval, max(0, end - clock())))


class HelperUI:
    """Wrapper over the compiled scripts/ship-ui.swift helper."""
    def __init__(self, path, timeout=20):
        self.path, self.timeout = path, timeout
    def _run(self, *argv):
        p = subprocess.run([self.path, *map(str, argv)], capture_output=True, text=True, timeout=self.timeout)
        rows = []
        for line in p.stdout.splitlines():
            line = line.strip()
            if line.startswith('{'):
                try: rows.append(json.loads(line))
                except ValueError: pass
        return p.returncode, rows
    def trusted(self):
        rc, rows = self._run('trust'); return bool(rows and rows[0].get('trusted'))
    def tree(self, pid):
        rc, rows = self._run('tree', pid)
        if rc != 0: raise Fail(f'ship-ui tree rc={rc} {rows[:1]}')
        return [r for r in rows if 'role' in r]
    def press(self, pid, role, needle):
        rc, rows = self._run('press', pid, role, needle); return rows[-1] if rows else {'found': False, 'rc': rc}
    def set_(self, pid, role, needle, value):
        rc, rows = self._run('set', pid, role, needle, value); return rows[-1] if rows else {'found': False, 'rc': rc}
    def focus(self, pid):
        rc, rows = self._run('focus', pid); return rows[-1] if rows else {}
    def key(self, pid, code, *mods):
        rc, rows = self._run('key', pid, code, *mods); return rows[-1] if rows else {'eventsPosted': 0, 'rc': rc}
    def key_tap(self, pid, code, *mods):
        """Post through the session event tap (goes to the frontmost app, including a remote Open/Save panel), not to the app pid."""
        rc, rows = self._run('keytap', pid, code, *mods); return rows[-1] if rows else {'eventsPosted': 0, 'rc': rc}


def find(nodes, role, needle='', subrole=None):
    for n in nodes:
        if n.get('role') != role: continue
        if subrole is not None and n.get('subrole') != subrole: continue
        if needle and not any(needle in (n.get(k) or '') for k in ('title', 'desc', 'id', 'value')): continue
        return n
    return None


def pid_of(name='Spacelyzer', run=subprocess.run):
    p = run(['pgrep', '-nx', name], capture_output=True, text=True)
    s = p.stdout.strip()
    return int(s) if p.returncode == 0 and s.isdigit() else None


def stop_apps(run=subprocess.run, sleep=time.sleep):
    run(['pkill', '-x', 'Spacelyzer'], check=False)
    for _ in range(30):
        if run(['pgrep', '-x', 'Spacelyzer'], capture_output=True).returncode == 1: return
        sleep(.2)
    run(['pkill', '-9', '-x', 'Spacelyzer'], check=False); sleep(.3)
    if run(['pgrep', '-x', 'Spacelyzer'], capture_output=True).returncode != 1:
        raise Fail('prior app still running')


APP_NAME = 'Spacelyzer'
# Exact names only (no substring or prefix): the app itself, or its remote Open/Save panel service while a panel is up.
ALLOWED_FRONTMOST = ('Spacelyzer', 'Open and Save Panel Service (Spacelyzer)')


def real_frontmost():
    p = subprocess.run(['osascript', '-e', 'tell application "System Events" to get name of first process whose frontmost is true'],
                       capture_output=True, text=True, timeout=20)
    return p.stdout.strip()


def guarded_key(ui, pid, code, mods, tap, frontmost):
    """Post one key ONLY while the app is frontmost (a session tap keys whatever is frontmost). One delivery path per call.
    Returns (result, path, frontmost_name); result is {'eventsPosted': 0, 'refused': name} and nothing is posted when refused."""
    name = frontmost()
    path = 'session-tap' if tap else 'pid'
    if name not in ALLOWED_FRONTMOST: return {'eventsPosted': 0, 'refused': name}, path, name
    r = ui.key_tap(pid, code, *mods) if tap else ui.key(pid, code, *mods)
    return r, path, name
