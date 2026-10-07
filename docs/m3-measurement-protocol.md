# Milestone 3 measurement protocol: UI stalls

Status: protocol and fixtures only. No stall is claimed measured end-to-end, and no
stall is claimed removed, until before/after numbers exist from the Mac harness.

Scope: three interaction stalls - typing in the filter field, hover over treemap
and outline, expanding a huge folder.

## Fixtures (scripts/make_fixtures.py)

Deterministic trees: same profile -> same names, sizes, mtimes, counts, and
spec_sha256 on any machine. Files are sparse (os.truncate): a 1m-file profile
costs inodes, not disk. `verify` re-reads a generated tree against its spec.

  python3 scripts/make_fixtures.py generate ROOT --profile NAME
  python3 scripts/make_fixtures.py verify   ROOT --profile NAME

Profiles:
- expansion-10k / expansion-100k / expansion-1m: one directory with
  10,000 / 100,000 / 1,000,000 direct file children (plus one zz_nested subdir so
  the row keeps a chevron). The huge-folder expansion stall.
- typing-200k: 2,000 dirs x 100 files (202,001 nodes), rotating name words
  (invoice, backup, photo, archive, render, cache, export, draft). The
  filter-typing stall at scale.

## What is Linux-measurable (engine only, candidates not conclusions)

Ad-hoc release-build bench (throwaway example, not shipped) over the fixtures in a
Linux container, cargo 1.99.0:

| profile | scan | expand SizeDesc | expand NameAsc | filter "invoice" | treemap layout |
| --- | --- | --- | --- | --- | --- |
| expansion-1m | 6.9-9.6s (1,000,004 nodes) | 13-14ms | 113-116ms | 31-41ms (0 matches) | 24.6ms |
| typing-200k | 0.23-1.2s (202,001 nodes) | 0.0ms | 0.2-0.3ms | 4.7-6.1ms (25,000 matches) | 2.6ms (30,000-rect cap) |
| expansion-10k | 68-83ms (10,004 nodes) | 0.1ms | 0.6ms | 0.4-0.5ms | 1.0ms |

Container caveats: this filesystem reports st_blocks=0 for every file, so scanned
sizes are all zero and `layout` was measured through `layout_with` with
synthesized per-node sizes; scan wall time varies with fs cache. These are
engine-side costs only - they say nothing about SwiftUI main-thread stalls, which
are Mac-gated below.

Candidates, ranked (Linux numbers + static read; each UNMEASURED for UI until the
Mac run):
1. Per-expansion sort of the expanded folder: NameAsc costs 113-116ms at 1m
   direct children versus 13-14ms in native SizeDesc order - above the 100ms
   jank bar. Top candidate for the expansion stall.
2. Full-tree filter pass per keystroke batch: 31-41ms at 1m nodes. The Rust
   layer runs it off-main per static read; the harness decides whether the UI
   thread still stalls on result application.
3. Treemap layout: 24.6ms at 1m siblings (sort-dominated; rect emission folds
   under min_edge), 2.6ms at 202k nodes.
Static read (Sources/Spacelyzer, UNMEASURED): filter/outline/layout/derived data
are off-main in Rust and preview publication batching keeps scan work off-main.
Per-row sorting and identity churn in OutlineView/TreemapView remain to be
confirmed by the harness.

## Mac-gated measurement (each run needs its own approval)

Harness: scripts/ax-client.swift + scripts/ui-calibrate.swift driving AX.
- typing: key event -> filter field AX value updated -> result list AX children
  updated; p50/p95 over N=200 keystrokes into a scanned typing-200k tree.
- hover: pointer move -> hover highlight AX-visible over treemap rects and
  outline rows; lag measured via timestamped AX polls.
- expansion: disclose triangle on expansion-10k/100k/1m fixtures: click ->
  children AX-visible; jank = main thread blocked >100ms.

Before/after protocol: same fixture, same machine, 3 runs each, medians, raw
harness logs kept per run. A stall is reported removed only with the before/after
median pair in the PR, after-run clearing the jank bar.
