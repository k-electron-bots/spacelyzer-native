#!/usr/bin/env python3
"""Deterministic fixture trees for Spacelyzer milestone-3 UI-stall measurement.

Generates the exact trees the Mac measurement runs expand, filter and hover over.
Fully deterministic: same profile -> same names, entry types, sizes, mtimes (ns),
counts, and spec hash on any machine.

  python3 make_fixtures.py generate ROOT --profile NAME
  python3 make_fixtures.py verify   ROOT --profile NAME

Profiles:
  expansion-10k    1 dir with 10,000 direct children (huge-folder expansion)
  expansion-100k   1 dir with 100,000 direct children
  expansion-1m     1 dir with 1,000,000 direct children
  typing-200k      2,000 dirs x 100 files, name-word rotation (filter/typing at scale)

Every expansion dir also gets one subdir `zz_nested` with 2 files so the row has a chevron.

Safety and honesty rules:
- generate REFUSES a destination that already exists and is not empty: fixtures
  land in a fresh directory, never into a user path with other content, and this
  script never deletes anything.
- Files are sparse (os.truncate): holes avoid data-block allocation on
  filesystems that support them; per-entry metadata cost remains and allocation
  behavior varies by filesystem. File byte content is all holes (reads as zeros)
  by construction and is NOT covered by the hash.
- spec_sha256 hashes the SPEC TEXT: every entry's relative path, entry type,
  size, and mtime (ns). It proves the tree matches the spec inventory exactly -
  no missing, extra, or retyped entries - not file byte contents.
- Everything uses lstat semantics: symlinks are never followed, never created,
  and fail verification wherever found.
"""
import hashlib, os, sys, argparse

EPOCH = 1_700_000_000  # fixed base mtime in seconds; per-entry offset is deterministic
NS = 1_000_000_000
WORDS = ["invoice", "backup", "photo", "archive", "render", "cache", "export", "draft"]

def spec_line(rel, kind, size, mtime_ns):
    return f"{rel}\t{kind}\t{size}\t{mtime_ns}\n"

def expansion_profile(n):
    """Yield (relpath, size, mtime_ns, is_dir) for a dir with n direct files + zz_nested/."""
    base = f"expansion-{n}"
    yield (base, None, EPOCH * NS, True)
    for i in range(n):
        yield (f"{base}/f{i:07d}.dat", (i * 7919) % (8 * 1024 * 1024) + 1, (EPOCH + i) * NS, False)
    yield (f"{base}/zz_nested", None, (EPOCH + 1) * NS, True)
    yield (f"{base}/zz_nested/inner_a", 4096, (EPOCH + 2) * NS, False)
    yield (f"{base}/zz_nested/inner_b", 8192, (EPOCH + 3) * NS, False)

def typing_profile():
    base = "typing-200k"
    yield (base, None, EPOCH * NS, True)
    for d in range(2000):
        drel = f"{base}/d{d:04d}"
        yield (drel, None, (EPOCH + d) * NS, True)
        for k in range(100):
            i = d * 100 + k
            word = WORDS[(i * 13) % len(WORDS)]
            yield (f"{drel}/{word}_{k:03d}.dat", (i * 5417) % (4 * 1024 * 1024) + 1, (EPOCH + i) * NS, False)

PROFILES = {
    "expansion-10k": lambda: expansion_profile(10_000),
    "expansion-100k": lambda: expansion_profile(100_000),
    "expansion-1m": lambda: expansion_profile(1_000_000),
    "typing-200k": typing_profile,
}

def spec_entries(profile):
    """The full expected inventory: relpath -> (kind, size, mtime_ns)."""
    out = {}
    for rel, size, mtime_ns, is_dir in PROFILES[profile]():
        out[rel] = ("dir", 0, mtime_ns) if is_dir else ("file", size, mtime_ns)
    return out

