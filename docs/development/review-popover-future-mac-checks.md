# Review popover: Mac checks (3 written as UNCOMPILED/UNRUN source, the rest PLANNED)

Written as source in SpacelyzerApp.swift (declared in the manifest, 65 names, never compiled or run, so no result exists):
`review-model-refuses-and-drops-when-engine-untrusted` (pre-read refusal and post-read drop, items 4/5 at model level only),
`review-verdict-messages-are-nonempty-and-only-same-allows-proceeding` (item 6, text only, not accessibility labels),
`review-bare-model-selection-change-makes-no-review-request` (bare AppModel only, selection only; no filter, no window, no popover; weak by construction).
Everything else below remains PLANNED: it needs a mounted window.

Status: the "Check on disk" popover is uncompiled source. These are the checks a Mac run should add. None is in the ordering manifest
yet, so no count in any report includes them. Nothing below has been observed.

1. The popover opens exactly once per click (a counter on `ItemReviewPopover.onAppear`, test builds only).
2. Selecting items, drilling and filtering perform no review I/O (the review request counter stays 0 until the button is clicked).
3. Opening and closing the popover leaves Trash state untouched: `pendingRemoval`, `removalMessage`, `lastRemoved` and the tree version are unchanged.
4. Invalidation closes the popover and drops the result for each of: selection change, filter change, rescan (tree replaced), removal
   (revision bump), engine poisoned while open, and a removal pending while open.
5. The poisoned state shows the existing warning and the button is disabled.
6. Every verdict (Same, Different, NoScannedIdentity, Unaddressable, AncestorSymlink, Gone, and an unexpected code) produces a
   non-empty accessibility label, and refusal verdicts are not worded as a match.
7. At the minimum window width the popover and selection bar are not clipped; a PNG is captured for review. A PNG is evidence for a human
   reviewer, not an acceptance of the layout, and VoiceOver behavior is not claimed.
8. Concurrency: `tree_review` against `forget` has a Rust stress test (`reviews_run_concurrently_with_forgets_and_never_change_their_answer`)
   and a source argument (review reads only fields written once at scan time, forget replaces only the size table through `&self`).
   Neither proves the absence of a race, and the caller's version check is a staleness guard, not a race-freedom proof.

## CSV export (source only, UNCOMPILED/UNRUN)
Written and declared: `csv-largest-quotes-exactly-and-marks-unrepresentable-paths` (formatting),
`csv-export-flow-refuses-blocked-toolarge-stale-and-writes-once-when-unchanged` (the flow with injected panel, path and write; stale in
each of treeID, version, filter, revision, ids, sizes; stale during preparation; panel dismissed),
`csv-export-real-model-wiring-leaves-removal-message-untouched` (real AppModel and its real export wiring; only the panel and the write are injected; removalMessage holds a sentinel).
Still PLANNED, needs a Mac and a window: the real NSSavePanel and its overwrite confirmation, a real file written and read back,
Excel/Numbers opening a UTF-8 file with non-ASCII names, a rescan or removal while the panel is open, cancellation by a rescan
(AppModel cancels exportTask on a new tree), and the toolbar layout.

## Folders tab (Rust tested on Linux; Swift source only, UNCOMPILED/UNRUN)
Written and declared: folders-model-publishes-real-list-drops-stale-and-clears-on-poison (loading state, publish, an isolated generation guard
on the same tree with a late old-generation answer, an answer for another tree, poison), folders-model-clears-at-once-and-rejects-stale-version-with-bounded-retry
(revision bump empties the rows immediately; a stale-version answer is rejected and retried), folders-model-version-retry-is-bounded-and-ends-failed-with-no-rows
(exactly 3 tries, then a failure, no rows, no count). They use the real engine, a real AppModel and a test-only loader seam.
Still PLANNED, needs a window: the loading/failed/ready overlays and header, selection disabled while loading, tab switching,
the picker's fourth segment at minimum width, a removal while the tab is open, and Trash being refused for a Folders selection under a filter
(read from source: removalBlockedReason and proposeRemoval still apply isOutsideFilter, filterUntrustedReason, destructiveBlocked and the protected-path list to any selected id).

Folders retry button ("Try Again" in the failed overlay, disabled while the engine is poisoned) and `.task(id:)` refresh on tab show: source only, never rendered or clicked.
Needs a window to test: clicking Try Again shows Loading then ready, the task refresh runs when the tab appears, and the overlay layout.
