#!/usr/bin/env python3
"""Deterministic fixture trees for Spacelyzer milestone-3 UI-stall measurement.

Generates the exact trees the Mac measurement runs expand, filter and hover over.
Fully deterministic: same profile -> same names, sizes, mtimes, counts, spec hash.
Sparse files (os.truncate) so a 1m-file profile costs inodes, not disk.

  python3 make_fixtures.py generate ROOT --profile NAME
  python3 make_fixtures.py verify   ROOT --profile NAME

Profiles:
  expansion-10k    1 dir with 10,000 direct children (huge-folder expansion)
  expansion-100k   1 dir with 100,000 direct children
  expansion-1m     1 dir with 1,000,000 direct children
  typing-200k      2,000 dirs x 100 files, name-word rotation (filter/typing at scale)

Every expansion dir also gets one subdir `zz_nested` with 2 files so the row has a chevron.
"""
import hashlib, os, sys, argparse

EPOCH = 1_700_000_000  # fixed base mtime; per-file offset is deterministic
WORDS = ["invoice", "backup", "photo", "archive", "render", "cache", "export", "draft"]

def spec_entry(rel, size, mtime):
    return f"{rel}\t{size}\t{mtime}\n"

def expansion_profile(root, n):
    """Yield (relpath, size, mtime, is_dir) for a dir with n direct files + zz_nested/."""
    base = f"expansion-{n}"
    yield (base, None, None, True)
    for i in range(n):
        yield (f"{base}/f{i:07d}.dat", (i * 7919) % (8 * 1024 * 1024) + 1, EPOCH + i, False)
    yield (f"{base}/zz_nested", None, None, True)
    yield (f"{base}/zz_nested/inner_a", 4096, EPOCH, False)
    yield (f"{base}/zz_nested/inner_b", 8192, EPOCH + 1, False)

def typing_profile(root):
    base = "typing-200k"
    yield (base, None, None, True)
    for d in range(2000):
        drel = f"{base}/d{d:04d}"
        yield (drel, None, None, True)
        for k in range(100):
            i = d * 100 + k
            word = WORDS[(i * 13) % len(WORDS)]
            yield (f"{drel}/{word}_{k:03d}.dat", (i * 5417) % (4 * 1024 * 1024) + 1, EPOCH + i, False)

PROFILES = {
    "expansion-10k": lambda r: expansion_profile(r, 10_000),
    "expansion-100k": lambda r: expansion_profile(r, 100_000),
    "expansion-1m": lambda r: expansion_profile(r, 1_000_000),
    "typing-200k": typing_profile,
}

def generate(root, profile):
    h = hashlib.sha256(); nfiles = ndirs = 0
    for rel, size, mtime, is_dir in PROFILES[profile](root):
        p = os.path.join(root, rel)
        if is_dir:
            os.makedirs(p, exist_ok=True); ndirs += 1
            h.update(spec_entry(rel + "/", 0, 0).encode())
        else:
            fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)
            os.truncate(fd, size); os.close(fd)
            os.utime(p, (mtime, mtime)); nfiles += 1
            h.update(spec_entry(rel, size, mtime).encode())
        total = nfiles + ndirs
        if total % 100_000 == 0:
            print(f"  ... {total} entries", flush=True)
    print(f"profile={profile} files={nfiles} dirs={ndirs} spec_sha256={h.hexdigest()}")

def verify(root, profile):
    h = hashlib.sha256(); nfiles = ndirs = 0
    ok = True
    for rel, size, mtime, is_dir in PROFILES[profile](root):
        p = os.path.join(root, rel)
        if is_dir:
            if not os.path.isdir(p): print(f"MISSING dir {rel}"); ok = False; continue
            ndirs += 1; h.update(spec_entry(rel + "/", 0, 0).encode())
        else:
            st = os.stat(p) if os.path.exists(p) else None
            if st is None or st.st_size != size or int(st.st_mtime) != mtime:
                print(f"MISMATCH {rel}"); ok = False; continue
            nfiles += 1; h.update(spec_entry(rel, size, mtime).encode())
    print(f"profile={profile} files={nfiles} dirs={ndirs} spec_sha256={h.hexdigest()} verify={'OK' if ok else 'FAILED'}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["generate", "verify"])
    ap.add_argument("root")
    ap.add_argument("--profile", required=True, choices=sorted(PROFILES))
    a = ap.parse_args()
    (generate if a.mode == "generate" else verify)(a.root, a.profile)
