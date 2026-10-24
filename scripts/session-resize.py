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
    result, deadline = None, time.monotonic() + float(os.environ.get('SPZ_SIZE_WAIT', '2.5'))
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

def judge_content(path, strip=200, need=8):
    """Rendered-content proof for a genuinely wide image: the right-most `strip` pixel columns (the part past a 1024pt
    display) must hold real rendering, not blank fill: at least `need` distinct colours."""
    d = png_pixels(path)
    if d is None: return False, 'png not decodable (need 8-bit RGB/RGBA)'
    w, h, rows, bpp = d; x0 = max(0, w - strip); colours = set()
    for r in rows: colours.update(bytes(r[x*bpp:x*bpp+3]) for x in range(x0, w))
    ok = len(colours) >= need
    return ok, 'SMOKE check only, native pixel review remains the gate: right-most %d columns of %dx%d image hold %d distinct colours (need >= %d): %s' % (w - x0, w, h, len(colours), need, 'OK' if ok else 'BLANK/UNRENDERED')

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
    if len(sys.argv) == 3 and sys.argv[1] == '--png-content':
        ok, msg = judge_content(sys.argv[2]); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 6 and sys.argv[1] == '--same-windows':
        ok, msg = judge_same_windows(open(sys.argv[2]).read(), open(sys.argv[3]).read(), int(sys.argv[4]), int(sys.argv[5])); print(msg); sys.exit(0 if ok else 1)
    if len(sys.argv) == 4 and sys.argv[1] == '--png-width':
        ok, msg = judge_png(png_width(sys.argv[2]), float(sys.argv[3])); print(msg); sys.exit(0 if ok else 1)
    sys.exit(main(sys.argv))
