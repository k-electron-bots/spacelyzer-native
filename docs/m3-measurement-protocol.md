# Milestone 3 measurement protocol: UI stalls

Status: protocol, fixtures, and a reproducible engine bench only. No stall is
claimed measured end-to-end, and no stall is claimed removed, until before/after
numbers exist from the Mac harness.

Scope: three interaction stalls - typing in the filter field, hover over treemap
and outline, expanding a huge folder.

## Fixtures (scripts/make_fixtures.py)

Deterministic trees: same profile -> same names, entry types, sizes, mtimes (ns),
counts, and spec_sha256 on any machine. `verify` compares the EXACT inventory
(lstat only): any missing, extra, retyped, or symlink entry fails it.

  python3 scripts/make_fixtures.py generate ROOT --profile NAME
  python3 scripts/make_fixtures.py verify   ROOT --profile NAME

Profiles:
- expansion-10k / expansion-100k / expansion-1m: one directory with
  10,000 / 100,000 / 1,000,000 direct file children (plus one zz_nested subdir so
  the row keeps a chevron). The huge-folder expansion stall.
- typing-200k: 2,000 dirs x 100 files (202,001 nodes), rotating name words
  (invoice, backup, photo, archive, render, cache, export, draft). The
  filter-typing stall at scale.

Safety and honesty rules (enforced by the script):
- generate REFUSES a destination that exists and is not empty; it never deletes
  anything and never writes into a user path with other content.
- Files are sparse (os.truncate): holes avoid data-block allocation on
  filesystems that support them; per-entry metadata cost remains and allocation
  behavior varies by filesystem.
- spec_sha256 hashes the SPEC TEXT (every entry's path, type, size, mtime-ns):
  it proves the tree matches the spec inventory exactly, not file byte contents.
  File bytes are all holes (read as zeros) by construction.

## What the Mac harness scans

Typing scans the PROFILE DIRECTORY directly (ROOT/typing-200k). Expansion
scans the profile's WRAPPER directory (a harness-created dir containing
exactly one fixture): run 37864247016 proved the app's outline lists the
scanned root's CHILDREN at depth 0 and the root itself is never a row, so
under a direct scan the huge folder is pre-materialized and has no
disclosure triangle - the named row never existed and both fixtures exited
6 without measuring. Scanning the wrapper makes the profile dir a real
top-level row whose expansion is the stall being measured; it adds exactly
one scan node (the wrapper). Never scan the fixtures ROOT with sibling
fixtures: that changes every count in this protocol.

## Linux engine bench (reproducible from this repo)

Recipe: on a Linux machine with a Rust toolchain, from the repo root at this
commit, generate a fixture, then run the shipped example:

  python3 scripts/make_fixtures.py generate /tmp/m3fix --profile expansion-1m
  cargo run --release --example m3bench -- /tmp/m3fix/expansion-1000000

Results from the authoring container (cargo 1.99.0, release; raw run log at the
end of this doc; ranges across repeated runs in parentheses where they varied):

| profile | scan | expand SizeDesc | expand NameAsc | filter "invoice" | treemap layout |
| --- | --- | --- | --- | --- | --- |
| expansion-1m | 6.9-9.8s (1,000,004 nodes) | 13-15ms | 113-134ms | 31-57ms (0 matches) | 24-25ms |
| typing-200k | 0.23-1.3s (202,001 nodes) | 0.0ms | 0.1-0.3ms | 4.7-6.1ms (25,000 matches) | 2.6-2.9ms (30,000-rect cap) |
| expansion-10k | 68-83ms (10,004 nodes) | 0.1ms | 0.5-0.6ms | 0.4-0.5ms | 0.7-1.0ms |

Container caveats: this container's filesystem reports st_blocks=0 for every
file, so scanned sizes are all zero and the example measures layout through
`layout_with` with synthesized per-node sizes (macOS reads real allocated sizes
via ATTR_FILE_ALLOCSIZE and is unaffected); scan wall time varies with fs cache.
These are engine-side costs only - they say nothing about SwiftUI main-thread
stalls, which are Mac-gated below.

Candidates, ranked (Linux numbers + static read; each UNMEASURED for UI until
the Mac run):
1. Per-expansion sort of the expanded folder: NameAsc costs 113-134ms at 1m
   direct children versus 13-15ms in native SizeDesc order - above the 100ms
   jank bar. Top candidate for the expansion stall.
