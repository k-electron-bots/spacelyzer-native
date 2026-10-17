# Space, filters and safe removal

## What the numbers mean
Sizes are allocated bytes, rounded by filesystem blocks, rather than logical file lengths. Hard-linked files count once. Unreadable locations and canceled/partial scans limit coverage. Totals are not yet a full volume-accounting model: purgeable space, APFS snapshots and clone accounting remain open work.

## Combine filters
Name, extension, kind, minimum/maximum size and modified-date windows combine across outline, treemap, Kinds and Largest. Clear all filters resets them. The footer reports matching counts and bytes. A selected item can remain selected after it falls outside the filter, but cannot be removed in that state.

Zero-byte matching files are still matches. They remain in count-based lists even when there is no treemap area to draw.

## Review before removing
Check on disk shows an item as it is right now: preview, full path and size, refreshed from the filesystem rather than from the scan. The results can change between the scan and the review; the review says so when they do.

## Move to Trash
Review the full-path confirmation. Protected paths, selections outside the filter and selections awaiting a filter result are refused. Undo is available for removal. Do not treat this as permission to remove an unfamiliar system file.

Batch removal moves several reviewed items in one pass, with one undo for the batch. The removal history lists everything removed this session, newest first, each with its own Put Back. A restore returns the item to its original location; rescan to refresh the numbers afterward.

The [verification page](../verification/README.md) separates mocked policy checks, a narrow disposable CI remove/undo pass, and still-open real-hardware/failure behavior. Batch removal, removal history and the on-disk review are built and awaiting the same Mac verification.
