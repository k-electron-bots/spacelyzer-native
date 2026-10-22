#!/usr/bin/env python3
"""Independent size/count oracle for `spz verify-cold`. Python stdlib only (os.scandir + lstat), shares NO code with the engine.
Semantics are stated, not assumed to equal du or Finder:
  allocated = st_blocks*512 per non-directory entry, a multiply-linked inode (st_nlink>1) counted once per (dev,ino); directories contribute their own entries only
  logical   = st_size, reported separately and never compared (APFS sparse, clones and compression make it differ from allocated)
  items     = every entry below the root (files, dirs, symlinks); the root itself is not counted. Symlinks are never followed.
Unreadable directories/entries are listed, never silently dropped. Output is JSON; with --spz BIN the oracle runs `BIN verify-cold ROOT` and compares
items+allocated, exit 1 on disagreement. Exact comparison is only meaningful on a QUIET tree; --tolerate-bytes/--tolerate-items allow stated drift."""
import argparse, json, os, subprocess, sys, re

def walk(root):
    items = alloc = logical = symlinks = extra_links = 0
    seen = set(); unreadable = []; nonutf8 = 0; stack = [root]; dirs = 0
    while stack:
        d = stack.pop()
        try:
            it = list(os.scandir(d))
        except OSError as e:
            unreadable.append([d, e.errno]); continue
        for e in it:
            items += 1
            try: st = e.stat(follow_symlinks=False)
            except OSError as er:
                unreadable.append([e.path, er.errno]); continue
            if os.fsencode(e.name).decode('utf-8', 'surrogateescape') != e.name or '\udc80' <= max(e.name, '\0') <= '\udcff': nonutf8 += 1
            import stat as S
            if S.S_ISDIR(st.st_mode): dirs += 1; stack.append(e.path); continue
            if S.S_ISLNK(st.st_mode): symlinks += 1
            logical += st.st_size
            if st.st_nlink > 1:
                if (st.st_dev, st.st_ino) in seen: extra_links += 1; continue
                seen.add((st.st_dev, st.st_ino))
            alloc += st.st_blocks * 512
    return dict(root=root, items=items, dirs=dirs, allocated_bytes=alloc, logical_bytes=logical, symlinks=symlinks,
                extra_hardlink_entries=extra_links, unreadable=unreadable, nonutf8_names=nonutf8)

def spz_line(binp, root):
    r = subprocess.run([binp, 'verify-cold', root], capture_output=True, text=True)
    m = re.search(r'^default : (\d+) items (\d+) bytes', r.stdout, re.M)
    if not m: return None, r.returncode, r.stdout + r.stderr
    return (int(m.group(1)), int(m.group(2))), r.returncode, r.stdout

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('root'); ap.add_argument('--spz'); ap.add_argument('--tolerate-bytes', type=int, default=0); ap.add_argument('--tolerate-items', type=int, default=0)
    a = ap.parse_args(); root = os.path.realpath(a.root)
    o = walk(root)
    if a.spz:
        got, rc, out = spz_line(a.spz, root)
        o['spz'] = None if got is None else dict(items=got[0], allocated_bytes=got[1], exit=rc)
        ok = got is not None and abs(got[0] - o['items']) <= a.tolerate_items and abs(got[1] - o['allocated_bytes']) <= a.tolerate_bytes
        o['verdict'] = 'AGREE' if ok else 'DISAGREE'
        if got: o['delta'] = dict(items=got[0] - o['items'], allocated_bytes=got[1] - o['allocated_bytes'])
        print(json.dumps(o, indent=1)); return 0 if ok else 1
    print(json.dumps(o, indent=1)); return 0
if __name__ == '__main__': sys.exit(main())
