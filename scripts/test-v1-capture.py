#!/usr/bin/env python3
"""EXECUTED Linux preflight for scripts/v1-capture.sh with stubbed open/pkill/pgrep/screencapture and a stub accessibility helper.
Proves the control flow only (ordering, independence of shots, refusal to confirm a removal unless the confirmation alert is present,
FDA layout check verdicts). It is NOT a Mac result: real AX menus, sheets, popovers and pixels are unverified until a Mac run."""
import os, subprocess, sys, tempfile, shutil
# Structural guard FIRST (fails in milliseconds): a dead check block after an early exit once reported green unexecuted.
lines = [l for l in open(__file__).read().splitlines() if l.strip()]
assert [l for l in lines if l.startswith('sys.exit(')] == [lines[-1]], 'the verdict exit must be the only top-level exit and the last statement'
R = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
fails = []; DUP = []
EXECUTED = [0]; MIN_EXECUTED = 53  # floor: fewer executed checks means a block was skipped or became dead code
def ck(n, ok, d=''):
    EXECUTED[0] += 1
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
def run(env_extra):
    t = tempfile.mkdtemp(); os.makedirs(t + '/stubs'); os.makedirs(t + '/scripts')
    for f in ['v1-capture.sh', 'run-bounded.py','capture-history-wide.sh','capture-stages.py','v1-capture-phase.sh','run-v1-capture.py','session-resize.py']: shutil.copy(R + '/scripts/' + f, t + '/scripts/' + f)
    open(t + '/scripts/make-docs-fixture.sh', 'w').write('#!/bin/bash\nmkdir -p "$1"; echo x > "$1/f"\n')
    open(t + '/stubs/pkill', 'w').write('#!/bin/bash\nexit 0\n')
    open(t + '/stubs/open', 'w').write('#!/bin/bash\necho "open $*" >> "$LOG"\nexit 0\n')
    open(t + '/stubs/pgrep', 'w').write('#!/bin/bash\necho 123\n')
    open(t + '/stubs/screencapture', 'w').write('''#!/bin/bash
for a; do l="$a"; done
[ -n "$EMPTYWIDE" ] && [[ "$l" == *removal-history-wide.png ]] && { : > "$l"; exit 0; }
if [[ "$l" == *removal-history-wide.png ]]; then W=1280; [ -n "$CLIPPEDWIDE" ] && W=992; [ -n "$NARROWWS" ] && W=992
  python3 -c "
import struct,sys,zlib
w=int(sys.argv[1]);h=24;blank=bool(sys.argv[3])
rows=b''.join(b'\\x00'+b''.join(bytes((120,120,120)) if blank else bytes(((x*3)%256,(y*9)%256,(x+y)%256)) for x in range(w)) for y in range(h))
c=lambda t,d:struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d))
open(sys.argv[2],'wb').write(b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+c(b'IDAT',zlib.compress(rows))+c(b'IEND',b''))" $W "$l" "$BLANKWIDE"; exit 0; fi
echo png > "$l"
''')
    open(t + '/helper', 'w').write('''#!/bin/bash
# Faithful scope model of docs-capture.swift: hastext sees the WHOLE tree (background + any dialog); sheettext sees
# only the foreground dialog/popover's own text ($STATE/dialog). The background ALWAYS carries the fixture file's full
# path (the Largest row sits behind the dialog) - only a sheet-scoped check can tell what the DIALOG names.
echo "$*" >> "$LOG"
DIALOGTARGET="$SAMPLE/Archives/Backup 2025.zip"
[ -n "$WRONGTARGET" ] && DIALOGTARGET="/tmp/other/Backup 2025.zip"
[ -n "$LISTROWPATH" ] && DIALOGTARGET="$SAMPLE/Archives"
case "$2" in
 geometry) echo "screen frame=1024x768 visibleFrame=1024x700"; exit 0;;
 resize) [ -n "$WIDERESIZEFAIL" ] && exit 1; touch "$STATE/wide"; echo 'resized 1280x800'; exit 0;;
 windowinfo) if [ -n "$NARROWWS" ]; then echo "11 0 32 42 992 700"; else echo "11 0 32 42 1280 700"; fi; echo "12 3 900 100 300 200";;
 rect) [ -f "$STATE/wide" ] && echo "0,0,1280,800" || echo "0,0,960,600";;
 hastext) grep -q -- "$3" "$STATE/background" "$STATE/dialog" 2>/dev/null || exit 1;;
 nosheet) [ -n "$AXUNAVAILABLE" ] && exit 1; [ ! -f "$STATE/dialog" ]; exit $?;;
 sheettext) grep -q -- "$3" "$STATE/dialog" 2>/dev/null || exit 1;;
 choose) [ -n "$NOMENU" ] && exit 1
   if [ "$3 $4" = "more toolbar items Removed" ]; then
     [ -f "$STATE/dialog" ] && exit 1
     [ -n "$HISTORYNOOPEN" ] && exit 0
     echo "Backup 2025.zip moved to Trash · Put Back" > "$STATE/dialog"; exit 0
   fi
   [ "$3 $4" = "Scan Exclusions…" ] && [ -z "$NOOPEN" ] && printf "Exclusions\nScans skip these locations. Changes apply when you rescan\n" > "$STATE/dialog"
   [ "$3 $4" = "Scan Duplicates…" ] && [ -z "$DUPTIMEOUT" ] && echo "3 groups · 6 files" > "$STATE/dialog"; exit 0;;
 escape) [ -n "$STICKYRESULT" ] && grep -q "Moved Backup" "$STATE/dialog" 2>/dev/null && exit 0; rm -f "$STATE/dialog"; exit 0;;
 frame) if [ "$3" = "Open System Settings" ]; then echo 800,60,150,22; else echo 20,${FIELDY:-95},300,24; fi;;
 dump) echo tree;;
 snapshot) DSTATE=ABSENT; [ -f "$STATE/dialog" ] && DSTATE=LIVE; echo "snapshot dialog=$DSTATE" >> "$LOG"; echo "== tree =="; echo "dialog-state: $DSTATE"
   if [ -f "$STATE/confirmed" ]; then if [ -n "$STALEFOOTER" ]; then echo "1.27 GB in 118 items"; else echo "1.27 GB in 117 items"; fi; else echo "1.46 GB in 118 items"; fi; exit 0;;
 press) if [ "$3" = "OK" ]; then [ -z "$OKSTUCK" ] && rm -f "$STATE/dialog"; exit 0; fi
   if [ "$3" = "Removal history" ] && [ -f "$STATE/wide" ] && [ -n "$WIDENOOPEN" ]; then exit 0; fi
   if [ "$3" = "Removal history" ] && { [ -f "$STATE/dialog" ] || [ -n "$HISTORYOVERFLOW" ]; }; then exit 1; fi
   [ "$3" = "Move selected item to Trash" ] && [ -n "$NOPRESS" ] && exit 1
   [ "$3" = "Move selected item to Trash" ] && [ -z "$NOALERT" ] && printf "Move to Trash? %s\n" "$DIALOGTARGET" > "$STATE/dialog"
   if [ "$3" = "Move to Trash" ] && [ -n "$STALERESULT" ]; then echo "Something else moved to the Trash." > "$STATE/dialog"; echo "press failed: Move to Trash" >&2; exit 1; fi
   if [ "$3" = "Move to Trash" ] && [ -n "$PRESSDISMISS" ]; then touch "$STATE/confirmed"; echo "Moved Backup 2025.zip to the Trash." > "$STATE/dialog"; echo "press failed: Move to Trash" >&2; exit 1; fi
   if [ "$3" = "Move to Trash" ] && [ -n "$CONFIRMNOTFOUND" ]; then echo "not found: Move to Trash" >&2; exit 1; fi
   if [ "$3" = "Move to Trash" ]; then touch "$STATE/confirmed"
     [ -n "$WRONGRESULT" ] && echo "Moved Old Installer.dmg to the Trash." > "$STATE/dialog"
     [ -z "$NORESULT" ] && [ -z "$WRONGRESULT" ] && echo "Moved Backup 2025.zip to the Trash." > "$STATE/dialog"
   fi
   [ "$3" = "Removal history" ] && { [ -n "$NOHISTORY" ] && echo "No removals this session" > "$STATE/dialog" || echo "Backup 2025.zip moved to Trash · Put Back" > "$STATE/dialog"; }
   exit 0;;
esac
''')
    # the background ALWAYS shows the fixture file (the Largest row behind any dialog): full path included
    os.makedirs(t + '/state', exist_ok=True)
    open(t + '/state/background', 'w').write('128 items\n' + t + '/S/Archives/Backup 2025.zip\n')
    for f in os.listdir(t + '/stubs'): os.chmod(t + '/stubs/' + f, 0o755)
    os.chmod(t + '/helper', 0o755)
    env = dict(os.environ, PATH=t + '/stubs:' + os.environ['PATH'], LOG=t + '/log', STATE=t + '/state', HELPER=t + '/helper', SAMPLE=t + '/S', V1_FAST='1', **env_extra)
    open(t + '/log', 'w').close()
    # Stand-in for the app's in-session size responder (the real one is Swift, native-unverified). WIDERESIZEFAIL makes
    # it report what run 40098663789 observed (992x665 on a 1024x768 screen); otherwise a 1280-wide window clipped to the
    # 700pt visible height reported by the stub geometry.
    open(t + '/responder.py', 'w').write('''import json,os,sys,time
d=sys.argv[1];end=time.time()+25
while time.time()<end:
    try:
        tok=open(d+"/spz-size-request-123").read().split()[0]
    except Exception:
        time.sleep(0.05);continue
    w,h=(992,665) if os.environ.get("WIDERESIZEFAIL") else (1280,700)
    json.dump(dict(token=tok,pid=123,ordinaryWindowCount=1,sheetAttached=False,frameWidth=w,frameHeight=h,visibleHeight=700,visibleWidth=1024),open(d+"/spz-size-result-123","w"))
    open(d+"/state/wide","w").close()
    time.sleep(0.2)
''')
    env.update(SPZ_SIZE_DIR=t, SPZ_SIZE_WAIT='1')
    responder = subprocess.Popen([sys.executable, t + '/responder.py', t], env=env)
    rc = subprocess.run(['bash', 'scripts/v1-capture.sh', '/x/App.app', t + '/out'], cwd=t, env=env, capture_output=True).returncode
    responder.kill()
    dup = os.path.exists(t + '/S/Documents/Reports/Annual Summary.pdf') and os.path.exists(t + '/S/Downloads/Annual Summary (1).pdf') and open(t + '/S/Documents/Reports/Annual Summary.pdf', 'rb').read() == open(t + '/S/Downloads/Annual Summary (1).pdf', 'rb').read() and os.path.getsize(t + '/S/Downloads/Annual Summary (1).pdf') == 7340032
    if env_extra.get('V1_BUDGET')!='-1':DUP.append(dup)
    status = open(t + '/out/v1-capture-status.txt').read(); log = open(t + '/log').read().split('\n')
    shots = sorted(f for f in os.listdir(t + '/out') if f.startswith('screenshot-v1-')); dumps = [f for f in os.listdir(t + '/out') if f.startswith('v1-dump-')]
    snaps = [f for f in os.listdir(t + '/out') if f.startswith('v1-snapshot-')]
    snap_bodies = {f: open(t + '/out/' + f).read() for f in snaps}
    import json
    snap_bodies['phase-summary']=json.load(open(t+'/out/phase-stages/stages.json'))
    shutil.rmtree(t); return rc, status, log, shots, dumps, snaps, snap_bodies
