#!/usr/bin/env python3
"""Independent size/count oracle for `spz verify-cold`. Python stdlib only (os.scandir + lstat), shares NO code with the engine.
Semantics are stated, not assumed to equal du or Finder:
  allocated = st_blocks*512 per non-directory entry, a multiply-linked inode (st_nlink>1) counted once per (dev,ino); directories contribute their own entries only
  logical   = st_size, reported separately and never compared (APFS sparse, clones and compression make it differ from allocated)
  items     = every entry below the root (files, dirs, symlinks); the root itself is not counted. Symlinks are never followed.
Unreadable directories/entries are listed, never silently dropped. Output is JSON; with --spz BIN the oracle runs `BIN verify-cold ROOT` and compares
items+allocated, exit 1 on disagreement. Exact comparison is only meaningful on a QUIET tree; --tolerate-bytes/--tolerate-items allow stated drift."""
import argparse, json, os, subprocess, sys, re

class Capped(Exception): pass

def walk(root, nodes=None, max_items=None, deadline=None):
    items = alloc = logical = symlinks = extra_links = 0
    seen = set(); unreadable = []; nonutf8 = []; stack = [root]; dirs = 0
    while stack:
        d = stack.pop()
        try:
            it = list(os.scandir(d))
        except OSError as e:
            unreadable.append([d, e.errno]); continue
        for e in it:
            try: os.fsencode(e.name).decode('utf-8')
            except UnicodeDecodeError: nonutf8.append(e.path); continue   # documented engine rule: not in the tree or any total, listed as skipped (lossy)
            items += 1
            if max_items is not None and items > max_items: raise Capped(f'items>{max_items}')
            if deadline is not None and (items & 1023) == 0 and __import__('time').monotonic() > deadline: raise Capped('time')
            try: st = e.stat(follow_symlinks=False)
            except OSError as er:
                unreadable.append([e.path, er.errno]); continue
            import stat as S
            if S.S_ISDIR(st.st_mode): dirs += 1; stack.append(e.path); (nodes is not None) and nodes.__setitem__(e.path, ['Directory', 0]); continue
            if S.S_ISLNK(st.st_mode): symlinks += 1
            if nodes is not None: nodes[e.path] = ['Symlink' if S.S_ISLNK(st.st_mode) else 'File', st.st_blocks * 512]
            logical += st.st_size
            if st.st_nlink > 1:
                if (st.st_dev, st.st_ino) in seen: extra_links += 1; continue
                seen.add((st.st_dev, st.st_ino))
            alloc += st.st_blocks * 512
    return dict(root=root, items=items, dirs=dirs, allocated_bytes=alloc, logical_bytes=logical, symlinks=symlinks,
                extra_hardlink_entries=extra_links, unreadable=unreadable, nonutf8_names=len(nonutf8), nonutf8_raw_hex=sorted(os.fsencode(x).hex() for x in nonutf8), nonutf8_lossy=sorted(os.fsencode(x).decode('utf-8', 'replace') for x in nonutf8), lossy_ambiguous=len(set(os.fsencode(x).decode('utf-8', 'replace') for x in nonutf8)) < len(nonutf8))

def unesc(t):
    o = []; i = 0
    while i < len(t):
        c = t[i]
        if c == '\\' and i + 1 < len(t): o.append({'n': '\n', 't': '\t', 'r': '\r', '\\': '\\'}.get(t[i + 1], t[i + 1])); i += 2
        else: o.append(c); i += 1
    return ''.join(o)