def spec_hash(entries):
    h = hashlib.sha256()
    for rel in sorted(entries):
        kind, size, mtime_ns = entries[rel]
        h.update(spec_line(rel, kind, size, mtime_ns).encode())
    return h.hexdigest()

def generate(root, profile):
    entries = spec_entries(profile)
    if os.path.lexists(root):
        if not os.path.isdir(root) or os.path.islink(root):
            print(f"REFUSED: {root} exists and is not a plain directory"); sys.exit(1)
        with os.scandir(root) as it:
            if next(it, None) is not None:
                print(f"REFUSED: {root} is not empty; fixtures only generate into a fresh directory"); sys.exit(1)
    else:
        os.makedirs(root)
    dirs = []
    nfiles = ndirs = 0
    for rel in sorted(entries):
        kind, size, mtime_ns = entries[rel]
        p = os.path.join(root, rel)
        if os.path.lexists(p):  # impossible on a fresh root; defense in depth
            print(f"REFUSED: {p} already exists"); sys.exit(1)
        if kind == "dir":
            os.mkdir(p); dirs.append((p, mtime_ns)); ndirs += 1
        else:
            fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)  # O_EXCL: never follow a planted symlink
            os.truncate(fd, size); os.close(fd)
            os.utime(p, ns=(mtime_ns, mtime_ns)); nfiles += 1
        total = nfiles + ndirs
        if total % 100_000 == 0:
            print(f"  ... {total} entries", flush=True)
    # Directory mtimes last: creating children bumps the parent's mtime, so set
    # them only after every entry exists (children before parents is irrelevant
    # here - no new entries are created afterwards).
    for p, mtime_ns in dirs:
        os.utime(p, ns=(mtime_ns, mtime_ns))
    print(f"profile={profile} files={nfiles} dirs={ndirs} spec_sha256={spec_hash(entries)}")

def actual_inventory(root):
    """lstat-only walk: relpath -> (kind, size, mtime_ns). Any symlink or
    non-regular entry is reported as its own kind so it fails the comparison."""
    out = {}
    stack = [""]
    while stack:
        rel = stack.pop()
        p = os.path.join(root, rel) if rel else root
        try:
            entries = list(os.scandir(p))
        except NotADirectoryError:
            continue
        for e in entries:
            erel = f"{rel}/{e.name}" if rel else e.name
            st = e.stat(follow_symlinks=False)
            if e.is_symlink():
                out[erel] = ("symlink", 0, st.st_mtime_ns)
            elif e.is_dir(follow_symlinks=False):
                out[erel] = ("dir", 0, st.st_mtime_ns)
                stack.append(erel)
            elif e.is_file(follow_symlinks=False):
                out[erel] = ("file", st.st_size, st.st_mtime_ns)
            else:
                out[erel] = ("other", 0, st.st_mtime_ns)
    return out

def verify(root, profile):
    if not os.path.isdir(root) or os.path.islink(root):
        print(f"FAILED: {root} is not a plain directory"); sys.exit(1)
    want = spec_entries(profile)
    got = actual_inventory(root)
    ok = True
    for rel in sorted(set(want) | set(got)):
        w, g = want.get(rel), got.get(rel)
        if w is None:
            print(f"UNEXPECTED {rel} kind={g[0]}"); ok = False
        elif g is None:
            print(f"MISSING {rel}"); ok = False
        elif g != w:
            print(f"MISMATCH {rel} want={w} got={g}"); ok = False
    nfiles = sum(1 for v in got.values() if v[0] == "file")
    ndirs = sum(1 for v in got.values() if v[0] == "dir")
    print(f"profile={profile} files={nfiles} dirs={ndirs} spec_sha256={spec_hash(want)} verify={'OK' if ok else 'FAILED'}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["generate", "verify"])
    ap.add_argument("root", help="directory that will CONTAIN the profile tree (must be fresh/empty for generate)")
    ap.add_argument("--profile", required=True, choices=sorted(PROFILES))
    a = ap.parse_args()
    (generate if a.mode == "generate" else verify)(a.root, a.profile)