CONFIRM = '%d press Move to Trash'.replace('%d', '123')
# static wiring of the REAL helper (the stub above only MODELS it): sheettext must search dialog/sheet/popover scopes only
helper_src = open(R + '/scripts/docs-capture.swift').read()
script_src = open(R + '/scripts/v1-capture-phase.sh').read()
i = helper_src.find('case "sheettext"'); body = helper_src[i:i + 4200] if i != -1 else ''
ck('helper wiring: sheettext exists, scopes to AXSheet/AXPopover/dialog-subrole windows only, fails closed when no scope matches',
   i != -1 and '"AXSheet"' in body and '"AXPopover"' in body and '"AXSystemDialog"' in body and 'guard collapsed.count == 1' in body, i)
script_src = open(R + '/scripts/v1-capture-phase.sh').read()
ck('helper wiring: sheettext collapses ancestor/descendant duplicate scopes (one panel counted once), then requires EXACTLY ONE independent foreground scope (a stale background dialog cannot launder an end state)',
   'AXParent' in body and 'collapsed.count == 1' in body, None)
# CF-cast compile guard (run 39961036509: `as? AXUIElement` is a HARD compile error on the real toolchain -
# "conditional downcast to CoreFoundation type ... will always succeed"; array casts like `as? [AXUIElement]` and
# force casts are fine). Portable static lint here; the EXECUTED compiler proof is the Linux typecheck harness
# (Swift 6.1.2 + real-CF stubs: d10bbf4 fails at the same line/column as the run, this candidate typechecks clean).
import re as _re
_cf_pat = _re.compile(r'as\?\s*(AXUIElement|AXValue|CFString|CFArray|CFDictionary|CFBoolean|CFNumber|CFData)\b')
ck('helper wiring: no conditional downcast to a single CoreFoundation type anywhere in the helper (the compile-killing class from run 39961036509)',
   not _cf_pat.search(helper_src), _cf_pat.search(helper_src))
