#!/usr/bin/env python3
"""Controls for the independent oracle (Linux/macOS, needs a built spz via SPZ_BIN or target/release/spz). Real special cases and ONE isolated tamper per case on a
NO-hard-link tree, so each control can only fail for its own reason. Filesystem capabilities are probed, and any case the filesystem cannot represent prints
NOT-RUN (never green, never aborts)."""
import importlib.util, os, shutil, socket, stat, subprocess, sys, tempfile, unicodedata
H = os.path.dirname(os.path.abspath(__file__)); SPZ = os.environ.get('SPZ_BIN', os.path.join(H, '..', 'target', 'release', 'spz'))
spec = importlib.util.spec_from_file_location('o', H + '/independent-size-oracle.py'); O = importlib.util.module_from_spec(spec); spec.loader.exec_module(O)
fails = []; notrun = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + str(d))); (ok or fails.append(n))
root = os.path.realpath(tempfile.mkdtemp(prefix='acctl-'))
try:
    os.makedirs(root + '/a/b/c'); os.makedirs(root + '/empty')
    for i, sz in enumerate([0, 1, 4096, 4097, 70000]): open(f'{root}/a/b/f{i}', 'wb').write(b'x' * sz)
    open(root + '/a/b/c/deep', 'wb').write(b'y' * 9000)
    with open(root + '/a/sparse', 'wb') as f: f.truncate(1 << 30)
    os.symlink('missing', root + '/dangling'); os.symlink('..', root + '/loop'); os.symlink(root + '/a', root + '/abs')
    os.mkfifo(root + '/fifo')
    try: s = socket.socket(socket.AF_UNIX); s.bind(root + '/sock')
    except OSError as e: print(f'NOT-RUN: unix socket bind failed ({e}); path too long or unsupported'); notrun.append('socket')
    open(root + '/back\\slash', 'w').write('1'); open(root + '/lit\\n', 'w').write('2'); open(root + '/tab\tname', 'w').write('3'); open(root + '/new\nline', 'w').write('4')
    # capability probes: case folding and normalization
    a, b = root + '/Case.txt', root + '/case.txt'; open(a, 'w').write('A'); open(b, 'w').write('B')
    if len(os.listdir(root)) and os.path.exists(b) and sorted(x for x in os.listdir(root) if x.lower() == 'case.txt') == ['Case.txt', 'case.txt']: print('probe: case-sensitive fs, case variants distinct')
    else: print('NOT-RUN: case variants collapse (case-insensitive fs)'); notrun.append('case')
    nfc, nfd = unicodedata.normalize('NFC', 'caf\u00e9'), unicodedata.normalize('NFD', 'caf\u00e9')
    open(f'{root}/{nfc}', 'w').write('c'); open(f'{root}/{nfd}', 'w').write('d')
    if len([x for x in os.listdir(root) if unicodedata.normalize('NFC', x) == nfc]) == 2: print('probe: NFC and NFD names distinct')
    else: print('NOT-RUN: NFC/NFD collapse (normalizing fs)'); notrun.append('nfc')
    nonutf = True
    try:
        for nm in (b'bad\xff', b'bad\xfe', b'bad\xff\xff'): open(os.fsencode(root) + b'/' + nm, 'wb').write(b'n')
    except OSError as e: print(f'NOT-RUN: fs refuses non-UTF-8 names (errno {e.errno}, {os.strerror(e.errno)}; macOS APFS gives EILSEQ 92) - the lossy-SKIP cases below did not execute'); notrun.append('nonutf8'); nonutf = False
    unread = 0
    if os.getuid() != 0:
        os.mkdir(root + '/noperm'); open(root + '/noperm/h', 'w').write('z'); os.chmod(root + '/noperm', 0); unread = 1
    else: print('NOT-RUN: root user, chmod 000 not enforceable'); notrun.append('unreadable')
    exp_skips = unread + (3 if nonutf else 0)
    def pn(tamper=None, backend='default', deadline=None):
        cmd = SPZ if tamper is None else [sys.executable, H + '/tamper-dump.py', 'dump']
        if tamper: os.environ['SPZ_REAL'] = SPZ; os.environ['TAMPER'] = tamper
        return O.per_node(root, cmd, has_hardlinks=False, backend=backend, deadline=deadline)
    r = pn()
    ck('baseline real engine: 0 per-node diffs', r['diff_count'] == 0, r['diffs'][:3])
    ck('baseline skipped accounting equals oracle expectation', len(r['skips']) == exp_skips == r['expected_skips'], (r['skips'], exp_skips))
    ck('baseline no drift', not r['drift'])
    ck('special files and symlinks present as nodes (fifo, socket, 3 symlinks)', r['nodes'] > 20)
    for t, want in [('file_bytes', 1), ('dir_bytes', 1), ('drop_file', 1), ('extra_node', 1), ('kind_swap', 1)]:
        r = pn(t); ck(f'tamper {t} caught by node diff', r['diff_count'] >= want, r['diff_count'])
    r = pn('drop_skip'); ck('tamper drop_skip caught by skip accounting', exp_skips == 0 or len(r['skips']) != r['expected_skips'], r['skips'])
    if nonutf:
        r = pn(); ck('three distinct invalid names stay THREE skips (not collapsed) and ambiguity is declared', len([p for _, p in r['skips'] if '\ufffd' in p]) == 3 and r['lossy_ambiguous'] is True, r['skips'])
        r = pn('drop_one_skip'); ck('dropping ONE lossy skip is caught (multiset)', r['diff_count'] >= 1 and any(d[0] == 'lossy_skip_multiset' for d in r['diffs']), r['diffs'])
    r = pn('need_portable', 'portable'); ck('portable leg: the backend flag reaches the engine through the list-form wrapper', not any(d[0] == 'dump_exit' for d in r['diffs']) and r['backend'] == 'portable', r['diffs'])
    r = pn('need_portable', 'default'); ck('default leg does NOT carry the portable flag (control is not vacuous)', any(d[0] == 'dump_exit' for d in r['diffs']), r['diffs'])
    r = subprocess.run([SPZ, 'dump', root, 'bogus'], capture_output=True, text=True); ck('invalid backend arg is refused by spz (exit 2), not silently the default', r.returncode == 2 and not r.stdout, (r.returncode, r.stdout[:50]))
    os.environ['SPZ_GHOSTS'] = '6000'; r = pn('ghosts'); del os.environ['SPZ_GHOSTS']
    ck('6000 diffs: cap and truncation are explicit (total 6000 or more, kept 5000, dropped counted, leaf stats capped at 50 with dropped count)', r['diffs_total'] >= 6000 and r['diffs_kept'] == 5000 and r['diffs_dropped'] == r['diffs_total'] - 5000 and len(r['all_diffs']) == 5000 and r['leaf_stat_cap'] == 50 and r['leaf_stat_kept'] <= 50 and r['leaf_stat_kept'] + r['leaf_stat_missing_path'] + r['leaf_stat_dropped_by_cap'] <= r['leaf_stat_candidates'] and r['leaf_stat_dropped_by_cap'] > 0, {k: r[k] for k in r if k.startswith(('diffs_', 'leaf_stat_'))})
    r = pn('dup_path'); ck('duplicate path in dump is a diff, not a silent overwrite', any(d[0] == 'dump_duplicate_path' for d in r['diffs']), r['diffs'])
    import time
    t = time.monotonic()
    try: pn('sleep', deadline=time.monotonic() + 2); ck('sleeping dump under a 2s absolute deadline times out', False, 'returned')
    except subprocess.TimeoutExpired: ck('sleeping dump under a 2s absolute deadline times out (process group killed)', time.monotonic() - t < 6, time.monotonic() - t)
    t = time.monotonic()
    try: pn('sleep', deadline=time.monotonic() - 5); ck('expired deadline: pre-walk cap/timeout, sleeping dump not run for 30s', False, 'returned')
    except (O.Capped, subprocess.TimeoutExpired): ck('expired deadline stops the work immediately (cap or 1s floor timeout), not a fresh budget', time.monotonic() - t < 6, time.monotonic() - t)
    # post-run walk hits the cap: per_node must RAISE Capped (INCOMPLETE upstream), never report DRIFT or a pass
    real_walk, calls = O.walk, [0]
    def walk2(*a, **k):
        calls[0] += 1
        if calls[0] == 2: raise O.Capped('time')
        return real_walk(*a, **k)
    O.walk = walk2
    try: pn(); ck('post-walk cap raises Capped (INCOMPLETE), not mislabeled DRIFT', False, 'returned')
    except O.Capped: ck('post-walk cap raises Capped (INCOMPLETE), not mislabeled DRIFT', True)
    finally: O.walk = real_walk
    r = pn('reason_swap'); ck('tamper skip REASON (right path, wrong reason) is caught', r['diff_count'] >= 1 and any(d[0] == 'skip_reason_or_path' for d in r['diffs']), r['diffs'])
    r = pn('dump_fail'); ck('nonzero dump exit is a diff (fail closed)', any(d[0] == 'dump_exit' for d in r['diffs']), r['diffs'])
    r = pn('extra_skip'); ck('tamper extra_skip caught by skip accounting', len(r['skips']) != r['expected_skips'], r['skips'])
    r = pn('mutate'); ck('tree changed during engine run is flagged DRIFT (inconclusive), not an engine diff', r['drift'], r)
    os.unlink(root + '/drift_new')
    # totals gate: a fake spz that mutates the tree while running must give DRIFT (rc 4), a faithful run AGREE (0), a wrong total DISAGREE (1), a tiny cap INCOMPLETE (3)
    def totals(fake_body, *extra):
        f = tempfile.mktemp(suffix='.sh'); open(f, 'w').write('#!/bin/sh\n' + fake_body); os.chmod(f, 0o755)
        r = subprocess.run([sys.executable, H + '/independent-size-oracle.py', root, '--spz', f, *extra], capture_output=True, text=True); os.unlink(f); return r.returncode
    ck('totals AGREE rc0 on the real engine', subprocess.run([sys.executable, H + '/independent-size-oracle.py', root, '--spz', SPZ], capture_output=True).returncode == 0)
    ck('totals DRIFT rc4 when the tree changes during the engine run', totals(f'echo late > "{root}/drift2"; exec "{SPZ}" verify-cold "$2"') == 4); os.unlink(root + '/drift2')
    ck('totals DISAGREE rc1 on a wrong engine total', totals('echo "default : 1 items 1 bytes in 0.0s (cold only)"') == 1)
    ck('totals INCOMPLETE rc3 under an item cap, nothing claimed', totals('exit 0', '--max-items', '3') == 3)
    # dump faithfulness: backslash, literal \n, tab, newline names come back as exactly the oracle's paths (diff_count 0 above already proves it); invalid UTF-8 is listed, not in tree
    if nonutf:
        d = subprocess.run([SPZ, 'dump', root], capture_output=True, text=True).stdout
        ck('invalid-UTF-8 name is a SKIP line (lossy) and not a node', any(l.startswith('SKIP') and '\ufffd' in l for l in d.splitlines()) and not any(l.startswith('File') and '\ufffd' in l for l in d.splitlines()), d[-300:])
finally:
    if os.getuid() != 0:
        try: os.chmod(root + '/noperm', 0o700)
        except OSError: pass
    shutil.rmtree(root, ignore_errors=True)
print('NOT-RUN cases:', notrun or 'none'); sys.exit(1 if fails else 0)
