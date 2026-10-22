# Accuracy evidence: independent size oracle

Internal engineering note. Facts only; not a correctness guarantee.

## What the harness checks
scripts/independent-size-oracle.py is a stdlib walk with no engine code. Allocated bytes = st_blocks*512, multiply-linked inodes counted once, directories add no own bytes, symlinks are never followed, logical size is reported separately, non-UTF-8 names are listed as lossy skips. scripts/accuracy-scale.py builds 1k/10k/100k trees (links and no-links), compares totals and per-node data for the default and portable engine legs, and scripts/accuracy-gate.py enforces the exact matrix. With hard links only the path set, kinds and root total are asserted per node; sizes are asserted per node on no-hard-link trees only.

## Mac run 39871364562 (head d161e967a37e350b06d0cf6d1b4b2a1f765064fd, macOS arm64, uid 501)
- Original result: conclusion FAILURE. The gate failed on per-node diffs in all 12 legs. This result stands.
- Totals checks (items, bytes vs both engine legs, symlinks, hard links, unreadable, skipped count) were true for all 1k, 10k and 100k rows.
- Cause of the per-node failure: the oracle was given the unresolved temp root (/var/...) while the engine reports the canonical root (/private/var/...). Every node appeared once on each side under different prefixes.
- Post-hoc offline recompare (labeled post hoc) of the saved first-diff records: only the root alias was normalized, keys and skip paths made relative to their own root, escapes and collisions strict. Result: 0 remaining diffs in all 12 legs (node counts 1002, 10002, 100002). Each record's dump_sha256 matches its raw dump. Engine skip = one PermissionDenied for the planted noperm dir. At 10k and 100k the oracle's expected-skip entry was beyond the 5000 diff cap, so that part rests on construction and the oracle totals (fixed since: skip lists are retained with explicit caps).
- Artifact references (sha256 prefix): artifact zip e4e0565f1175e748, job log b6d30b086dd2e847, posthoc json 37e018cc58084d6d, recompare script f63d5929ad9ff73e.
- Fix: per_node resolves only the root once; controls cover a symlinked root (failed on the old code, passes now).

## Caveats
- This is evidence for these generated fixtures on one macOS runner. It is not universal correctness.
- A Linux-only run once showed three ancestor directories 4096 bytes short on a 100k no-link tree (portable leg). The raw evidence was not retained, 10 later 100k loops and other reruns were clean, and the cause is unproven. Status: OPEN. The Mac post-hoc result does not address it.
- The hard-link per-directory attribution is not asserted.
- Case-insensitive, Unicode-normalizing and non-UTF-8 filesystem cases were NOT-RUN on the Mac runner.