ck('CF-cast lint is non-vacuous: flags the exact d10bbf4 bad line and any single-CF downcast; allows array casts and force casts',
   _cf_pat.search('guard let parent = read(cur, "AXParent") as? AXUIElement else { break }') is not None
   and _cf_pat.search('x as? CFDictionary') is not None
   and _cf_pat.search('read(el, "AXChildren") as? [AXUIElement]') is None
   and _cf_pat.search('parentRef as! AXUIElement') is None, None)
ck('helper wiring: no Bool literal bridged `as CFTypeRef` either (unproven form; the Mac-proven kCFBooleanTrue idiom is required for AX booleans - lines 83/91)',
   ' as CFTypeRef' not in helper_src and helper_src.count('kCFBooleanTrue') >= 3, None)
j = helper_src.find('case "snapshot"'); sbody = helper_src[j:j + 4200] if j != -1 else ''
ck('helper wiring: snapshot command exists - bounded full-attribute LIVE state (role/subrole/title/value/selected/focused/frame, window list, scope list, selected-target parent chains) and it does NOT skip table/outline rows (the selected target lives there)',
   j != -1 and all(x in sbody for x in ['512', 'AXSelected', 'AXFocused', 'AXParent', 'CGWindowListCopyWindowInfo', '== foreground scopes', 'selected', 'chain']) and 'AXTable' not in sbody.split('== tree')[0], j)
