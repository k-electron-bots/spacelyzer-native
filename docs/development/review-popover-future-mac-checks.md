# Review popover: Mac checks (3 written as UNCOMPILED/UNRUN source, the rest PLANNED)

Written as source in SpacelyzerApp.swift (declared in the manifest, 65 names, never compiled or run, so no result exists):
`review-model-refuses-and-drops-when-engine-untrusted` (pre-read refusal and post-read drop, items 4/5 at model level only),
`review-verdict-messages-are-nonempty-and-only-same-allows-proceeding` (item 6, text only, not accessibility labels),
`review-selection-and-filter-changes-start-no-review` (item 2, model level: it shows nothing calls request(); it is weak by construction).
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
