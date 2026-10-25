#!/usr/bin/env python3
"""Ask the RUNNING app (same PID, same session) to size its own main window, then judge the app's own
report of the geometry it actually got. CI-only; the test build polls /tmp/spz-size-request-<pid>.

Why not AX setAXSize: run 40098663789 asked 1280x800 and the window stayed 992x665 on a 1024x768
runner (visibleFrame 1024x677). The app-driven path is the one that already produced 1280-wide windows
on that same display (SPZ_WINDOW_SIZE launches recorded rect 32,31,1280,677).

Gate (review required, see docs/development/capture-failure-diagnostics.md):
  width  : frame width must equal the requested width +-2. No screen clamp is excused for width.
  height : frame height must equal min(requested height, screen visibleFrame height) +-2. The OS cannot
           place a window taller than the visible frame, so the only excused height shortfall is the
           measured screen limit; any other shortfall fails.
The report must come from the same PID, echo this request's token, and show one ordinary window."""
import json, os, pathlib, sys, time, uuid

TOL = 2.0

def evaluate(result, pid, token, req_w, req_h):
    """Return (ok, lines). Pure so Linux tests can exercise every verdict."""
    lines = []
    def bad(msg):
        lines.append('resize FAIL ' + msg); return False, lines
    if result is None: return bad('no app report before the deadline')
    if result.get('pid') != pid: return bad('report pid %r != target pid %r' % (result.get('pid'), pid))
    if result.get('token') != token: return bad('report token does not echo this request')
    if result.get('ordinaryWindowCount') != 1: return bad('ordinaryWindowCount=%r, need 1' % result.get('ordinaryWindowCount'))
    if result.get('sheetAttached'): return bad('a sheet is attached; the main window must be unobstructed')
    try:
        fw, fh = float(result['frameWidth']), float(result['frameHeight']); vis = float(result['visibleHeight'])
    except (KeyError, TypeError, ValueError): return bad('report lacks frame/visible geometry')
    exp_h = min(float(req_h), vis)
    lines.append('resize requested=%sx%s frame=%sx%s visibleHeight=%s expectedHeight=%s heightLimitedByScreen=%s'
                 % (req_w, req_h, fw, fh, vis, exp_h, exp_h < float(req_h)))
    if abs(fw - float(req_w)) > TOL: return bad('width %s != requested %s (+-%s); not genuinely wide' % (fw, req_w, TOL))
    atts = result.get('attempts')
    if isinstance(atts, list) and atts:
        lines.append('resize attempts=%s' % ','.join(str(a.get('name')) for a in atts if isinstance(a, dict)))
        if result.get('lateSettleDelta') not in (None, 0, 0.0): lines.append('resize lateSettleDelta=%s' % result.get('lateSettleDelta'))
    if abs(fh - exp_h) > TOL: return bad('height %s != min(requested %s, visible %s) = %s' % (fh, req_h, vis, exp_h))
    lines.append('resized %dx%d' % (round(fw), round(fh)))
    return True, lines

def main(argv):
    pid, req_w, req_h = int(argv[1]), int(argv[2]), int(argv[3])
    base = pathlib.Path(os.environ.get('SPZ_SIZE_DIR', '/tmp'))
    req, res = base / ('spz-size-request-%d' % pid), base / ('spz-size-result-%d' % pid)
    res.unlink(missing_ok=True)
    token = str(uuid.uuid4()).upper()
    tmp = req.with_suffix('.tmp'); tmp.write_text('%s %dx%d\n' % (token, req_w, req_h)); tmp.replace(req)
    result, deadline = None, time.monotonic() + float(os.environ.get('SPZ_SIZE_WAIT', '5'))
    while time.monotonic() < deadline:
        try:
            data = json.loads(res.read_text())
            if data.get('token') == token: result = data; break
        except (OSError, ValueError): pass
        time.sleep(0.05)
    req.unlink(missing_ok=True)
    print('resize targetPID=%d requested=%dx%d via=app-in-session' % (pid, req_w, req_h))
    if result is not None: print('resize report ' + json.dumps(result, sort_keys=True))
    ok, lines = evaluate(result, pid, token, req_w, req_h)
    print('\n'.join(lines))
    if not ok: print('resize dimensions not observed')
    return 0 if ok else 1

def png_width(path):
    d = open(path, 'rb').read(24)
    if d[:8] != b'\x89PNG\r\n\x1a\n': return None
    return int.from_bytes(d[16:20], 'big')