ck('script wiring: live snapshots before/after every mutating action (select-target, trash-confirm-live BEFORE the confirm press, trash-after-press, trash-result-live, exclusions/duplicates/history/fda live) and failure paths keep a snapshot via diag',
   all(x in script_src for x in ['snap exclusions-live', 'snap duplicates-live', 'snap select-target', 'snap trash-confirm-live', 'snap trash-after-press', 'snap trash-result-live', 'snap history-live', 'snap fda-live'])
   and 'diag() { ax dump' in script_src and 'ax snapshot > "$OUT/v1-snapshot-$1.txt"' in script_src
   and script_src.find('snap trash-confirm-live') < script_src.find('press_out=$(ax press "Move to Trash"'), None)
ck('script wiring: observed-readiness gates exist for every content shot (exclusions, duplicates, result on both press paths, history)',
   all(x in script_src for x in ['excl_ok', 'dup_ok', 'press_rc', 'hist_ok', 'STEP-FAIL exclusions-content', 'STEP-FAIL duplicates-content', 'STEP-FAIL trash-result', 'STEP-FAIL history-content']), None)
ck('script wiring: every dialog-dependent check is sheet-scoped (confirmation title, owned-path guard, result postcondition, popover content) and no basename-only guard remains',
   'sheettext "Move to Trash?"' in script_src and 'sheettext "$SAMPLE/Archives/Backup 2025.zip"' in script_src and 'sheettext "Moved Backup 2025.zip"' in script_src
   and 'sheettext "groups ·"' in script_src and 'hastext "Backup 2025.zip"' not in script_src and 'hastext "Move to Trash?"' not in script_src and 'hastext "Moved Backup 2025.zip"' not in script_src, None)
