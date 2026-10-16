#!/bin/bash
# make-cancel-fixture.sh <dir> [shard_index shard_count] - bounded scan fixture for
# cancel-window and 1M-publication measurement.
# Run 38458610451 timing evidence: warm /Library scans finished in 0.7-1.7s, shorter than the
# open+pgrep+driver-spawn chain, so the Stop control (present only while model.scanning) was
# never observable. ~1M empty directory entries give the REAL engine scan a ~4-10s window on
# this runner class. Cancellation is the product's actual path (Stop -> model.cancel()); the
# fixture adds no delay to the app and changes no product code.
# Hardlinks are per-dir seeds (5000 links each): a single seed overflows the per-inode link
# limit (~65k on APFS/overlayfs) long before 1M entries.
# Shard mode: <shard_index shard_count> splits the 200 dirs into contiguous ranges so the
# workflow can generate in parallel (run 38773486853 measured 247s serial link()); totals are
# identical to serial generation. Unsharded invocation keeps the original behavior including
# the fail-fast short-fixture check; sharded totals are verified by the workflow across all
# shard outputs.
set -u
ROOT="$1"
SHARD="${2:-0}"
NSHARDS="${3:-1}"
python3 - "$ROOT" "$SHARD" "$NSHARDS" <<'PY'
import os, sys
root, shard, nshards = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(root, exist_ok=True)
per = 200 // nshards
start = shard * per
end = 200 if shard == nshards - 1 else start + per
n = 0
for d in range(start, end):
    dp = os.path.join(root, f"d{d:03d}"); os.makedirs(dp, exist_ok=True)
    seed = os.path.join(dp, "seed"); open(seed, "w").close(); n += 1
    for i in range(5000):
        os.link(seed, os.path.join(dp, f"f{i:04d}")); n += 1
print(f"fixture entries={n} dirs={end-start} root={root} shard={shard}/{nshards}")
# fail fast (unsharded only): a short fixture would silently recreate the missed-window
# failure; in shard mode the workflow verifies the aggregate totals instead.
sys.exit(0 if (nshards > 1 or n >= 1_000_000) else 1)
PY
