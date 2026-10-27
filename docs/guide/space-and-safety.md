# Space, filters and safe removal

## What the numbers mean
Sizes are allocated bytes, rounded by filesystem blocks, rather than logical file lengths. Hard-linked files count once. Unreadable locations and canceled/partial scans limit coverage. Totals are not a full volume-accounting model: purgeable space, APFS snapshots and clone accounting are not modeled (see [known limitations](known-limitations.md)).

## Combine filters
Name, extension, kind, minimum/maximum size and modified-date windows combine across outline, treemap, Kinds and Largest. Clear all filters resets them. The footer reports matching counts and bytes. A selected item can remain selected after it falls outside the filter, but cannot be removed in that state.

Zero-byte matching files are still matches. They remain in count-based lists even when there is no treemap area to draw.

## Review before removing
Check on disk shows an item as it is right now: preview, full path and size, refreshed from the filesystem rather than from the scan. The results can change between the scan and the review; the review says so when they do.

## Move to Trash
![The Move to Trash confirmation, naming the selected item with its full path and size](../images/trash-confirmation.png)

The screenshot shows a sample file.

Review the full-path confirmation. Protected paths, selections outside the filter and selections awaiting a filter result are refused. Undo is available for removal. Do not treat this as permission to remove an unfamiliar system file.

Batch removal moves several reviewed items in one pass, with one undo for the batch. The removal history lists everything removed this session, newest first, each with its own Put Back. A restore returns the item to its original location; rescan to refresh the numbers afterward.

![The removed sample file listed in Removal History with Put Back](../images/removal-history.png)


![The Largest list after the sample file was moved to Trash and the result alert dismissed](../images/trash-done.png)


## Export the Largest list
On the Largest tab, **Export CSV** saves the list as it was recorded at scan time to a file you choose. It reads nothing from the disk and changes no file other than that one. Columns are rank, size in bytes, path and a note. A path that cannot be written exactly (a name macOS stored in a form the scan could not represent) or that starts with a spreadsheet formula character is left blank with a note, never altered. The file is UTF-8 without a byte order mark; Excel may misread non-ASCII names when it opens the file directly, so import it with UTF-8 selected. The button is unavailable while the list is updating, out of date or empty, and nothing is written if the results change while the save panel is open.