rc, st, log, shots, dumps, snaps, bodies = run({})
ck('happy path: all6original shots plus required wide history, done, rc0', rc == 0 and shots == ['screenshot-v1-duplicates.png', 'screenshot-v1-exclusions.png', 'screenshot-v1-fda-banner.png', 'screenshot-v1-removal-history-wide-popover.png', 'screenshot-v1-removal-history-wide.png', 'screenshot-v1-removal-history.png', 'screenshot-v1-trash-confirm.png', 'screenshot-v1-trash-done.png'] and 'FDA-LAYOUT OK' in st, (rc, shots, st))
ck('live snapshots executed: all 8 stage snapshots written; dialog surfaces captured WHILE LIVE (never after dismissal); the selected-target snapshot is pre-dialog',
   all(f'v1-snapshot-{n}.txt' in snaps for n in ['exclusions-live', 'duplicates-live', 'select-target', 'trash-confirm-live', 'trash-after-press', 'trash-result-live', 'history-live', 'fda-live'])
   and all('dialog-state: LIVE' in bodies.get(f'v1-snapshot-{n}.txt', '') for n in ['exclusions-live', 'duplicates-live', 'trash-confirm-live', 'trash-result-live', 'history-live'])
   and 'dialog-state: ABSENT' in bodies.get('v1-snapshot-select-target.txt', ''), sorted(snaps))
storder = [l for l in st.splitlines() if l.startswith('SNAPSHOT') or l.startswith('OK ')]
seq = [next(i for i, l in enumerate(storder) if l.startswith(x)) for x in ['SNAPSHOT select-target', 'SNAPSHOT trash-confirm-live', 'OK trash-confirm', 'SNAPSHOT trash-after-press', 'SNAPSHOT trash-result-live', 'SNAPSHOT history-live', 'OK removal-history']]
ck('snapshot ordering executed: target state captured before the open press, confirmation captured live before the confirming press and its shot, result and history captured live before their shots',
   seq == sorted(seq), seq)
order = [l for l in log if l]
idx = lambda s: next(i for i, l in enumerate(order) if s in l)
ck('order: exclusions, duplicates, then the trash flow; removal confirmed once, after the alert was checked, before history',
   idx('choose Scan Exclusions…') < idx('sheettext Scans skip these locations') < idx('choose Scan Duplicates…') < idx('sheettext groups ·') < idx('selectrow Backup 2025.zip') < idx('Move selected item to Trash') < idx('sheettext Move to Trash?') < idx('Archives/Backup 2025.zip') < order.index(CONFIRM) < idx('sheettext Moved Backup 2025.zip') < idx('Removal history') < idx('sheettext Backup 2025.zip')
   and order.count(CONFIRM) == 1, order)
rc, st, log, shots, dumps, snaps, bodies = run({'NOALERT': '1'})
ck('MUTATION: confirmation alert absent -> the removal is never confirmed, failure recorded, diagnostic dump kept', CONFIRM not in log and 'FAIL trash-confirm' in st and 'v1-dump-trash-confirm.txt' in dumps, (log, st))
ck('failure path keeps a LIVE-state snapshot too (diagnosable without an investigative rerun)', 'v1-snapshot-trash-confirm.txt' in snaps, snaps)
rc, st, log, shots, dumps, snaps, bodies = run({'NOPRESS': '1'})
ck('MUTATION: Trash button not pressable -> nothing confirmed, failure snapshot kept', CONFIRM not in log and 'STEP-FAIL trash-open' in st and 'v1-snapshot-trash-open.txt' in snaps, (log, st, snaps))
rc, st, log, shots, dumps, snaps, bodies = run({'NOMENU': '1'})
ck('menu failures are independent: cleanup and FDA shots still captured, dumps kept', 'screenshot-v1-trash-confirm.png' in shots and 'screenshot-v1-fda-banner.png' in shots and 'screenshot-v1-exclusions.png' not in shots and len(dumps) == 2, (shots, dumps))
rc, st, log, shots, dumps, snaps, bodies = run({'FIELDY': '60'})
ck('MUTATION: filter field under the banner -> FDA-LAYOUT FAIL recorded (the pre-fix layout is detected)', 'FDA-LAYOUT FAIL' in st, st)
ck('happy path is the only COMPLETE: rc 0 and COMPLETE line', 'V1-CAPTURE COMPLETE' in run({})[1] and run({})[0] == 0)
for k, v in [('FIELDY', '60'), ('NOMENU', '1'), ('NOALERT', '1')]:
    r = run({k: v}); ck('FAIL-CLOSED: %s=%s -> rc 1 and INCOMPLETE, never COMPLETE' % (k, v), r[0] == 1 and 'V1-CAPTURE INCOMPLETE' in r[1] and 'COMPLETE:' not in r[1].replace('INCOMPLETE:', ''), r[:2])
