#!/usr/bin/env python3
"""Behavioral offline failure tests for RealTrashMoveChecks' confinement gate, check
predicates, the identity premise and cleanup validation. These are DESIGN checks: they mirror the logic the Swift
encodes (realpath canonicalization, temp prefix + marker gate, each check's end-state
predicate, the cleanup allowlist) in Python and prove every wrong state fails CLOSED. They are
NOT an execution of the Swift logic, not a Swift compile and not a Mac run - they can miss a
Swift that diverges from this mirror. Exits 1 on any failure."""
import os, sys, tempfile, uuid, shutil

ok = True
def need(cond, msg):
    global ok
    print(('PASS' if cond else 'FAIL'), '-', msg)
    if not cond: ok = False

# --- the gate, exactly as the Swift encodes it ---
def gate_allows(root, tmp_root):
    root = os.path.realpath(root)
    tmp_root = os.path.realpath(tmp_root)
    return root.startswith(tmp_root + os.sep) and 'spz-rtm-' in root

tmp = tempfile.mkdtemp()
try:
    # 1. a normal suite fixture passes the gate (design allows the intended path)
    fix = os.path.join(tmp, 'spz-rtm-' + str(uuid.uuid4()))
    os.makedirs(fix)
    need(gate_allows(fix, tmp), 'normal spz-rtm fixture under temp is ALLOWED (intended path)')

    # 2. same directory without the marker: closed
    nomarker = os.path.join(tmp, 'spz-other-' + str(uuid.uuid4()))
    os.makedirs(nomarker)
    need(not gate_allows(nomarker, tmp), 'marker-missing path under temp is REFUSED')

    # 3. symlink escape: a path INSIDE temp whose realpath lands OUTSIDE temp: closed
    outside = tempfile.mkdtemp(prefix='spz-rtm-outside-')
    link = os.path.join(tmp, 'spz-rtm-link')
    os.symlink(outside, link)
    need(not gate_allows(link, tmp), 'symlink escaping temp is REFUSED after realpath')

    # 4. the temp root itself is not a valid fixture: closed
    need(not gate_allows(tmp, tmp), 'temp root itself is REFUSED (no prefix match)')

    # 5. a marker path outside temp: closed
    need(not gate_allows(outside, tmp), 'marker path outside temp is REFUSED')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(outside, ignore_errors=True)

# --- each check's end-state predicate, fed wrong states: every one must fail ---
def case1(file_exists, journal, trashed_exists, trashed_path, root):
    return (not file_exists) and len(journal) == 1 and trashed_exists \
        and not trashed_path.startswith(root) and '.Trash' in trashed_path
root = '/tmp/spz-rtm-x'
need(not case1(True, [('o','/home/u/.Trash/a.bin')], True, '/home/u/.Trash/a.bin', root), 'case1: file still present FAILS')
need(not case1(False, [], False, '', root), 'case1: empty journal FAILS (no index crash, short-circuit)')
need(not case1(False, [('o','/tmp/elsewhere/a.bin')], True, '/tmp/elsewhere/a.bin', root), 'case1: landing outside a .Trash FAILS (confinement)')
need(not case1(False, [('o', root + '/a.bin')], True, root + '/a.bin', root), 'case1: file moved within the fixture FAILS')
need(case1(False, [('o','/home/u/.Trash/a.bin')], True, '/home/u/.Trash/a.bin', root), 'case1: the real happy state PASSES')

def case2(settled, restored, size, kind):
    return settled and restored and size == 1000 and kind == 'putBack'
need(not case2(False, True, 1000, 'putBack'), 'case2: engine commit not settled (undo would be refused) FAILS')
need(not case2(True, False, 0, 'notMoved'), 'case2: nothing restored FAILS')
need(not case2(True, True, 500, 'putBack'), 'case2: restored with wrong size FAILS')
need(not case2(True, True, 1000, 'notMoved'), 'case2: restored but wrong report kind FAILS')
need(case2(True, True, 1000, 'putBack'), 'case2: the real happy state PASSES')

def case3(exists, journal_count, message, kind):
    return exists and journal_count == 0 and message is not None \
        and 'was replaced since the scan' in message and kind == 'notMoved'
need(not case3(False, 0, 'This item was replaced since the scan', 'notMoved'), 'case3: file gone despite refusal FAILS')
need(not case3(True, 1, 'This item was replaced since the scan', 'notMoved'), 'case3: journaled move despite refusal FAILS')
need(not case3(True, 0, None, 'notMoved'), 'case3: no message FAILS (cause unproven)')
need(not case3(True, 0, 'Please wait for the previous change to finish.', 'notMoved'), 'case3: in-flight gate message, not the identity verdict, FAILS')
need(not case3(True, 0, 'This item was replaced since the scan', 'moved'), 'case3: identity message but wrong kind FAILS')
need(case3(True, 0, 'This item was replaced since the scan, so it is not the item you reviewed.', 'notMoved'),
     'case3: the real identity-refusal state PASSES')

