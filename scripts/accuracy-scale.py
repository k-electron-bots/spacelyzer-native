#!/usr/bin/env python3
"""Scaled accuracy check, 1k -> 100k items, tricky metadata. Sources: (1) counts known BY CONSTRUCTION, (2) independent-size-oracle.py (stdlib walk, no engine code),
(3) the engine: `spz verify-cold` (default AND portable legs, both compared separately) and `spz dump` (both legs). Negative controls live in test-accuracy-controls.py.
Assertions: item counts equal across all three; allocated bytes equal oracle vs each engine leg; symlink/hard-link/unreadable counts equal construction;
skipped entries equal as exact (reason, path) multiset; no-hard-link tree: every node's size equal; hard-link tree: path set + kinds + root total only.
ONE shared deadline bounds build, oracle, engine and cleanup (cleanup has a reserved slice). Missing/unparseable output FAILS, never disables a check.
Verdicts: PASS, FAIL, INCOMPLETE (deadline/disk/drift: nothing claimed for the affected size). Linux/portable unless run on a Mac with --spz."""
import argparse, importlib.util, json, os, platform, random, re, shutil, subprocess, sys, tempfile, time, unicodedata
HERE = os.path.dirname(os.path.abspath(__file__)); ORACLE = os.path.join(HERE, 'independent-size-oracle.py')
spec = importlib.util.spec_from_file_location('o', ORACLE); O = importlib.util.module_from_spec(spec); spec.loader.exec_module(O)

class DeadlineHit(Exception): pass
class Deadline:
    def __init__(self, total, cleanup_reserve): self.t0 = time.monotonic(); self.total = total; self.reserve = cleanup_reserve
    def work_left(self): return self.total - self.reserve - (time.monotonic() - self.t0)     # work must stop here; cleanup uses the reserve
    def check(self):
        if self.work_left() <= 0: raise DeadlineHit()
    def cap(self): return max(1.0, self.work_left())                                          # subprocess timeout
    def abs(self): return time.monotonic() + self.work_left()                                 # absolute monotonic work deadline