def judge_png(width_px, frame_w):
    """The image must show the whole window: pixel width equals the window frame width at 1x or 2x (+-2)."""
    if width_px is None: return False, 'png width unreadable'
    ok = any(abs(width_px - frame_w * k) <= TOL for k in (1, 2))  # frame_w is the REQUESTED width, never a measured one
    return ok, 'png width %s vs requested width %s (1x or 2x +-%s): %s' % (width_px, frame_w, TOL, 'OK' if ok else 'CLIPPED/WRONG')

def png_pixels(path):
    """Decode an 8-bit non-interlaced RGB/RGBA PNG to (w, h, rows of pixel bytes). None if unsupported."""
    import zlib
    b = open(path, 'rb').read()
    if b[:8] != b'\x89PNG\r\n\x1a\n': return None
    pos, idat, hdr = 8, b'', None
    while pos + 8 <= len(b):
        n = int.from_bytes(b[pos:pos+4], 'big'); typ = b[pos+4:pos+8]; body = b[pos+8:pos+8+n]; pos += 12 + n
        if typ == b'IHDR': hdr = body
        elif typ == b'IDAT': idat += body
    if not hdr: return None
    w, h, depth, ctype, _, _, inter = int.from_bytes(hdr[0:4], 'big'), int.from_bytes(hdr[4:8], 'big'), hdr[8], hdr[9], hdr[10], hdr[11], hdr[12]
    if depth != 8 or inter != 0 or ctype not in (2, 6): return None
    bpp = 3 if ctype == 2 else 4; stride = w * bpp
    raw = zlib.decompress(idat); rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; up = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + up) & 255
            elif f == 3: line[x] = (line[x] + (a + up) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(up - c), abs(a - c), abs(a + up - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, rows, bpp

def judge_content(path, strip=200, need=8, side='right'):
    """Rendered-content proof for a genuinely wide image: the `strip` pixel columns on the given side must hold real
    rendering, not blank fill: at least `need` distinct colours. Run 40201792105: with the window origin at x=32 on a
    1024pt display the right edge came back flat, so each capture position is judged on the edge that is on the display
    at that position (position 1: left edge; shifted position: right edge)."""
    d = png_pixels(path)
    if d is None: return False, 'png not decodable (need 8-bit RGB/RGBA)'
    w, h, rows, bpp = d; x0, x1 = (max(0, w - strip), w) if side == 'right' else (0, min(w, strip)); colours = set()
    for r in rows: colours.update(bytes(r[x*bpp:x*bpp+3]) for x in range(x0, x1) if bpp == 3 or r[x*bpp+3] > 0)  # alpha=0 is not rendered
    ok = len(colours) >= need
    return ok, 'SMOKE check only, native pixel review remains the gate: %s-most %d columns of %dx%d image hold %d distinct colours (need >= %d): %s' % (side, x1 - x0, w, h, len(colours), need, 'OK' if ok else 'BLANK/UNRENDERED')

def display_x_range(geometry_text):
    """x extent of display 0 from the helper's own `geometry` output (NSScreen frame)."""
    import re
    for l in geometry_text.splitlines():
        m = re.match(r'screen index=0 frame=\(([-\d.]+), ([-\d.]+), ([\d.]+), ([\d.]+)\)', l)
        if m: return float(m[1]), float(m[1]) + float(m[3])
    return None

def on_display_range(windows_text, main_id, geometry_text):
    """Window-relative point range [lo, hi) of the main window that lies on display 0, from WindowServer bounds
    intersected with the display (never a fixed strip)."""
    r = _rows(windows_text).get(main_id); dr = display_x_range(geometry_text)
    if r is None or dr is None: return None
    x, w = r[1], r[3]
    lo, hi = max(x, dr[0]) - x, min(x + w, dr[1]) - x
    return (lo, hi, w) if hi > lo else None

def judge_range(path, windows_text, main_id, geometry_text, need=8, other_windows_text=None):
    """Capture proof for ONE position: every pixel column inside the on-display range must be rendered (alpha > 0)
    and the range must hold real content (>= need distinct opaque colours). With the OTHER position's window list the
    columns this capture alone is responsible for (its range minus the other capture's range) must ALSO hold >= need
    distinct opaque colours, so a flat opaque fill over those columns cannot hide behind colours the other capture
    already covers. Columns outside the range are not asked for. Run 40201792105: columns past the display edge were alpha=0."""
    rg = on_display_range(windows_text, main_id, geometry_text)
    if rg is None: return False, 'no on-display range (window or display bounds unreadable / window fully off-display)'
    d = png_pixels(path)
    if d is None: return False, 'png not decodable (need 8-bit RGB/RGBA)'
    lo, hi, w = rg; pw, ph, rows, bpp = d; k = pw / w
    c0, c1 = int(round(lo * k)), int(round(hi * k)); empty = []; colours = set(); excl = set(); excl_cols = 0
    ex = None
    if other_windows_text is not None:
        og = on_display_range(other_windows_text, main_id, geometry_text)
        if og is None: return False, 'other position has no on-display range'
        ex = [(max(lo, a), min(hi, b)) for a, b in ((lo, min(hi, og[0])), (max(lo, og[1]), hi)) if min(hi, b) > max(lo, a)]
        ex = [(int(round(a * k)), int(round(b * k))) for a, b in ex]
    for x in range(c0, c1):
        seen = False; mine = ex is not None and any(a <= x < b for a, b in ex)
        if mine: excl_cols += 1
        for r in rows:
            if bpp == 3 or r[x*bpp+3] > 0:
                seen = True; cl = bytes(r[x*bpp:x*bpp+3]); colours.add(cl)
                if mine: excl.add(cl)
        if not seen: empty.append(x)
    ok = not empty and len(colours) >= need
    msg = 'on-display window range %g..%g pt = columns %d..%d of %d: %d columns with no rendered (alpha>0) pixel%s, %d distinct opaque colours (need >= %d)' % (lo, hi, c0, c1, pw, len(empty), (' (first %d)' % empty[0]) if empty else '', len(colours), need)
    if ex is not None:
        ok2 = excl_cols > 0 and len(excl) >= need; ok = ok and ok2
        msg += '; exclusive columns %s (%d cols) hold %d distinct opaque colours (need >= %d): %s' % (ex, excl_cols, len(excl), need, 'OK' if ok2 else 'NOT RENDERED')
    return ok, msg + ': %s' % ('OK' if ok else 'NOT RENDERED')

def judge_restored(before, after, main_id, pop_id):
    """After move-back the main window must be where it started (x, y, size, +-TOL) and the popover still present."""
    b, a = _rows(before).get(main_id), _rows(after).get(main_id)
    if b is None or a is None: return False, 'main window %s missing before or after the restore' % main_id
    ok = all(abs(a[i] - b[i]) <= TOL for i in (1, 2, 3, 4)) and pop_id in _rows(after)
    return ok, 'restored main window %s vs original %s (x,y,w,h +-%s), popover %s present: %s' % (a[1:], b[1:], TOL, pop_id in _rows(after), 'OK' if ok else 'NOT RESTORED')

def judge_coverage(windows_a, windows_b, main_id, geometry_text):
    """Two on-display captures together must cover the whole window width [0, w). Never stitched: this is a statement
    about two separate files, not a full-width image."""
    a, b = on_display_range(windows_a, main_id, geometry_text), on_display_range(windows_b, main_id, geometry_text)
    if a is None or b is None: return False, 'a position has no on-display range'
    if a[2] != b[2]: return False, 'window width differs between positions: %s vs %s' % (a[2], b[2])
    lo, hi = min(a[0], b[0]), max(a[1], b[1]); gap = a[1] < b[0] or b[1] < a[0]
    ok = lo <= 0 and hi >= a[2] and not gap
    return ok, 'capture A covers %g..%g pt, capture B covers %g..%g pt, union %g..%g of window width %g%s: %s' % (a[0], a[1], b[0], b[1], lo, hi, a[2], ' (GAP)' if gap else '', 'two on-display captures cover the window' if ok else 'COVERAGE INCOMPLETE')

def judge_colours(path, need=8):
    """Whole-image rendered-content proof for a small capture (the popover): at least `need` distinct colours."""
    d = png_pixels(path)
    if d is None: return False, 'png not decodable (need 8-bit RGB/RGBA)'
    w, h, rows, bpp = d; colours = set()
    for r in rows: colours.update(bytes(r[x*bpp:x*bpp+3]) for x in range(w) if bpp == 3 or r[x*bpp+3] > 0)
    ok = len(colours) >= need
    return ok, 'SMOKE check only, native pixel review remains the gate: %dx%d image holds %d distinct colours (need >= %d): %s' % (w, h, len(colours), need, 'OK' if ok else 'BLANK/UNRENDERED')

def _rows(text):
    out = {}
    for l in text.splitlines():
        f = l.split()
        if len(f) == 6: out[int(f[0])] = tuple(int(v) for v in f[1:])
    return out

def judge_shifted(before, after, main_id, pop_id, dx):
    """Window move pin: same main and popover windows, both moved by dx (+-TOL) with unchanged size. The popover must
    follow the window or a popover capture at the new position would show the wrong place."""
    b, a = _rows(before), _rows(after)
    if main_id not in b or pop_id not in b: return False, 'main %s / popover %s not in the window list before the move' % (main_id, pop_id)
    if main_id not in a or pop_id not in a: return False, 'main %s / popover %s not in the window list after the move' % (main_id, pop_id)
    msgs, ok = [], True
    for name, i in (('main', main_id), ('popover', pop_id)):
        moved = a[i][1] - b[i][1]; same = a[i][3] == b[i][3] and a[i][4] == b[i][4] and abs(a[i][2] - b[i][2]) <= TOL
        good = abs(moved - dx) <= TOL and same; ok = ok and good
        msgs.append('%s moved %s (want %s +-%s), size %s: %s' % (name, moved, dx, TOL, 'unchanged' if same else 'CHANGED', 'OK' if good else 'WRONG'))
    return ok, '; '.join(msgs)

def judge_bounds_x(windows_text, main_id, want_x):
    r = _rows(windows_text).get(main_id)
    if r is None: return False, 'main window %s not in windowserver list' % main_id
    ok = abs(r[1] - want_x) <= TOL
    return ok, 'windowserver origin x %s vs wanted %s (+-%s): %s' % (r[1], want_x, TOL, 'OK' if ok else 'NOT AT POSITION')

def judge_bounds(windows_text, main_id, req_w):
    """WindowServer's own bounds for the main window must be the REQUESTED width, independent of the app's report
    and of the image, so no two sources can agree on a narrower frame."""
    for l in windows_text.splitlines():
        f = l.split()
        if len(f) == 6 and int(f[0]) == main_id:
            ok = abs(float(f[4]) - req_w) <= TOL
            return ok, 'windowserver bounds width %s vs requested %s (+-%s): %s' % (f[4], req_w, TOL, 'OK' if ok else 'NOT WIDE')
    return False, 'main window %s not in windowserver list' % main_id

def judge_same_windows(before, after, main_id, pop_id):
    ids = lambda t: {int(l.split()[0]) for l in t.splitlines() if l.strip()}
    a, b = ids(before), ids(after); ok = {main_id, pop_id} <= a and {main_id, pop_id} <= b
    return ok, 'main %s and popover %s present before and after capture: %s' % (main_id, pop_id, ok)

if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--bounds-width':
        ok, msg = judge_bounds(open(sys.argv[2]).read(), int(sys.argv[3]), float(sys.argv[4])); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) in (3, 4) and sys.argv[1] == '--png-content':
        side = sys.argv[3] if len(sys.argv) == 4 else 'right'
        if side not in ('left', 'right'): print('side must be left or right'); sys.exit(2)
        ok, msg = judge_content(sys.argv[2], side=side); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) in (6, 7) and sys.argv[1] == '--png-range':
        ok, msg = judge_range(sys.argv[2], open(sys.argv[3]).read(), int(sys.argv[4]), open(sys.argv[5]).read(), other_windows_text=open(sys.argv[6]).read() if len(sys.argv) == 7 else None); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 6 and sys.argv[1] == '--restored':
        ok, msg = judge_restored(open(sys.argv[2]).read(), open(sys.argv[3]).read(), int(sys.argv[4]), int(sys.argv[5])); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 6 and sys.argv[1] == '--coverage':
        ok, msg = judge_coverage(open(sys.argv[2]).read(), open(sys.argv[3]).read(), int(sys.argv[4]), open(sys.argv[5]).read()); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 3 and sys.argv[1] == '--png-colours':
        ok, msg = judge_colours(sys.argv[2]); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 7 and sys.argv[1] == '--shifted-windows':
        ok, msg = judge_shifted(open(sys.argv[2]).read(), open(sys.argv[3]).read(), int(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6])); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 5 and sys.argv[1] == '--bounds-x':
        ok, msg = judge_bounds_x(open(sys.argv[2]).read(), int(sys.argv[3]), float(sys.argv[4])); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 6 and sys.argv[1] == '--same-windows':
        ok, msg = judge_same_windows(open(sys.argv[2]).read(), open(sys.argv[3]).read(), int(sys.argv[4]), int(sys.argv[5])); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 4 and sys.argv[1] == '--png-width':
        ok, msg = judge_png(png_width(sys.argv[2]), float(sys.argv[3])); print(msg); sys.exit(0 if ok else 1)
    sys.exit(main(sys.argv))
