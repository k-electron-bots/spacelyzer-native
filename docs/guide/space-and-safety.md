# Space, filters and safe removal

## What the numbers mean
Sizes are allocated bytes, rounded by filesystem blocks, rather than logical file lengths. Hard-linked files count once. Unreadable locations and canceled/partial scans limit coverage. Totals are not yet a full volume-accounting model: purgeable space, APFS snapshots and clone accounting remain open work.

## Combine filters
Name, extension, kind, minimum/maximum size and modified-date windows combine across outline, treemap, Kinds and Largest. The branch-only Folders list is explicitly unfiltered; do not use a name filter as evidence that a folder total contains only matching files. Clear all filters resets them. The footer reports matching counts and bytes. A selected item can remain selected after it falls outside the filter, but cannot be removed in that state.

Zero-byte matching files are still matches. They remain in count-based lists even when there is no treemap area to draw.

## Move to Trash
Review the full-path confirmation. Protected paths, selections outside the filter and selections awaiting a filter result are refused. Undo is available for removal. Do not treat this as permission to remove an unfamiliar system file.

Batch removal and removal history remain roadmap work. Read-only item details exist on the feature branch, not as a newly verified release: see [Check on disk, Folders and CSV](branch-features.md). Checking identity now does not make a later removal safe. The [verification page](../verification/README.md) separates mocked policy checks, a narrow disposable CI remove/undo pass, and still-open real-hardware/failure behavior.