rc, st, log, shots, dumps, snaps, bodies = run({})
opens = [l for l in log if l.startswith('open ')]
ck('exclusions/duplicates run on a 1280x800 instance (960x600 collapses the Scan menu into "more toolbar items"), the Trash flow and FDA shot stay at 960x600',
   len(opens) >= 4 and 'SPZ_WINDOW_SIZE=1280x800' in opens[0] and 'SPZ_WINDOW_SIZE=1280x800' in opens[1] and 'SPZ_WINDOW_SIZE=960x600' in opens[2] and 'SPZ_WINDOW_SIZE=960x600' in opens[3], opens)
rc, st, log, shots, dumps, snaps, bodies = run({'PRESSDISMISS': '1'})
ck('AXPress error after the alert really dismissed (element invalidated mid-action): outcome verified fail-closed, Trash flow completes, rc 0',
   rc == 0 and 'outcome verified' in st and 'screenshot-v1-trash-done.png' in shots and 'screenshot-v1-removal-history.png' in shots and 'STEP-FAIL' not in st, (rc, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'NOOPEN': '1'})
ck('MUTATION: Exclusions sheet never opens -> readiness gate refuses, no shot, rc 1 (a successful menu press is not proof)',
   rc == 1 and 'STEP-FAIL exclusions-content' in st and 'screenshot-v1-exclusions.png' not in shots, (rc, st, shots))
_h = run({})[1]
ck('footer gate executed on a fresh happy-path run: reads 118 -> 117 and records footer-count OK', 'footer-count OK: 118 -> 117' in _h and 'STEP-FAIL footer-count' not in _h, _h)
rc, st, log, shots, dumps, snaps, bodies = run({'STALEFOOTER': '1'})
ck('MUTATION: footer stays at 118 after the removal (the run 40194081483 defect) -> STEP-FAIL footer-count, rc 1, shots still captured as evidence', rc == 1 and 'STEP-FAIL footer-count' in st and 'before=118 after=118' in st and 'screenshot-v1-trash-done.png' in shots and 'screenshot-v1-removal-history.png' in shots, (rc, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'DUPTIMEOUT': '1'})
ck('MUTATION: Duplicates markers never appear -> the wait is a GATE, no shot, rc 1 (missing readiness never counts OK)',
   rc == 1 and 'STEP-FAIL duplicates-content' in st and 'screenshot-v1-duplicates.png' not in shots, (rc, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'NORESULT': '1'})
ck('MUTATION: confirm press SUCCEEDS but no result dialog appears -> success path is postcondition-checked too, STEP-FAIL trash-result, rc 1',
   rc == 1 and 'STEP-FAIL trash-result' in st and 'screenshot-v1-trash-done.png' not in shots and 'screenshot-v1-removal-history.png' not in shots, (rc, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'WRONGRESULT': '1'})
ck('MUTATION: result dialog names a DIFFERENT file -> target-scoped postcondition refuses, rc 1',
   rc == 1 and 'STEP-FAIL trash-result' in st and 'screenshot-v1-trash-done.png' not in shots, (rc, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'NOHISTORY': '1'})
ck('MUTATION: history popover opens WITHOUT the target journal entry -> readiness gate refuses the shot, rc 1',
   rc == 1 and 'STEP-FAIL history-content' in st and 'screenshot-v1-removal-history.png' not in shots and 'screenshot-v1-trash-done.png' in shots, (rc, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'CONFIRMNOTFOUND': '1'})
ck('MUTATION: confirm button genuinely absent -> still STEP-FAIL, never verified by outcome, rc 1', rc == 1 and 'STEP-FAIL trash-confirm-press' in st and 'outcome verified' not in st, (rc, st))
rc, st, log, shots, dumps, snaps, bodies = run({'WRONGTARGET': '1'})
ck('MUTATION: dialog names a HOMONYMOUS file outside the fixture (background row carries the owned path) -> sheet-scoped guard refuses, nothing confirmed, escaped, rc 1',
   rc == 1 and CONFIRM not in log and 'FAIL trash-scope' in st and 'v1-dump-trash-scope.txt' in dumps and 'screenshot-v1-trash-confirm.png' not in shots, (rc, log, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'LISTROWPATH': '1'})
ck('MUTATION: dialog names the Archives FOLDER while the background Largest row carries the file path (the run-39947043378 pixels) -> sheet-scoped guard refuses, nothing confirmed, rc 1',
   rc == 1 and CONFIRM not in log and 'FAIL trash-scope' in st and 'screenshot-v1-trash-confirm.png' not in shots, (rc, log, st, shots))
