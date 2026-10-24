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
    ok = any(abs(width_px - frame_w * k) <= TOL for k in (1, 2))
    return ok, 'png width %s vs window frame width %s (1x or 2x +-%s): %s' % (width_px, frame_w, TOL, 'OK' if ok else 'CLIPPED/WRONG')

if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--png-width':
        ok, msg = judge_png(png_width(sys.argv[2]), float(sys.argv[3])); print(msg); sys.exit(0 if ok else 1)
    sys.exit(main(sys.argv))
