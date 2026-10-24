#!/usr/bin/env python3
"""Verdict controls for the in-session wide resize and the wide image gate. Pure Linux logic: NOT native evidence."""
import importlib.util, pathlib, struct, tempfile, sys
s = importlib.util.spec_from_file_location('sr', 'scripts/session-resize.py'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
fails = []
def ck(n, ok):
    print(('ok   ' if ok else 'FAIL ') + n); (ok or fails.append(n))
def rep(**o):
    d = dict(token='T', pid=7, ordinaryWindowCount=1, sheetAttached=False, frameWidth=1280, frameHeight=677, visibleHeight=677); d.update(o); return d
ev = lambda r, **k: m.evaluate(r, k.get('pid', 7), k.get('token', 'T'), 1280, 800)[0]
ck('run 40098663789 geometry (992x665 on visible 677) FAILS', not ev(rep(frameWidth=992, frameHeight=665)))
ck('1280 wide, height limited by the 677 visible frame PASSES', ev(rep()))
ck('1280x800 on a tall screen PASSES', ev(rep(frameHeight=800, visibleHeight=1000)))
ck('1280 wide but short of the visible limit (600 of 677) FAILS: only the measured screen limit is excused', not ev(rep(frameHeight=600)))
ck('width short by 10 on a tall screen FAILS', not ev(rep(frameWidth=1270, frameHeight=800, visibleHeight=1000)))
ck('missing report FAILS', not ev(None))
ck('wrong pid FAILS (same-PID binding)', not ev(rep(pid=8)))
ck('token not echoed FAILS', not ev(rep(token='OLD')))
ck('two ordinary windows FAIL', not ev(rep(ordinaryWindowCount=2)))
ck('attached sheet FAILS', not ev(rep(sheetAttached=True)))
ck('report without geometry FAILS', not ev({'token': 'T', 'pid': 7, 'ordinaryWindowCount': 1, 'sheetAttached': False}))
def png(w):
    t = pathlib.Path(tempfile.mkdtemp()) / 'a.png'; t.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', w, 677)); return t
ck('1280px image of a 1280 window PASSES', m.judge_png(m.png_width(png(1280)), 1280)[0])
ck('2560px (2x) image of a 1280 window PASSES', m.judge_png(m.png_width(png(2560)), 1280)[0])
ck('992px clipped image of a 1280 window FAILS', not m.judge_png(m.png_width(png(992)), 1280)[0])
ck('non-PNG FAILS', not m.judge_png(None, 1280)[0])
import zlib
def mkpng(w, blank, h=12):
    c = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    rows = b''.join(b'\x00' + b''.join(bytes((9, 9, 9)) if blank else bytes(((x * 3) % 256, (y * 9) % 256, (x + y) % 256)) for x in range(w)) for y in range(h))
    t = pathlib.Path(tempfile.mkdtemp()) / 'c.png'
    t.write_bytes(b'\x89PNG\r\n\x1a\n' + c(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + c(b'IDAT', zlib.compress(rows)) + c(b'IEND', b'')); return t
ck('rendered right strip (varied pixels) PASSES the content proof', m.judge_content(mkpng(1280, False))[0])
ck('blank right strip FAILS the content proof (unrendered off-display area)', not m.judge_content(mkpng(1280, True))[0])
ck('same windows before and after capture PASS', m.judge_same_windows('11 0 1 1 1 1\n12 3 1 1 1 1', '12 3 1 1 1 1\n11 0 1 1 1 1', 11, 12)[0])
ck('popover window gone after capture FAILS the binding', not m.judge_same_windows('11 0 1 1 1 1\n12 3 1 1 1 1', '11 0 1 1 1 1', 11, 12)[0])
ck('windowserver bounds 1280 for the main window PASS', m.judge_bounds('11 0 32 42 1280 677', 11, 1280)[0])
ck('windowserver bounds 992 FAIL against the requested 1280', not m.judge_bounds('11 0 32 42 992 677', 11, 1280)[0])
ck('main window missing from windowserver list FAILS', not m.judge_bounds('12 0 1 1 1280 600', 11, 1280)[0])
src = pathlib.Path('Sources/Spacelyzer/SessionSizeRequest.swift').read_text()
ck('app responder is CI-only, env-gated, reports pid+token+frame, uses the app sizing path', src.startswith('#if SPZ_CI_TESTS') and 'SPZ_SIZE_REQUESTS' in src and 'setContentSizeExact' in src and '"token"' in src and '"pid"' in src)
ck('responder started from the app only under SPZ_CI_TESTS and requested only by the cleanup session', 'SessionSizeRequest.start' in pathlib.Path('Sources/Spacelyzer/SpacelyzerApp.swift').read_text() and pathlib.Path('scripts/v1-capture-phase.sh').read_text().count('SPZ_SIZE_REQUESTS=1') == 1)
print('%d failed' % len(fails)); sys.exit(1 if fails else 0)