def case4(settled, original_size, trashed_present, message, kind, journal_count):
    return settled and original_size == 2000 and trashed_present and message is not None \
        and 'something already exists at' in message and kind == 'notMoved' and journal_count == 1
need(not case4(False, 2000, True, 'Could not put it back: something already exists at /r/c.bin', 'notMoved', 1),
     'case4: unsettled engine state (undo refused before the probe) FAILS')
need(not case4(True, 9000, True, 'collision msg', 'notMoved', 1), 'case4: original overwritten by restore FAILS')
need(not case4(True, 2000, False, 'collision msg', 'notMoved', 1), 'case4: trashed item vanished FAILS')
need(not case4(True, 2000, True, 'Please wait for the previous change to finish.', 'notMoved', 1),
     'case4: in-flight gate message, not the collision, FAILS')
need(not case4(True, 2000, True, 'Could not put it back: something already exists at /r/c.bin', 'putBack', 0),
     'case4: collision message but journal forgotten + wrong kind FAILS')
need(case4(True, 2000, True, 'Could not put it back: something already exists at /r/c.bin', 'notMoved', 1),
     'case4: the real collision state PASSES')

# --- identity premise: the verdict is kind/dev/inode ONLY (engine/src/inspect.rs review_scanned) ---
prem = tempfile.mkdtemp()
try:
    f = os.path.join(prem, 'item.bin')
    with open(f, 'wb') as fh: fh.write(b'1' * 1000)
    s1 = os.lstat(f)
    with open(f, 'wb') as fh: fh.write(b'2' * 7000)   # non-atomic in-place overwrite
    s2 = os.lstat(f)
    need(s1.st_ino == s2.st_ino and s1.st_dev == s2.st_dev,
         'premise: in-place size change KEEPS the inode - size alone can never force the refusal')
    fd, tf = tempfile.mkstemp(dir=prem)                 # atomic replace: temp file + rename
    os.write(fd, b'3' * 7000); os.close(fd); os.rename(tf, f)
    s3 = os.lstat(f)
    need(s3.st_ino != s1.st_ino and s3.st_dev == s1.st_dev,
         'premise: atomic replace CHANGES the inode (same device) -> verdict .replaced')
finally:
    shutil.rmtree(prem, ignore_errors=True)

# --- cleanup ownership: unique run-marked names + device/inode revalidation before any delete ---
def cleanup_allowed(path, marker, rec_dev, rec_ino, rec_size):
    name = os.path.basename(path)
    stem, ext = os.path.splitext(name)
    head = stem.split(' ')[0]
    if '.Trash' not in path or ext != '.bin' or head not in (marker + '-a', marker + '-b', marker + '-c'):
        return False
    try:
        st = os.lstat(path)
    except OSError:
        return False
    # inode numbers can be recycled, so the recorded size must match too
    return st.st_dev == rec_dev and st.st_ino == rec_ino and st.st_size == rec_size
trashdir = tempfile.mkdtemp(suffix='-.Trash')
try:
    marker = 'spz-rtm-' + str(uuid.uuid4())
    own = os.path.join(trashdir, marker + '-a.bin')
    with open(own, 'wb') as fh: fh.write(b'x')
    rec = os.lstat(own)
    need(cleanup_allowed(own, marker, rec.st_dev, rec.st_ino, rec.st_size), 'cleanup: own trashed fixture file (name+dev+ino+size match) ALLOWED')
    os.remove(own)
    with open(own, 'wb') as fh: fh.write(b'yy')         # freed pathname reused by a NEW file
    need(not cleanup_allowed(own, marker, rec.st_dev, rec.st_ino, rec.st_size),
         'cleanup: freed path reused REFUSED even if the fs recycles the inode (size differs)')
    cur = os.lstat(own)
    need(not cleanup_allowed(own, marker, cur.st_dev, cur.st_ino + 1, cur.st_size),
         'cleanup: recorded inode mismatch REFUSED')
    need(not cleanup_allowed(own, marker, cur.st_dev, cur.st_ino, cur.st_size + 1),
         'cleanup: recorded size mismatch REFUSED')
    other = os.path.join(trashdir, 'taxes-' + marker + '-a.bin.pdf')
    open(other, 'wb').close()
    ost2 = os.lstat(other)
    need(not cleanup_allowed(other, marker, ost2.st_dev, ost2.st_ino, ost2.st_size), 'cleanup: unrelated file in Trash REFUSED')
    outsider = os.path.join(tempfile.gettempdir(), marker + '-b.bin')
    open(outsider, 'wb').close()
    ost = os.lstat(outsider)
    need(not cleanup_allowed(outsider, marker, ost.st_dev, ost.st_ino, ost.st_size), 'cleanup: fixture-marked name outside a .Trash REFUSED')
    os.remove(outsider)
finally:
    shutil.rmtree(trashdir, ignore_errors=True)

print('gate+predicate behavioral tests OK' if ok else 'BEHAVIORAL FAILURES FOUND')
sys.exit(0 if ok else 1)