rc, st, log, shots, dumps, snaps, bodies = run({'STALERESULT': '1'})
ck('MUTATION: press errors and only a STALE generic result text (no confirm happened) is visible -> the scoped postcondition refuses, STEP-FAIL, rc 1',
   rc == 1 and 'STEP-FAIL trash-result' in st and 'outcome verified' not in st and 'screenshot-v1-trash-done.png' not in shots, (rc, log, st, shots))
r = run({'V1_BUDGET': '-1'}); ck('FAIL-CLOSED: exhausted time budget skips shots, rc 1, INCOMPLETE', r[0] == 1 and 'capture-deadline' in r[1] and 'INCOMPLETE' in r[1], r[:2])
ck('capture-owned fixture copy holds an identical non-zero 7 MB duplicate pair in every run', DUP and all(DUP), DUP)
r = run({'STICKYRESULT':'1', 'HISTORYOVERFLOW':'1'})
ck('declared model only: Escape-resistant result + successful overflow popover uses OK/dismissal then menu, all6shots', r[0]==0 and 'screenshot-v1-removal-history.png' in r[3] and 'dialog-state: ABSENT' in r[6].get('v1-snapshot-trash-dismissed-live.txt', ''), r[:2])
r = run({'STICKYRESULT':'1', 'OKSTUCK':'1'})
ck('negative: OK does not dismiss result -> no history shot and explicit failure', r[0]==1 and 'STEP-FAIL result-dismiss' in r[1] and 'screenshot-v1-removal-history.png' not in r[3] and 'screenshot-v1-trash-done.png' not in r[3], r[:2])
r = run({'AXUNAVAILABLE':'1'})
ck('negative: inaccessible AX does not prove dismissal or authorize done/history shots', r[0]==1 and 'screenshot-v1-trash-done.png' not in r[3] and 'screenshot-v1-removal-history.png' not in r[3], r[:2])
r = run({'HISTORYOVERFLOW':'1','NOHISTORY':'1'})
# The declared stub's overflow branch models successful opening only. Snapshot
# wiring is checked below independently; this is not evidence for native opening.
ck('diagnostic history boundaries retained: before/direct-failed/after-open', all('v1-snapshot-'+n+'.txt' in r[5] for n in ['history-before-open','history-direct-press-failed','history-after-open']), r[5])
r = run({'HISTORYOVERFLOW':'1','HISTORYNOOPEN':'1'})
ck('actual run40042043674 failure-shape control: direct history absent, overflow returns success WITHOUT popover -> history refused, done retained, no repeated open',
   r[0]==1 and 'STEP-FAIL history-content' in r[1] and 'screenshot-v1-removal-history.png' not in r[3] and 'screenshot-v1-trash-done.png' in r[3] and sum('choose more toolbar items Removed' in x for x in r[2])==1 and sum('press Removal history' in x for x in r[2])==1,
   (r[0],r[1],r[3]))
