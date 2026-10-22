#!/usr/bin/env python3
"""Old-fail/new-pass controls for check-demo-state.py using the recorded shape of run 39843869589 (Linux only, not Mac evidence)."""
import os, sys, tempfile, importlib.util
spec = importlib.util.spec_from_file_location('c', os.path.join(os.path.dirname(__file__), 'check-demo-state.py')); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
def mk(rows):
    d = tempfile.mkdtemp()
    for n, line in rows.items(): open(f'{d}/spz-demo-state-{n}', 'w').write(line + '\n')
    return d
def line(n, w=1280, h=800, sheet=False, key=False, model=False, main=True):
    return f'step={n} main={main} w={w} h={h} sheet={sheet} keyIsSheet={key} alertModel={model} appearance=x'
good = {n: line(n, sheet=n in (71, 72), model=n in (71, 72)) for n in range(70, 76)}
# the defect: the alert sheet was resized and became "the window": no main window, key is a sheet, alert lingers after 72
bad = dict(good); bad[72] = line(72, w=1024, h=700, sheet=True, key=True, model=True)
for n in range(73, 76): bad[n] = line(n, sheet=True, key=True, model=True, main=False)
fails = 0
def t(name, ok):
    global fails; print(('ok   ' if ok else 'FAIL ') + name); fails += 0 if ok else 1
t('good sequence passes', c.check(mk(good), 75, 70) == [])
b = c.check(mk(bad), 75, 70)
t('defect sequence fails and names step 73', any(x.startswith('step 73') for x in b))
t('missing record fails', c.check(mk({n: v for n, v in good.items() if n != 74}), 75, 70) == ['step 74: no state record'])
t('alert missing at 71 fails', any('step 71' in x for x in c.check(mk({**good, 71: line(71)}), 75, 70)))
t('tiny window fails', any('plausible' in x for x in c.check(mk({**good, 73: line(73, w=40, h=40)}), 75, 70)))
sys.exit(1 if fails else 0)