def per_node(root, binp, has_hardlinks):
    """Per-node comparison. nodes: path -> [kind, own allocated]; cumulative directory sizes are rolled up here, independently of the engine.
    Cross-directory hard links make per-directory attribution walk-order dependent (engine docs say so), so with hard links only the node SET, kinds,
    file sizes' multiset and the root total are compared; without them every node's cumulative size must match exactly."""
    nodes = {}; pre = walk(root, nodes)
    cum = {}
    for p, (k, sz) in nodes.items():
        if k != 'Directory':
            d = os.path.dirname(p)
            while True:
                cum[d] = cum.get(d, 0) + sz
                if d == root: break
                d = os.path.dirname(d)
    r = subprocess.run([binp, 'dump', root] if isinstance(binp, str) else binp + [root], capture_output=True, text=True)
    eng = {}; skips = []
    for line in r.stdout.splitlines():
        a = line.split('\t')
        if a[0] == 'SKIP': skips.append((a[1], unesc(a[2]))); continue
        eng[unesc(a[2])] = (a[0], int(a[1]))
    want = {root: ('Directory', None)}; want.update({p: (k, None) for p, (k, _) in nodes.items()})
    diffs = []
    for p in sorted(set(want) | set(eng)):
        if p not in eng: diffs.append(['only_oracle', p]); continue
        if p not in want: diffs.append(['only_engine', p]); continue
        if want[p][0] != eng[p][0]: diffs.append(['kind', p, want[p][0], eng[p][0]]); continue
        if want[p][0] == 'Directory':
            if not has_hardlinks and eng[p][1] != cum.get(p, 0): diffs.append(['dir_size', p, cum.get(p, 0), eng[p][1]])
        elif not has_hardlinks and eng[p][1] != nodes[p][1]: diffs.append(['file_size', p, nodes[p][1], eng[p][1]])
    lossy_got = sorted(p for _, p in skips if '\ufffd' in p)
    if lossy_got != pre['nonutf8_lossy']: diffs.append(['lossy_skip_multiset', pre['nonutf8_lossy'][:3], lossy_got[:3]])   # compares as a multiset: raw names may be indistinguishable after lossy rendering, counts are not
    post_nodes = {}; post = walk(root, post_nodes)
    drift = post_nodes != nodes or post['items'] != pre['items'] or post['allocated_bytes'] != pre['allocated_bytes']   # tree changed while the engine ran: result is INCONCLUSIVE, not an engine fault
    return dict(nodes=len(want), diffs=diffs[:20], diff_count=len(diffs), skips=skips, drift=drift, expected_skips=len(pre['unreadable']) + pre['nonutf8_names'], lossy_ambiguous=pre['lossy_ambiguous'])

def spz_line(binp, root, timeout=None):
    r = subprocess.run([binp, 'verify-cold', root], capture_output=True, text=True, timeout=timeout)
    m = re.search(r'^default : (\d+) items (\d+) bytes', r.stdout, re.M)
    if not m: return None, r.returncode, r.stdout + r.stderr
    return (int(m.group(1)), int(m.group(2))), r.returncode, r.stdout

def main():
    import time
    ap = argparse.ArgumentParser(); ap.add_argument('root'); ap.add_argument('--spz'); ap.add_argument('--tolerate-bytes', type=int, default=0); ap.add_argument('--tolerate-items', type=int, default=0)
    ap.add_argument('--max-items', type=int); ap.add_argument('--max-seconds', type=float)
    a = ap.parse_args(); root = os.path.realpath(a.root); dl = None if a.max_seconds is None else time.monotonic() + a.max_seconds
    try: o = walk(root, max_items=a.max_items, deadline=dl)
    except Capped as c:
        print(json.dumps(dict(root=root, verdict='INCOMPLETE', reason=f'oracle cap reached ({c}); no comparison made, nothing is claimed'), indent=1)); return 3
    if a.spz:
        left = None if dl is None else max(1.0, dl - time.monotonic())
        try: got, rc, out = spz_line(a.spz, root, left)
        except subprocess.TimeoutExpired:
            print(json.dumps(dict(root=root, verdict='INCOMPLETE', reason='engine timed out under the time cap; no comparison made'), indent=1)); return 3
        try: o2 = walk(root, max_items=a.max_items)
        except Capped: o2 = None
        o['spz'] = None if got is None else dict(items=got[0], allocated_bytes=got[1], exit=rc)
        drift = o2 is None or o2['items'] != o['items'] or o2['allocated_bytes'] != o['allocated_bytes']   # oracle's own before/after differ: the tree moved
        ok = got is not None and abs(got[0] - o['items']) <= a.tolerate_items and abs(got[1] - o['allocated_bytes']) <= a.tolerate_bytes
        o['verdict'] = 'AGREE' if ok and not drift else ('DRIFT' if drift else 'DISAGREE')   # DRIFT = inconclusive, never blamed on the engine
        if got: o['delta'] = dict(items=got[0] - o['items'], allocated_bytes=got[1] - o['allocated_bytes'])
        print(json.dumps(o, indent=1)); return {'AGREE': 0, 'DISAGREE': 1, 'DRIFT': 4}[o['verdict']]
    print(json.dumps(o, indent=1)); return 0
if __name__ == '__main__': sys.exit(main())