r=run({})
opens=[x for x in r[2] if x.startswith('open ')]
wideidx=next(i for i,x in enumerate(r[2]) if 'windowinfo' in x)
fdaidx=next(i for i,x in enumerate(r[2]) if x.startswith('open ') and 'SPZ_DEMO_FDA_REFUSED=1' in x)
ck('wide capture same PID/session: resize after compact history, before FDA relaunch, no second removal',len(opens)==4 and wideidx<fdaidx and sum(x=='123 press Move to Trash' for x in r[2])==1 and 'dialog-state: LIVE' in r[6].get('v1-snapshot-history-wide-live.txt',''),r[2])
wide_source=open(R+'/scripts/capture-history-wide.sh').read()
ck('wide stage budget invariant: entire20s wrapper requires20s remaining inside original165s; six original shot count unchanged', 'START + 20' in script_src and '"$BOUND" 20 bash scripts/capture-history-wide.sh' in script_src and 'BUDGET="${V1_BUDGET:-165}"' in script_src and "oks==6" in open(R+'/scripts/run-v1-capture.py').read())
ck('actual resize helper verifies unique ordinary window and observed dimensions, not set-return success alone', 'case "resize":' in helper_src and 'mainWindows.count == 1' in helper_src and 'AXStandardWindow' in helper_src and 'abs(actual.width-width) <= 2' in helper_src and 'abs(actual.height-height) <= 2' in helper_src)
r=run({'NOOPEN':'1','WIDERESIZEFAIL':'1'})
summary=r[6]['phase-summary']
ck('real multi-fault path: exclusions failure does not hide cleanup wide failure or independentFDA; both failures retained/finalred',r[0]==1 and 'STEP-FAIL exclusions-content' in r[1] and 'STEP-FAIL history-wide' in r[1] and 'screenshot-v1-fda-banner.png' in r[3] and set(summary['failed'])=={'exclusions','cleanup'} and summary['endstates']['exclusions']['status']=='blocked',r[:2])
r=run({'NOALERT':'1','NOOPEN':'1'})
ck('real prerequisite refusal: no confirmation means no destructive confirm/history, independentduplicates/FDA stillcaptured, blockedendstatesnotfakepassed',r[0]==1 and CONFIRM not in r[2] and 'screenshot-v1-duplicates.png' in r[3] and 'screenshot-v1-fda-banner.png' in r[3] and r[6]['phase-summary']['endstates']['removal-history']['status']=='blocked',r[:2])
for mode in ['WIDERESIZEFAIL','WIDENOOPEN']:
 r=run({mode:'1'})
 ck('wide-stage refusal '+mode+' retains all6original shots but cannot COMPLETE',r[0]==1 and 'WIDE-HISTORY OK:' not in r[1] and 'screenshot-v1-removal-history-wide.png' not in r[3] and 'screenshot-v1-removal-history.png' in r[3] and 'STEP-FAIL history-wide' in r[1],r[:2])
r=run({'EMPTYWIDE':'1'})
ck('zero-byte wideimage rc0 cannot pass aggregate; originalsix andFDA retained',r[0]==1 and not r[6]['phase-summary']['complete'] and r[6]['phase-summary']['endstates']['removal-history-wide']['status']=='blocked' and 'FDA-LAYOUT OK' in r[1] and len(r[3])==8,r[:2])

# --- in-session size path + window-id capture gate (Linux model only; native behavior unverified) ---
r = run({'CLIPPEDWIDE': '1'})
ck('MUTATION: a clipped 992-wide wide image (the rect-capture shape from run 40098663789) cannot COMPLETE and its endstate is not captured',
   r[0] == 1 and 'WIDE-HISTORY OK:' not in r[1] and 'V1-CAPTURE COMPLETE' not in r[1] and r[6]['phase-summary']['endstates']['removal-history-wide']['status'] == 'blocked', (r[0], r[1][-600:]))
r = run({'WIDERESIZEFAIL': '1'})
ck('MUTATION: app reports 992x665 (run 40098663789 geometry) -> resize fails, dependents BLOCKED, wide image absent, INCOMPLETE names the missing wide state and says the six originals exclude it',
   r[0] == 1 and 'removal-history-wide' in r[1].split('V1-CAPTURE INCOMPLETE')[-1] and 'do NOT include the wide history shot' in r[1] and 'screenshot-v1-removal-history-wide.png' not in r[3], r[1][-700:])
r = run({})
ck('happy path summary: COMPLETE line names 7 of 7 required end states', '7 of 7 required end states' in r[1], r[1][-400:])

r = run({'BLANKWIDE': '1'})
ck('MUTATION: right-hand strip of the wide image is blank fill -> image-content fails, wide end state not captured, never COMPLETE',
   r[0] == 1 and 'WIDE-HISTORY OK:' not in r[1] and r[6]['phase-summary']['endstates']['removal-history-wide']['status'] == 'blocked', r[1][-500:])

r = run({'NARROWWS': '1'})
ck('MUTATION: windowserver bounds and image both 992 while the app report says 1280 (agreement on a narrower frame) -> never COMPLETE, judged against the requested 1280',
   r[0] == 1 and 'WIDE-HISTORY OK:' not in r[1] and r[6]['phase-summary']['endstates']['removal-history-wide']['status'] == 'blocked', r[1][-400:])

# Execution-evidence guard: the final verdict must be the LAST statement, so no check can sit after the exit
# (a dead mutation block once reported green without running). Counts executed checks; the preflight requires a floor.
print('\n%d checks executed, %d failed' % (EXECUTED[0], len(fails)))
sys.exit(1 if fails or EXECUTED[0] < MIN_EXECUTED else 0)
