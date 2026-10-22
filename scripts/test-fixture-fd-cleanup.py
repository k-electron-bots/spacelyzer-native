#!/usr/bin/env python3
"""Regression: when opening a SECOND parent directory fails, generate() must surface that original error. Before the fix the
already-closed first descriptor was closed again in the cleanup, and the EBADF masked the real cause. Linux, not Mac evidence."""
import importlib.util, os, sys, tempfile, errno
f = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make_fixtures.py')
spec = importlib.util.spec_from_file_location('fx', f); fx = importlib.util.module_from_spec(spec); spec.loader.exec_module(fx)
real_open = os.open; n = {'dirs': 0}
def flaky(path, flags, *a, **k):
    if flags & os.O_DIRECTORY:
        n['dirs'] += 1
        if n['dirs'] == 2: raise OSError(errno.EMFILE, 'injected: too many open files')
    return real_open(path, flags, *a, **k)
os.open = flaky
with tempfile.TemporaryDirectory() as td:
    try: fx.generate(os.path.join(td, 'fx'), 'expansion-10k')
    except OSError as e:
        ok = e.errno == errno.EMFILE
        print(('PASS' if ok else 'FAIL') + ' original open error surfaces, got errno=%s (%s)' % (e.errno, e)); sys.exit(0 if ok else 1)
    print('FAIL no exception'); sys.exit(1)
