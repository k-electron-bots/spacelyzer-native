# Visual tour

These images were captured at 1024x768 on a shared GitHub CI Mac. Their file names, counts and times are example scan results, not expected values for your Mac. Captured October 1, 2026, they show the earlier three-tab interface, not the current `item-inspect-engine-stack` branch. They do not show Folders, Export CSV or Check on disk. Current screenshots for those controls are pending a separately permitted Mac UI run; none are simulated here. See the [branch feature guide](branch-features.md) and [verification](../verification/README.md).

## Follow folders or compare areas
![Outline beside the treemap](../images/overview.png)

The outline shows folders and files with size bars. Expand a folder to follow its children. Selection reveals ancestors when needed. Arrow keys navigate; Right/Left expand and collapse; Return drills in. Later checkpoints accepted specific named focus boundaries; broader navigation, VoiceOver and real-system input remain unproven.

The treemap uses area for allocated size. Choose folder, kind or depth coloring. Hover for a readout, click to select, or double-click to drill in. Tiny regions combine into a labeled remainder. Zero-byte matches have no drawable area: use the outline or Largest to inspect them.

## See the file-type breakdown
![Kinds view with counts and allocated sizes](../images/kinds.png)

Kinds groups matching files by type. This helps distinguish, for example, code from archives without leaving the selected scan.

## Find large files within a filter
![Largest view filtered by lib, with hidden selection warning](../images/filtered-largest.png)

Largest lists the 200 largest matching files and their paths. The header identifies the cap. A name filter of `lib` changes outline, treemap, Kinds and Largest. The branch-only Folders list is unfiltered and is not shown in this historical capture. The orange selection warning means the selected item is outside the filter; Move to Trash stays unavailable until you clear the filter or select a matching item.

## Understand an empty view
![Earlier CI interface: no matches in the outline and Largest](../images/no-matches.png)

No matches means the current filter excludes the files under the displayed root. It is distinct from matching files with zero drawable allocated space. Clear filters or inspect the outline/Largest rather than assuming the scan contains nothing.

Read [space, filters and safe removal](space-and-safety.md) before deleting files.
