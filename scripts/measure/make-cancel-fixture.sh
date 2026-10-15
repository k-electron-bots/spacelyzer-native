#!/bin/bash
# make-cancel-fixture.sh <dir> - bounded scan fixture for cancel-window measurement.
# Run 38458610451 timing evidence: warm /Library scans finished in 0.7-1.7s, shorter than the
# open+pgrep+driver-spawn chain, so the Stop control (present only while model.scanning) was
# never observable. ~1M empty directory entries give the REAL engine scan a ~4-10s window on
# this runner class. Cancellation is the product's actual path (Stop -> model.cancel()); the
# fixture adds no delay to the app and changes no product code.
# Hardlinks are per-dir seeds (5000 links each): a single seed overflows the per-inode link
# limit (~65k on APFS/overlayfs) long before 1M entries.
set -u
ROOT="$1"
python3 - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
os.makedirs(root, exist_ok=True)
n = 0
for d in range(200):
    dp = os.path.join(root, f"d{d:03d}"); os.makedirs(dp, exist_ok=True)
    seed = os.path.join(dp, "seed"); open(seed, "w").close(); n += 1
    for i in range(5000):
        os.link(seed, os.path.join(dp, f"f{i:04d}")); n += 1
print(f"fixture entries={n} dirs=200 root={root}")
# fail fast: a short fixture would silently recreate the missed-window failure
sys.exit(0 if n >= 1_000_000 else 1)
PY
