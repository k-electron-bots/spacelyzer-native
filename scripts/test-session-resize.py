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
# --- two-position on-display judging (alpha-based, bounds-derived; Linux logic only) ---
def mkrgba(w, x0, x1, h=12, mode='ok'):
    """RGBA png: columns [x0,x1) rendered with varied opaque pixels, the rest alpha=0 (what run 40201792105 showed)."""
    c = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    px = lambda x, y: bytes(((x * 3) % 256, (y * 9) % 256, (x + y) % 256, 255)) if x0 <= x < x1 else bytes((7, 7, 7, 0))
    rows = b''.join(b'\x00' + b''.join(px(x, y) for x in range(w)) for y in range(h))
    t = pathlib.Path(tempfile.mkdtemp()) / 'a.png'
    t.write_bytes(b'\x89PNG\r\n\x1a\n' + c(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + c(b'IDAT', zlib.compress(rows)) + c(b'IEND', b'')); return t
GEO = 'screen index=0 frame=(0.0, 0.0, 1024.0, 768.0) visibleFrame=(0.0, 60.0, 1024.0, 677.0) scale=1.0\n'
WA, WB = '195 0 32 31 1280 677\n207 0 309 173 406 110\n', '195 0 -256 31 1280 677\n207 0 21 173 406 110\n'
ck('display range of display 0 comes from the helper geometry line', m.display_x_range(GEO) == (0.0, 1024.0))
ck('position A on-display range is exactly 0..992 (1024 minus origin 32)', m.on_display_range(WA, 195, GEO) == (0, 992, 1280))
ck('position B on-display range is exactly 256..1280', m.on_display_range(WB, 195, GEO) == (256, 1280, 1280))
ck('capture A rendered exactly over 0..992 PASSES', m.judge_range(mkrgba(1280, 0, 992), WA, 195, GEO)[0])
ck('capture A with the on-display part unrendered FAILS (alpha=0 counts as not rendered)', not m.judge_range(mkrgba(1280, 0, 700), WA, 195, GEO)[0])
ck('capture B rendered over 256..1280 PASSES', m.judge_range(mkrgba(1280, 256, 1280), WB, 195, GEO)[0])
ck('MUTATION: capture B equal to capture A (move did not render the right part) FAILS', not m.judge_range(mkrgba(1280, 0, 992), WB, 195, GEO)[0])
ck('2x capture scales the on-display columns', m.judge_range(mkrgba(2560, 0, 1984), WA, 195, GEO)[0])
ck('union of A and B covers the width', m.judge_coverage(WA, WB, 195, GEO)[0])
ck('MUTATION: a move that only reaches x=0 leaves columns 1024..1280 uncovered and FAILS coverage', not m.judge_coverage(WA, '195 0 0 31 1280 677\n', 195, GEO)[0])
ck('window fully off-display has no range and FAILS', not m.judge_range(mkrgba(1280, 0, 1280), '195 0 -2000 31 1280 677\n', 195, GEO)[0])
ck('shift pin: main and popover both moved by -288 PASS', m.judge_shifted(WA, WB, 195, 207, -288)[0])
ck('MUTATION: popover did not follow the window FAILS', not m.judge_shifted(WA, '195 0 -256 31 1280 677\n207 0 309 173 406 110\n', 195, 207, -288)[0])
ck('MUTATION: popover gone after the move FAILS', not m.judge_shifted(WA, '195 0 -256 31 1280 677\n', 195, 207, -288)[0])
ck('achieved origin differing from the plan FAILS the origin gate', not m.judge_bounds_x('195 0 -200 31 1280 677\n', 195, -256)[0] and m.judge_bounds_x(WB, 195, -256)[0])
ck('popover colours gate rejects an all-transparent capture', not m.judge_colours(mkrgba(406, 0, 0))[0] and m.judge_colours(mkrgba(406, 0, 406))[0])
def mkflat(w, x0, x1, fx, fl=0):
    """opaque everywhere in [x0,x1); columns >= fx are ONE opaque flat colour, the rest varied."""
    c = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    px = lambda x, y: (bytes((50, 50, 50, 255)) if fl <= x and x >= fx else bytes(((x * 3) % 256, (y * 9) % 256, (x + y) % 256, 255))) if x0 <= x < x1 else bytes((7, 7, 7, 0))
    rows = b''.join(b'\x00' + b''.join(px(x, y) for x in range(w)) for y in range(12))
    t = pathlib.Path(tempfile.mkdtemp()) / 'f.png'
    t.write_bytes(b'\x89PNG\r\n\x1a\n' + c(b'IHDR', struct.pack('>IIBBBBB', w, 12, 8, 6, 0, 0, 0)) + c(b'IDAT', zlib.compress(rows)) + c(b'IEND', b'')); return t
def mkflat2(w, x0, x1, fend):
    c = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    px = lambda x, y: (bytes((50, 50, 50, 255)) if x < fend else bytes(((x * 3) % 256, (y * 9) % 256, (x + y) % 256, 255))) if x0 <= x < x1 else bytes((7, 7, 7, 0))
    rows = b''.join(b'\x00' + b''.join(px(x, y) for x in range(w)) for y in range(12))
    t = pathlib.Path(tempfile.mkdtemp()) / 'g.png'
    t.write_bytes(b'\x89PNG\r\n\x1a\n' + c(b'IHDR', struct.pack('>IIBBBBB', w, 12, 8, 6, 0, 0, 0)) + c(b'IDAT', zlib.compress(rows)) + c(b'IEND', b'')); return t
ck('B with real content over its exclusive 992..1280 PASSES the exclusive-range proof', m.judge_range(mkrgba(1280, 256, 1280), WB, 195, GEO, other_windows_text=WA)[0])
ck('MUTATION: B opaque and FLAT over 992..1280 (colours only from columns A covers) FAILS even though 8+ colours exist overall', not m.judge_range(mkflat(1280, 256, 1280, 992), WB, 195, GEO, other_windows_text=WA)[0] and m.judge_range(mkflat(1280, 256, 1280, 992), WB, 195, GEO)[0])
ck('A with real content over its exclusive 0..256 PASSES', m.judge_range(mkrgba(1280, 0, 992), WA, 195, GEO, other_windows_text=WB)[0])
ck('MUTATION: A flat opaque over 0..256 only (rest varied) FAILS the exclusive proof', not m.judge_range(mkflat2(1280, 0, 992, 256), WA, 195, GEO, other_windows_text=WB)[0] and m.judge_range(mkflat2(1280, 0, 992, 256), WA, 195, GEO)[0])
ck('identical positions leave no exclusive columns, so the second capture has no purpose and FAILS', not m.judge_range(mkrgba(1280, 0, 992), WA, 195, GEO, other_windows_text=WA)[0])
ck('restore: window back at its start with popover present PASSES', m.judge_restored(WA, WA, 195, 207)[0])
ck('MUTATION: window left displaced FAILS the restore check', not m.judge_restored(WA, WB, 195, 207)[0])
ck('MUTATION: restored but popover gone FAILS', not m.judge_restored(WA, '195 0 32 31 1280 677\n', 195, 207)[0])
src = pathlib.Path('Sources/Spacelyzer/SessionSizeRequest.swift').read_text()
ck('app responder is CI-only, env-gated, reports pid+token+frame, uses the app sizing path', src.startswith('#if SPZ_CI_TESTS') and 'SPZ_SIZE_REQUESTS' in src and 'setContentSizeExact' in src and '"token"' in src and '"pid"' in src)
ck('responder started from the app only under SPZ_CI_TESTS and requested only by the cleanup session', 'SessionSizeRequest.start' in pathlib.Path('Sources/Spacelyzer/SpacelyzerApp.swift').read_text() and pathlib.Path('scripts/v1-capture-phase.sh').read_text().count('SPZ_SIZE_REQUESTS=1') == 1)
print('%d failed' % len(fails)); sys.exit(1 if fails else 0)
