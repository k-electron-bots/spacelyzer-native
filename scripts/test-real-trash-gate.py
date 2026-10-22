#!/usr/bin/env python3
"""Behavioral offline failure tests for RealTrashMoveChecks' confinement gate, check
predicates and cleanup validation. These are DESIGN checks: they mirror the logic the Swift
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

# --- cleanup validation: only this suite's own fixture names in a .Trash may be deleted ---
def cleanup_allowed(path):
    name = os.path.basename(path)
    stem, ext = os.path.splitext(name)
    head = stem.split(' ')[0]
    return '.Trash' in path and ext == '.bin' and head in ('a', 'b', 'c')
need(cleanup_allowed('/Users/u/.Trash/a.bin'), 'cleanup: own trashed fixture file ALLOWED')
need(cleanup_allowed('/Users/u/.Trash/c 2.bin'), "cleanup: Finder dedup copy 'c 2.bin' ALLOWED")
need(not cleanup_allowed('/Users/u/.Trash/taxes.pdf'), 'cleanup: unrelated user file in Trash REFUSED')
need(not cleanup_allowed('/Users/u/.Trash/report.bin'), 'cleanup: .bin but not a fixture name REFUSED')
need(not cleanup_allowed('/tmp/elsewhere/a.bin'), 'cleanup: fixture name outside a .Trash REFUSED')

print('gate+predicate behavioral tests OK' if ok else 'BEHAVIORAL FAILURES FOUND')
sys.exit(0 if ok else 1)
