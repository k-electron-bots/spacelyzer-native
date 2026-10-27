# UI responsiveness measurement (developer reference)

How to generate test fixtures and measure interaction latency for three cases: typing in the filter field, hovering over the treemap and outline, and expanding a very large folder. This page is for contributors.

## Fixtures (scripts/make_fixtures.py)

Fixtures are deterministic trees: the same profile gives the same names, entry types, sizes, modification times (ns) and counts on any machine. `verify` compares the exact inventory (lstat only); any missing, extra, retyped or symlinked entry fails it.

    python3 scripts/make_fixtures.py generate ROOT --profile NAME
    python3 scripts/make_fixtures.py verify   ROOT --profile NAME

Profiles:
- `expansion-10k`, `expansion-100k`, `expansion-1m`: one directory with 10,000 / 100,000 / 1,000,000 direct file children, plus one `zz_nested` subdirectory so the row keeps a disclosure chevron. Used for the huge-folder expansion case.
- `typing-200k`: 2,000 directories of 100 files each (202,001 nodes) with rotating name words (invoice, backup, photo, archive, render, cache, export, draft). Used for filter typing at scale.

Safety rules enforced by the script:
- `generate` refuses a destination that exists and is not empty. It never deletes anything and never writes into a directory that has other content.
- Files are sparse (`os.truncate`), so no data blocks are allocated on filesystems that support holes. Per-entry metadata cost remains, and allocation behavior varies by filesystem.
- `spec_sha256` hashes the spec text (each entry's path, type, size and mtime-ns). It proves the tree matches the spec inventory, not the file bytes, which are all holes.

## What the harness scans

- Typing scans the profile directory directly (`ROOT/typing-200k`).
- Expansion scans the profile's wrapper directory (a directory that contains exactly one fixture). The outline lists the scanned root's children at depth 0 and never shows the root itself, so a direct scan would leave the huge folder already expanded with no chevron. Scanning the wrapper makes the profile directory a real top-level row.
- Never scan a fixtures root that holds several fixtures; it changes every count.

## Engine benchmark (Linux or macOS)

From the repo root, with a Rust toolchain:

    python3 scripts/make_fixtures.py generate /tmp/m3fix --profile expansion-1m
    cargo run --release --example m3bench -- /tmp/m3fix/expansion-1000000

The example prints scan time, expansion time for size and name order, filter time and treemap layout time. Some filesystems report `st_blocks=0`, so scanned sizes are zero; the example then measures layout with synthesized sizes. These are engine-side costs only and say nothing about main-thread behavior in the app.

## Interaction harness (macOS)

`scripts/m3-interaction-bench.swift` drives the app through the Accessibility API and ordinary mouse and key input on disposable fixtures. It makes no attribute writes and uses no menus or Trash.

It measures event-to-visible latency: the time from an input event until the expected change is observable through the Accessibility tree. This is user-visible latency, not proof the main thread was blocked, because event delivery, coalescing and scheduling add delay. Main-thread blocked time needs separate instrumentation, such as a main-thread watchdog or `os_signpost` intervals.

- Typing: key event to the filter field's value updating, and to the footer summary republishing the filter result, as p50/p95 over 200 keystrokes in a `typing-200k` tree.
- Hover: pointer move to the element under the pointer resolving, as a latency distribution over a window grid sweep.
- Expansion: click on a row's chevron button to the outline's children count changing and the chevron state flipping, on the 10k, 100k and 1M fixtures. The row is re-resolved before each repetition and before the post-click check. Expansions over 100 ms are reported as candidates for jank.

## Before and after comparisons

Use the same fixture and machine, 3 runs each, compare medians, and keep the raw JSONL logs per run. Report an improvement only with the before and after median pair, with the after run under the 100 ms bar.