2. Full-tree filter pass per keystroke batch: 31-57ms at 1m nodes. The Rust
   layer runs the filter off-main per static read; whether the UI thread still
   stalls applying results is UNMEASURED.
3. Treemap layout: 24-25ms at 1m siblings (sort-dominated; rect emission folds
   under min_edge), 2.6-2.9ms at 202k nodes.
Static read (Sources/Spacelyzer, UNMEASURED): filter/outline/layout/derived data
are computed off-main in Rust, and the slice-C preview driver SUPPORTS off-main
draining of scan publications - but that driver is not wired into the UI, so no
off-main claim is made for the shipping app. Per-row sorting and identity churn
in OutlineView/TreemapView remain to be confirmed by the harness.

## Mac-gated measurement (each run needs its own approval)

Harness: scripts/m3-interaction-bench.swift (M3-B slice), driving AX plus
ordinary mouse/key input on disposable fixtures - the same envelope
scripts/ui-calibrate.swift declares (no attribute writes, no menus/Trash).

What the harness measures is EVENT-TO-AX-VISIBLE latency: the time from an
input event until the expected change is observable through AX. That is
user-visible jank evidence, but it is NOT proof the main thread was blocked -
AX callbacks, coalescing, and scheduling also add delay. Main-thread blocked
time needs separate instrumentation (for example a main-thread watchdog ping or
os_signpost intervals inside the app); that instrumentation is specified as
follow-up work and is NOT part of this protocol's harness claims.

- typing: key event -> filter field AX value updated; key event -> the app's
  own footer summary container republishes the filter result (ContentView
  fullDetails, exposed on the combined summary container's AXLabel/AXHelp;
  first measured 200/200 in run 37877990327); p50/p95 over N=200 keystrokes
  into a scanned typing-200k tree. The earlier row-count signal was dropped
  after run 37870201922 proved it blind (the count never moved across 200
  keys under filter "i"). The app-reported filter ms parsed from the footer
  is corroboration only, not independently verified.
- hover: pointer move -> the element under the pointer resolves via
  AXUIElementCopyElementAtPosition; lag distribution over a window grid sweep.
  Whether the app exposes any hover-HIGHLIGHT state through AX is unverified;
  no highlight-visibility measurement is claimed.
- expansion: click the row's chevron AXButton -> the outline's top-level
  children count moves and the chevron state flips, on expansion-10k/100k/1m
  fixtures; expansions slower than 100ms are reported as jank candidates
  (event-to-visible latency, per the caveat above). The app renders its own
  chevron NSButton whose state text "Expand <name>"/"Collapse <name>" sits on
  AXDescription (AXLabel/AXTitle empty; run 37877990327's failure-path dump)
  - there is no AXDisclosureTriangle/AXDisclosing. The target row is
  re-resolved through a bounded chunked scan before every rep and before the
  post-click state check (run 37880172301: the pre-loop row handle went stale
  after rep 0's expansion; exit 6). First successfully measured in run
  37882191076 (expansion-10k: 3/3 expands, p50 149.99ms, p95 220.90ms, all
  three over the 100ms jank bar; expansion-100k: 2/2 expands, p50 114.44ms;
  BASELINE ONLY, event-to-AX-visible latency).

Before/after protocol: same fixture, same machine, 3 runs each, medians, raw
harness JSONL logs kept per run. A stall is reported removed only with the
before/after median pair in the PR, after-run clearing the 100ms bar.

## Raw bench log (authoring container, this commit's example)

```
=== expansion-1000000 ===
scan: 1000004 nodes in 9790.5ms, root size=0
expand SizeDesc: 1000001 rows in 15.3ms
expand NameAsc: 1000001 rows in 134.4ms
filter text=invoice: 0 matches in 56.7ms
layout (synthesized sizes, st_blocks=0 on this fs): 2 rects in 24.4ms
=== typing-200k ===
scan: 202001 nodes in 1318.4ms, root size=0
expand SizeDesc: 2000 rows in 0.0ms
expand NameAsc: 2000 rows in 0.1ms
filter text=invoice: 25000 matches in 5.8ms
layout (synthesized sizes, st_blocks=0 on this fs): 30000 rects in 2.9ms
=== expansion-10000 ===
scan: 10004 nodes in 78.9ms, root size=0
expand SizeDesc: 10001 rows in 0.1ms
expand NameAsc: 10001 rows in 0.5ms
filter text=invoice: 0 matches in 0.5ms
layout (synthesized sizes, st_blocks=0 on this fs): 10004 rects in 0.7ms
```
