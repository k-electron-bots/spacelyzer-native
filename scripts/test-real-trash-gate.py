#!/usr/bin/env python3
"""Behavioral offline failure tests for RealTrashMoveChecks' confinement gate and check
predicates. These execute the SAME logic the Swift encodes (realpath canonicalization, temp
prefix + marker gate, and each check's end-state predicate) against real filesystem states
created here, and prove every wrong state fails CLOSED. They test the design behaviorally;
they are not a Swift compile or a Mac run. Exits 1 on any failure."""
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

def case2(restored, size):
    return restored and size == 1000
need(not case2(False, 0), 'case2: nothing restored FAILS')
need(not case2(True, 500), 'case2: restored with wrong size FAILS')
need(case2(True, 1000), 'case2: the real happy state PASSES')

def case3(exists, journal_count, message):
    return exists and journal_count == 0 and message is not None
need(not case3(False, 0, 'refused'), 'case3: file gone despite refusal FAILS')
need(not case3(True, 1, None), 'case3: journaled move despite refusal FAILS')
need(case3(True, 0, 'identity refused'), 'case3: the real refusal state PASSES')

def case4(original_size, trashed_present):
    return original_size == 2000 and trashed_present
need(not case4(9000, True), 'case4: original overwritten by restore FAILS')
need(not case4(2000, False), 'case4: trashed item vanished FAILS')
need(case4(2000, True), 'case4: the real collision state PASSES')

print('gate+predicate behavioral tests OK' if ok else 'BEHAVIORAL FAILURES FOUND')
sys.exit(0 if ok else 1)
