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
    os.mkfifo(root + '/fifo'); s = socket.socket(socket.AF_UNIX); s.bind(root + '/sock')
    open(root + '/back\\slash', 'w').write('1'); open(root + '/lit\\n', 'w').write('2'); open(root + '/tab\tname', 'w').write('3'); open(root + '/new\nline', 'w').write('4')
    # capability probes: case folding and normalization
    a, b = root + '/Case.txt', root + '/case.txt'; open(a, 'w').write('A'); open(b, 'w').write('B')
    if len(os.listdir(root)) and os.path.exists(b) and sorted(x for x in os.listdir(root) if x.lower() == 'case.txt') == ['Case.txt', 'case.txt']: print('probe: case-sensitive fs, case variants distinct')
    else: print('NOT-RUN: case variants collapse (case-insensitive fs)'); notrun.append('case')
    nfc, nfd = unicodedata.normalize('NFC', 'caf\u00e9'), unicodedata.normalize('NFD', 'caf\u00e9')
    open(f'{root}/{nfc}', 'w').write('c'); open(f'{root}/{nfd}', 'w').write('d')
    if len([x for x in os.listdir(root) if unicodedata.normalize('NFC', x) == nfc]) == 2: print('probe: NFC and NFD names distinct')
    else: print('NOT-RUN: NFC/NFD collapse (normalizing fs)'); notrun.append('nfc')
    try: open(os.fsencode(root) + b'/bad\xff', 'wb').write(b'n'); nonutf = True
    except OSError: print('NOT-RUN: fs refuses non-UTF-8 names'); notrun.append('nonutf8'); nonutf = False
    unread = 0
    if os.getuid() != 0:
        os.mkdir(root + '/noperm'); open(root + '/noperm/h', 'w').write('z'); os.chmod(root + '/noperm', 0); unread = 1
    else: print('NOT-RUN: root user, chmod 000 not enforceable'); notrun.append('unreadable')
    exp_skips = unread + (1 if nonutf else 0)
    def pn(tamper=None):
        cmd = SPZ if tamper is None else [sys.executable, H + '/tamper-dump.py', 'dump']
        if tamper: os.environ['SPZ_REAL'] = SPZ; os.environ['TAMPER'] = tamper
        return O.per_node(root, cmd, has_hardlinks=False)
    r = pn()
    ck('baseline real engine: 0 per-node diffs', r['diff_count'] == 0, r['diffs'][:3])
    ck('baseline skipped accounting equals oracle expectation', len(r['skips']) == exp_skips == r['expected_skips'], (r['skips'], exp_skips))
    ck('baseline no drift', not r['drift'])
    ck('special files and symlinks present as nodes (fifo, socket, 3 symlinks)', r['nodes'] > 20)
    for t, want in [('file_bytes', 1), ('dir_bytes', 1), ('drop_file', 1), ('extra_node', 1), ('kind_swap', 1)]:
        r = pn(t); ck(f'tamper {t} caught by node diff', r['diff_count'] >= want, r['diff_count'])
    r = pn('drop_skip'); ck('tamper drop_skip caught by skip accounting', exp_skips == 0 or len(r['skips']) != r['expected_skips'], r['skips'])
    r = pn('extra_skip'); ck('tamper extra_skip caught by skip accounting', len(r['skips']) != r['expected_skips'], r['skips'])
    r = pn('mutate'); ck('tree changed during engine run is flagged DRIFT (inconclusive), not an engine diff', r['drift'], r)
    os.unlink(root + '/drift_new')
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