def build(root, n, seed, dl, links=True):
    r = random.Random(seed); files = []; items = 0; sym = hl = 0; dirs = [root]; sparse = 0; noperm = None
    def add_dir(parent, name):
        nonlocal items; p = os.path.join(parent, name); os.mkdir(p); dirs.append(p); items += 1; return p
    for i in range(max(3, n // 400)): add_dir(r.choice(dirs), f'd{i}')
    d = dirs[-1]
    for i in range(12): d = add_dir(d, f'deep{i}')
    add_dir(root, 'empty')
    names = ['plain', 'sp ace', 'dot.file', '.hidden', 'caf\u00e9', unicodedata.normalize('NFD', 'caf\u00e9'), 'emoji\U0001F600', 'new\nline', 'UP.TXT', 'up.txt']
    sizes = [0, 1, 511, 512, 4095, 4096, 4097, 8192, 65536]
    while items < n:
        if items % 512 == 0: dl.check()
        par = r.choice(dirs); k = r.random(); p = os.path.join(par, f'{r.choice(names)}_{items}')   # unique per-item suffix: case/NFC folding cannot merge two items
        if k < 0.70:
            with open(p, 'wb') as f: f.write(b'x' * r.choice(sizes))
            files.append(p); items += 1
        elif k < 0.80:
            with open(p, 'wb') as f: f.truncate(r.choice([1 << 24, 1 << 30]))
            sparse += 1; files.append(p); items += 1
        elif k < 0.90 and files and links:
            os.link(r.choice(files), p); hl += 1; items += 1
        else:
            os.symlink(r.choice(['/', '..', '.', 'missing', files[0] if files else 'x', par]), p); sym += 1; items += 1
    unread = 0
    if os.getuid() != 0:
        noperm = add_dir(root, 'noperm'); open(os.path.join(noperm, 'hidden'), 'w').write('z'); items += 1; os.chmod(noperm, 0); unread = 1
    return dict(items=items, symlinks=sym, extra_hardlinks=hl, sparse=sparse, planted_unreadable_dirs=unread, noperm=noperm)

def cleanup(root, c, log):
    """Owned-boundary delete: only a directory this run created under the temp dir (checked), chmod of the KNOWN noperm path first (os.walk cannot enter mode 000),
    no ignore_errors. A leak is recorded in the artifact, never hidden."""
    real = os.path.realpath(root); tmp = os.path.realpath(tempfile.gettempdir())
    if os.path.dirname(real) != tmp or not os.path.basename(real).startswith('acc'):
        log.append(f'REFUSED cleanup outside owned boundary: {real}'); return False
    try:
        if c and c.get('noperm') and os.path.isdir(c['noperm']): os.chmod(c['noperm'], 0o700)
        shutil.rmtree(real)
    except OSError as e:
        log.append(f'CLEANUP FAILED {real}: {e}'); return False
    if os.path.exists(real): log.append(f'CLEANUP LEFT {real}'); return False
    return True

def skipped_count(spz, root, dl):
    out = O.run_bounded([spz, 'scan', root], dl.cap()).stdout
    m = re.search(r'\((\d+) skipped\)', out)
    return int(m.group(1)) if m else None      # None => the output format changed: caller FAILS

def one_size(n, a, dl, rows, bad, incomplete, leaks, timings):
    t0 = time.monotonic(); roots = []
    try:
        need = n * 12_000 * 3; free = shutil.disk_usage(tempfile.gettempdir()).free
        if free < need: incomplete.append([n, f'disk: need ~{need >> 20} MiB, have {free >> 20} MiB']); return
        res = {}
        for variant, links, seed_off in (('links', True, 0), ('nolinks', False, 1)):
            dl.check(); root = tempfile.mkdtemp(prefix=f'acc{n}{variant[0]}-'); roots.append([root, None])
            c = build(root, n, a.seed + n + seed_off, dl, links); roots[-1][1] = c; dl.check()
            vis = c['items'] - c['planted_unreadable_dirs']
            tot = O.run_bounded([sys.executable, ORACLE, root, '--spz', a.spz, '--max-seconds', str(dl.cap())], dl.cap() + 5)
            try: o = json.loads(tot.stdout)
            except ValueError: bad.append([n, variant, 'oracle output unparseable']); continue
            if o.get('verdict') == 'INCOMPLETE': incomplete.append([n, variant + ': ' + o['reason']]); return
            if o.get('verdict') == 'DRIFT': incomplete.append([n, variant + ': DRIFT during totals run (inconclusive, not an engine fault)']); return
            skipped = skipped_count(a.spz, root, dl)
            legs = {}
            for backend in ('default', 'portable'):
                dl.check(); pn = O.per_node(root, a.spz, has_hardlinks=c['extra_hardlinks'] > 0, backend=backend, deadline=dl.abs())
                if pn['drift']: incomplete.append([n, f'{variant}/{backend}: DRIFT during per-node run']); return
                legs[backend] = dict(nodes=pn['nodes'], diffs=pn['diff_count'], first_diffs=pn['diffs'][:3], skips=pn['skips'], scope=pn['scope'])
                if pn['diff_count']: bad.append([n, variant, backend, 'per-node diffs', pn['diffs'][:3]])
            checks = dict(
                items_vs_construction=o['items'] == vis and bool(o.get('spz')) and o['spz']['items'] == vis,
                bytes_oracle_vs_default=bool(o.get('spz')) and o['spz']['allocated_bytes'] == o['allocated_bytes'],
                bytes_oracle_vs_portable=bool(o.get('spz_portable_leg')) and o['spz_portable_leg']['allocated_bytes'] == o['allocated_bytes'] and o['spz_portable_leg']['items'] == vis,
                symlinks=o['symlinks'] == c['symlinks'], extra_hardlinks=o['extra_hardlink_entries'] == c['extra_hardlinks'],
                unreadable=len(o['unreadable']) == c['planted_unreadable_dirs'],
                skipped_count_parsed_and_equal=skipped is not None and skipped == c['planted_unreadable_dirs'],
                verdict_agree=o.get('verdict') == 'AGREE')
            for k, v in checks.items():
                if not v: bad.append([n, variant, k])
            res[variant] = dict(construct={k: v for k, v in c.items() if k != 'noperm'}, oracle=dict(items=o['items'], allocated=o['allocated_bytes'], logical=o['logical_bytes'], symlinks=o['symlinks'], extra_hardlinks=o['extra_hardlink_entries'], unreadable=len(o['unreadable'])),
                                spz_default=o.get('spz'), spz_portable=o.get('spz_portable_leg'), spz_skipped=skipped, per_node=legs, checks=checks)
        rows.append(dict(n=n, **res))
    except DeadlineHit:
        incomplete.append([n, 'deadline reached during build/compare'])
    except (subprocess.TimeoutExpired, O.Capped):
        incomplete.append([n, 'engine/oracle work hit the shared deadline'])
    except KeyboardInterrupt:
        incomplete.append([n, 'interrupted (SIGINT/SIGTERM) - partial, nothing claimed']); raise
    finally:
        log = []
        for root, c in roots:
            if not cleanup(root, c, log): leaks.extend(log); bad.append([n, 'cleanup leak: ' + root])
            log.clear()
        timings[n] = round(time.monotonic() - t0, 1)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--spz', required=True); ap.add_argument('--sizes', default='1000,10000,100000'); ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--deadline-seconds', type=float, default=600); ap.add_argument('--cleanup-reserve-seconds', type=float, default=60); ap.add_argument('--out')
    a = ap.parse_args(); dl = Deadline(a.deadline_seconds, min(a.cleanup_reserve_seconds, a.deadline_seconds / 2))
    bad, rows, incomplete, leaks, timings = [], [], [], [], {}
    import signal
    def _term(sig, frm): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, _term)
    interrupted = False
    for n in map(int, a.sizes.split(',')):
        if interrupted: incomplete.append([n, 'not started: interrupted']); continue
        if dl.work_left() <= 0: incomplete.append([n, 'not started: shared deadline reached']); continue
        try: one_size(n, a, dl, rows, bad, incomplete, leaks, timings)
        except KeyboardInterrupt: interrupted = True
    out = dict(platform=platform.platform(), uid=os.getuid(), deadline_seconds=a.deadline_seconds, cleanup_reserve_seconds=dl.reserve, total_seconds=round(time.monotonic() - dl.t0, 1),
               over_deadline=(time.monotonic() - dl.t0) > a.deadline_seconds, seconds_by_size=timings, incomplete=incomplete, leaks=leaks, rows=rows, failures=bad,
               interrupted=interrupted, verdict='FAIL' if bad else ('INCOMPLETE' if incomplete else 'PASS'))
    txt = json.dumps(out, indent=1); print(txt)
    if a.out: open(a.out, 'w').write(txt)
    return 1 if bad else (3 if incomplete else 0)
if __name__ == '__main__': sys.exit(main())
