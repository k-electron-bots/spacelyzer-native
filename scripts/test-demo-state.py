#!/usr/bin/env python3
"""Old-fail/new-pass controls for check-demo-state.py using the recorded shape of run 39843869589 (Linux only, not Mac evidence)."""
import os, sys, tempfile, importlib.util
spec = importlib.util.spec_from_file_location('c', os.path.join(os.path.dirname(__file__), 'check-demo-state.py')); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
def mk(rows):
    d = tempfile.mkdtemp()
    for n, line in rows.items(): open(f'{d}/spz-demo-state-{n}', 'w').write(line + '\n')
    return d
def line(n, w=1280, h=800, sheet=False, key=False, model=False, main=True):
    sid = 'removal-result' if model else ('notscanned' if sheet else 'none')
    rows = 3 if (sheet and not model) else 0
    return f'step={n} main={str(main).lower()} w={w} h={h} sheet={str(sheet).lower()} keyIsSheet={str(key).lower()} alertModel={str(model).lower()} sheetId={sid} sheetRows={rows} appearance=NSAppearanceNameAqua'
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
# the exact line shape Swift's DemoInput.stateLine interpolation produces for a healthy step (lowercase Bool), and for the stale-alert defect
healthy = 'step=12 main=true w=1280 h=800 sheet=false keyIsSheet=false alertModel=false sheetId=none sheetRows=0 appearance=NSAppearanceNameAqua'
def healthy81(n):
    # per-step designed state: the Moved-to-Trash alert is up at 71-72; the designed Not-scanned sheet (no alert) is up and key at 78
    line = healthy.replace('step=12', f'step={n}')
    if n in (71, 72): line = line.replace('sheet=false', 'sheet=true').replace('alertModel=false', 'alertModel=true').replace('sheetId=none', 'sheetId=removal-result')
    if n == 78: line = line.replace('sheet=false', 'sheet=true').replace('keyIsSheet=false', 'keyIsSheet=true').replace('sheetId=none', 'sheetId=notscanned').replace('sheetRows=0', 'sheetRows=3')
    return line
t('real healthy Swift-format line passes (all 81 steps healthy, alert at 71/72, Not-scanned sheet at 78)', c.check(mk({n: healthy81(n) for n in range(1, 82)}), 81) == [])
t('intended Not-scanned sheet at 78 (sheet key, no alert model) passes', c.check(mk({78: healthy81(78)}), 78, 78) == [])
t('stale alert model at 78 still fails (the sheet must NOT be an alert)', c.check(mk({78: healthy81(78).replace('alertModel=false', 'alertModel=true')}), 78, 78) != [])
t('intended sheet missing at 78 fails', c.check(mk({78: healthy81(78).replace('sheet=true', 'sheet=false').replace('keyIsSheet=true', 'keyIsSheet=false')}), 78, 78) != [])
t('a sheet at 77 (no designed sheet there) fails', c.check(mk({77: healthy81(77).replace('sheet=false', 'sheet=true')}), 77, 77) != [])
t('sheet present but not key at 78 fails (the shot needs the sheet frontmost)', c.check(mk({78: healthy81(78).replace('keyIsSheet=true', 'keyIsSheet=false')}), 78, 78) != [])
stale = 'step=73 main=false w=1024 h=700 sheet=true keyIsSheet=true alertModel=true sheetId=removal-result sheetRows=0 appearance=NSAppearanceNameDarkAqua'
t('real stale-alert Swift-format line fails', c.check(mk({73: stale}), 73, 73) != [])
t('wrong sheet identity at 78 fails (only the designed Not-scanned sheet is allowed)', c.check(mk({78: healthy81(78).replace('sheetId=notscanned', 'sheetId=unknown')}), 78, 78) != [])
t('sheet up but content not loaded at 78 fails (mid-presentation spinner is not a publishable shot)', c.check(mk({78: healthy81(78).replace('sheetRows=3', 'sheetRows=0')}), 78, 78) != [])
t('wrong alert identity at 71 fails', c.check(mk({71: healthy81(71).replace('sheetId=removal-result', 'sheetId=unknown')}), 71, 71) != [])
t('missing identity fields at 78 fail closed', c.check(mk({78: 'step=78 main=true w=1280 h=800 sheet=true keyIsSheet=true alertModel=false appearance=x'}), 78, 78) != [])
t('capitalised Python-style booleans are NOT accepted', c.check(mk({12: healthy.replace('true', 'True').replace('false', 'False')}), 12, 12) != [])
sys.exit(1 if fails else 0)
