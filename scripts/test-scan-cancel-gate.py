#!/usr/bin/env python3
"""Behavioral offline failure tests for Legacy cancellation predicate examples and safety gate. DESIGN
checks only: the deterministic Swift suite is now covered at its worker rendezvous by real
Rust tests in engine/tests/ci_scan_gate.rs. These old timing examples are not that coverage. They are NOT an execution of the
Swift logic, not a Swift compile and not a Mac run. Exits 1 on any failure."""
import os, sys, tempfile, uuid, shutil

ok = True
def need(cond, msg):
    global ok
    print(('PASS' if cond else 'FAIL'), '-', msg)
    if not cond: ok = False

def gate_allows(root, tmp_root):
    root = os.path.realpath(root)
    tmp_root = os.path.realpath(tmp_root)
    return root.startswith(tmp_root + os.sep) and 'spz-cxl-' in root

tmp = tempfile.mkdtemp()
try:
    fix = os.path.join(tmp, 'spz-cxl-' + str(uuid.uuid4()))
    os.makedirs(fix)
    need(gate_allows(fix, tmp), 'normal spz-cxl fixture under temp is ALLOWED (intended path)')
    outside = tempfile.mkdtemp(prefix='spz-cxl-outside-')
    link = os.path.join(tmp, 'spz-cxl-link')
    os.symlink(outside, link)
    need(not gate_allows(link, tmp), 'symlink escaping temp is REFUSED after realpath')
    need(not gate_allows(outside, tmp), 'marker path outside temp is REFUSED')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(outside, ignore_errors=True)

FULL = 150_301
# case 1: stopped within bound, no error, partial tree flagged cancelled
def case1(stopped, stop_ms, error, has_tree, cancelled, nodes):
    return stopped and stop_ms < 10_000 and error is None and has_tree and cancelled and nodes < FULL
need(not case1(False, 10_500, None, True, True, 80_000), 'case1: cancel never stopped (timeout) FAILS')
need(not case1(True, 12_000, None, True, True, 80_000), 'case1: completion beyond the coarse 10s bound FAILS')
need(not case1(True, 300, 'The scan failed.', True, True, 80_000), 'case1: error published FAILS')
need(not case1(True, 300, None, False, False, 0), 'case1: no tree at all FAILS (partial tree is the designed outcome)')
need(not case1(True, 300, None, True, True, FULL), 'case1: complete node count is non-green INCONCLUSIVE coverage (not ignored-cancel proof)')
need(not case1(True, 300, None, True, False, 80_000), 'case1: unflagged tree FAILS (silently complete-looking)')
need(case1(True, 300, None, True, True, 80_000), 'case1: the real happy state PASSES')

# case 2: immediate cancel returns promptly; tree nil or flagged cancelled
def case2(imm_ms, has_tree, cancelled):
    return imm_ms < 10_000 and has_tree and cancelled
need(not case2(11_000, False, False), 'case2: return beyond the bound FAILS (hang risk)')
need(not case2(50, True, False), 'case2: unflagged tree after pre-set cancel FAILS')
need(not case2(50, False, False), 'case2: prompt nil failure REFUSED')
need(case2(50, True, True), 'case2: prompt cancelled-flagged tree PASSES')

# case 3: rescan after cancel is exact, complete and unflagged
def case3(done, error, has_tree, cancelled, nodes):
    return done and error is None and has_tree and not cancelled and nodes == FULL
need(not case3(False, None, True, False, FULL), 'case3: rescan never finished FAILS')
need(not case3(True, 'The scan failed.', False, False, 0), 'case3: rescan error FAILS')
need(not case3(True, None, True, True, 80_000), 'case3: rescan still cancelled/partial FAILS')
need(not case3(True, None, True, False, FULL - 1), 'case3: node count drift FAILS (deterministic fixture)')
need(case3(True, None, True, False, FULL), 'case3: the real happy state PASSES')

print('scan-cancel gate+predicate behavioral tests OK' if ok else 'BEHAVIORAL FAILURES FOUND')
sys.exit(0 if ok else 1)
