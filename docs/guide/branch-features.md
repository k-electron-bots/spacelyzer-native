# Folders, CSV export and Check on disk

Source guide checked October 6, 2026 against `item-inspect-engine-stack` at `9bc4143542ffcd97362ccbe92b6010a17aa54a6b`. Main at this audit was `8b7d24b7388e52b46616c1d6255d88ff80109e30`. These controls are branch-only, not a new release. Production Swift compiled at the earlier CI128 source, but test-only compilation failed before UI execution. The latest correction is source-reviewed only. No current screenshots or runtime acceptance follow. [Evidence](../verification/README.md).

## Compare large folders
Choose **Folders** beside Treemap, Kinds and Largest. Source implements up to 200 folders, ranked by total size inside. This list is **not filtered**, even when other views have an active name, extension, size or date filter. Folder sizes can overlap because an ancestor includes its descendants; do not add rows together as reclaimable space.

Loading is shown as loading, not zero folders. An error shows **Folders unavailable** with **Try Again**; an engine error requires a rescan. Changed trees drop old rows while a new list loads. These are source contracts, not pixel-tested behavior.

## Export the Largest list
**Export CSV** saves the current Largest list, capped at 200 matching files, to the location chosen in the save panel. It exports the scan's allocated sizes, not a new disk read and not a promise of space recovered by deletion. Empty, pending, stale or engine-error lists are blocked.

Columns: `rank,size_bytes_on_disk_at_scan,path,note`. Encoding is UTF-8 without a byte-order mark, with CRLF line endings and CSV quoting. Rows whose paths cannot be written exactly, or begin with a spreadsheet formula character, have an empty path and an explanatory note. In Excel use Data > From Text/CSV and select UTF-8; Excel behavior has not been tested.

If results change before writing, nothing is written. A change during a write cannot undo the file: the completion message says it contains the earlier captured list. Dismissing the save panel cancels the export; cancellation after a write starts can still leave a file. Source: `Sources/Spacelyzer/CSVExport.swift`.

## Check a selected item without changing it
Select an item, then choose **Check on disk...** in the selection bar. Source opens a read-only popover with the path, current allocated size, logical length and modification time when available. A hard-link note explains why removing one name may free no space.

The result distinguishes an item matching the scan at this moment from one replaced, gone, unreadable, lacking recorded identity, having an unaddressable name or a changed ancestor symlink. A replacement's details are labeled as a different item, not the reviewed item. Unexpected engine answers are not treated as a match.

Changing selection, tree or filter dismisses the check. **Nothing is moved or deleted. A match now does not make a later removal safe.** Trash, protected-path, permission, failure and undo gates remain separate. Source: `ItemReview.swift` and `TreemapView.swift`.

## What is still missing
Actual Mac UI captures and runtime checks for all three controls, current test-only Swift compilation, real-hardware cleanup, VoiceOver and performance acceptance. The [older visual tour](tour.md) remains useful for basic navigation but is not evidence for these controls.
