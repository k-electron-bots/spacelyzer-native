#!/usr/bin/env python3
"""Scaled accuracy check, 1k -> 100k items, tricky metadata. Three sources: (1) counts known BY CONSTRUCTION, (2) independent-size-oracle.py (stdlib walk, no engine code),
(3) the engine via `spz verify-cold` / `spz scan`. Item counts must equal across all three; allocated bytes must equal oracle vs engine; symlink/hardlink/
unreadable/sparse numbers are reported. Negative controls prove the comparison can fail. Linux portable backend only unless run on a Mac with --spz."""
import importlib.util, argparse, json, os, random, re, shutil, subprocess, sys, tempfile, unicodedata
HERE = os.path.dirname(os.path.abspath(__file__)); ORACLE = os.path.join(HERE, 'independent-size-oracle.py')
def build(root, n, seed, links=True):
    r = random.Random(seed); files = []; items = 0; sym = hl = unread = 0; dirs = [root]; sparse = 0
    def add_dir(parent, name):
        nonlocal items; p = os.path.join(parent, name); os.mkdir(p); dirs.append(p); items += 1; return p
    for i in range(max(3, n // 400)): add_dir(r.choice(dirs), f'd{i}')
    d = dirs[-1]
    for i in range(12): d = add_dir(d, f'deep{i}')                      # nesting
    add_dir(root, 'empty')
    names = ['plain', 'sp ace', 'dot.file', '.hidden', 'caf\u00e9', unicodedata.normalize('NFD', 'caf\u00e9'), 'emoji\U0001F600', 'new\nline', 'UP.TXT', 'up.txt']
    sizes = [0, 1, 511, 512, 4095, 4096, 4097, 8192, 65536]
    while items < n:
        par = r.choice(dirs); k = r.random(); nm = f'{r.choice(names)}_{items}'; p = os.path.join(par, nm)
        if k < 0.70:
            with open(p, 'wb') as f: f.write(b'x' * r.choice(sizes))
            files.append(p); items += 1
        elif k < 0.80:
            with open(p, 'wb') as f: f.truncate(r.choice([1 << 24, 1 << 30]))   # sparse: logical >> allocated
            sparse += 1; files.append(p); items += 1
        elif k < 0.90 and files and links:
            os.link(r.choice(files), p); hl += 1; items += 1                    # extra hard link entry, same or other dir
        else:
            os.symlink(r.choice(['/', '..', '.', 'missing', files[0] if files else 'x', par]), p); sym += 1; items += 1  # dangling, loop-capable, abs
    if os.getuid() != 0:
        u = add_dir(root, 'noperm'); open(os.path.join(u, 'hidden'), 'w').write('z'); items += 1; os.chmod(u, 0)
        unread = 1
    return dict(items=items, symlinks=sym, extra_hardlinks=hl, sparse=sparse, planted_unreadable_dirs=unread)
def oracle(root, spz=None):
    cmd = [sys.executable, ORACLE, root] + (['--spz', spz] if spz else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(r.stdout), r.returncode
def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--spz', required=True); ap.add_argument('--sizes', default='1000,10000,100000'); ap.add_argument('--seed', type=int, default=7); ap.add_argument('--deadline-seconds', type=float, default=600); ap.add_argument('--out')
    a = ap.parse_args(); bad = []; rows = []; import time, platform; t00 = time.monotonic(); incomplete = []; timings = {}
    for n in map(int, a.sizes.split(',')):
        left = a.deadline_seconds - (time.monotonic() - t00)
        if left < 0: incomplete.append(n); print(f'INCOMPLETE size {n}: deadline {a.deadline_seconds}s reached, not run (no claim)', file=sys.stderr); continue
        t0 = time.monotonic()
        need = n * 12_000 * 3   # measured about 7.8 KB allocated per item at 100k (775 MB) (see oracle output); the tree is built twice (links + no-links variants) and oracle/engine read it, so require 3x headroom
        free = shutil.disk_usage(tempfile.gettempdir()).free
        if free < need:
            print(f'NOT-RUN size {n}: needs about {need >> 20} MiB free, have {free >> 20} MiB (reported, not a pass)', file=sys.stderr); bad.append((n, 'NOT-RUN disk')); continue
        root = tempfile.mkdtemp(prefix=f'acc{n}-')
        try:
            c = build(root, n, a.seed + n)
            o, rc = oracle(root, a.spz)
            sk = subprocess.run([a.spz, 'scan', root], capture_output=True, text=True).stdout
            m = re.search(r'\((\d+) skipped\)', sk); skipped = int(m.group(1)) if m else None
            # construction counts items inside an unreadable dir the scanner cannot see: 1 hidden child is not visible to anyone
            vis = c['items'] - c['planted_unreadable_dirs']
            ok_items = o['items'] == vis and o['spz'] and o['spz']['items'] == vis
            ok_bytes = o['spz'] and o['spz']['allocated_bytes'] == o['allocated_bytes']
            ok_cls = o['symlinks'] == c['symlinks'] and o['extra_hardlink_entries'] == c['extra_hardlinks'] and len(o['unreadable']) == c['planted_unreadable_dirs'] and (skipped is None or skipped == c['planted_unreadable_dirs'])
            spec = importlib.util.spec_from_file_location('o', ORACLE); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
            pn = mod.per_node(root, a.spz, has_hardlinks=c['extra_hardlinks'] > 0)
            ok_nodes = pn['diff_count'] == 0 and len(pn['skips']) == c['planted_unreadable_dirs'] and all(p.startswith(root) for _, p in pn['skips'])
            # same sizes with hard links forbidden: every node's cumulative size must match exactly
            root2 = tempfile.mkdtemp(prefix=f'accnl{n}-')
            try:
                c2 = build(root2, n, a.seed + n + 1, links=False); pn2 = mod.per_node(root2, a.spz, has_hardlinks=False)
                ok_nodes2 = pn2['diff_count'] == 0 and len(pn2['skips']) == c2['planted_unreadable_dirs']
                o2, _ = oracle(root2, a.spz); ok_nodes2 = ok_nodes2 and o2['verdict'] == 'AGREE' and o2['items'] == c2['items'] - c2['planted_unreadable_dirs']
            finally:
                for dp, dn, fn in os.walk(root2): os.chmod(dp, 0o700)
                shutil.rmtree(root2, ignore_errors=True)
            if n == int(a.sizes.split(',')[0]):   # negative control: an engine that misreports one directory and drops one file must be caught
                w = tempfile.mktemp(suffix='.sh'); open(w, 'w').write(f'#!/bin/sh\n{a.spz} dump "$1" | awk -F"\\t" \'BEGIN{{OFS="\\t"}} NR==2 && $1=="Directory"{{$2=$2+1}} NR==5 && $1=="File"{{next}} {{print}}\'\n'); os.chmod(w, 0o755)
                neg = mod.per_node(root2 if False else root, w, has_hardlinks=False); os.unlink(w)
                if neg['diff_count'] < 2: bad.append((n, 'negative control: tampered dump not detected', neg['diff_count']))
            if not ok_nodes: bad.append((n, 'per-node links-tree', pn['diffs'][:3]))
            if not ok_nodes2: bad.append((n, 'per-node no-links tree', pn2['diffs'][:3]))
            row = dict(per_node=dict(nodes=pn['nodes'], diffs=pn['diff_count'], skips=pn['skips'], nolinks_nodes=pn2['nodes'], nolinks_diffs=pn2['diff_count']), n=n, construct=c, oracle=dict(items=o['items'], allocated=o['allocated_bytes'], logical=o['logical_bytes'], unreadable=len(o['unreadable']), symlinks=o['symlinks'], extra_hardlinks=o['extra_hardlink_entries']), spz=o['spz'], spz_skipped=skipped, items_ok=bool(ok_items), bytes_ok=bool(ok_bytes), classes_ok=bool(ok_cls)); rows.append(row)
            for k in ('items_ok', 'bytes_ok', 'classes_ok'):
                if not row[k]: bad.append((n, k))
            # negative controls: the comparison must be able to fail
            if n == int(a.sizes.split(',')[0]):
                big = os.path.join(root, 'late'); open(big, 'wb').write(b'q' * 8192)
                o_pre = o['allocated_bytes']
                import importlib.util as U; s = U.spec_from_file_location('o', ORACLE); mod = U.module_from_spec(s); s.loader.exec_module(mod)
                got, _, _ = mod.spz_line(a.spz, root)
                if got is None or got[1] == o_pre or got[0] != o['items'] + 1: bad.append((n, 'negative control: engine did not see the added 8 KiB file'))
                os.unlink(big)
        finally:
            timings[n] = round(time.monotonic() - t0, 1)
            if os.getuid() != 0:
                for dp, dn, fn in os.walk(root): os.chmod(dp, 0o700)
            shutil.rmtree(root, ignore_errors=True)
    out = dict(platform=platform.platform(), uid=os.getuid(), tmp_free_mib=shutil.disk_usage(tempfile.gettempdir()).free >> 20, seconds_by_size=timings, incomplete_sizes=incomplete, rows=rows, failures=bad,
               verdict='FAIL' if bad else ('INCOMPLETE' if incomplete else 'PASS'))
    txt = json.dumps(out, indent=1); print(txt)
    if a.out: open(a.out, 'w').write(txt)
    return 1 if bad else (3 if incomplete else 0)
if __name__ == '__main__': sys.exit(main())
