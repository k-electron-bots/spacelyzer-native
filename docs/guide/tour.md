# Visual tour

The screenshots use sample data. Names, counts and times are examples, not what you will see on your Mac.

## Follow folders or compare areas
![Outline beside the treemap](../images/overview.png)

The outline shows folders and files with size bars. Expand a folder to follow its children. Selection reveals ancestors when needed. Arrow keys navigate; Right/Left expand and collapse; Return drills in.

The treemap uses area for allocated size. Choose folder, kind or depth coloring. Hover for a readout, click to select, or double-click to drill in. Tiny regions combine into a labeled remainder. Zero-byte matches have no drawable area: use the outline or Largest to inspect them.

## See the file-type breakdown
![Kinds view with counts and allocated sizes](../images/kinds.png)

Kinds groups matching files by type. This helps distinguish, for example, code from archives without leaving the selected scan.

## Find large files within a filter
![Largest view filtered by pdf, with hidden selection warning](../images/filtered-largest.png)

Largest lists the 200 largest matching files and their paths. The header identifies the cap. A name filter of `pdf` changes every view. The orange selection warning means the selected item is outside the filter; Move to Trash stays unavailable until you clear the filter or select a matching item.

## Understand an empty view
![No matches in the outline and treemap](../images/no-matches.png)

No matches means the current filter excludes the files under the displayed root. It is distinct from matching files with zero drawable allocated space. Clear filters or inspect the outline/Largest rather than assuming the scan contains nothing.

Read [space, filters and safe removal](space-and-safety.md) before deleting files.


## Review duplicates without assuming every byte is recoverable
![Duplicates review listing groups and per-file actions](../images/duplicates.png)

The review groups matching content and shows per-file or keep-one actions.
Allocated bytes are not necessarily reclaimable space. The screenshot's warning
explains limits for sparse, compressed and some clone copies. 

## Choose exclusions for the next scan
![Exclusions dialog with a path field and an explanation of rescan behavior](../images/exclusions.png)

Exclusions apply when you rescan. Editing this list does not change the numbers
already on screen. An excluded path the scan never saw is not proof that it is
absent.

## Review the exact file, then find it in Removal History
![Move to Trash confirmation naming Backup 2025.zip and its full path](../images/trash-confirmation.png)

Check the full path before confirming. This is a sample file. The app refuses protected, stale or filtered-out selections.

![Removed sample file shown in the history popover with Put Back](../images/removal-history.png)

Removal History opens from the toolbar (under the overflow menu in a narrow window). Each entry has its own Put Back.
