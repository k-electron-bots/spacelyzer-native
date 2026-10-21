# Quick start

Four steps from download to a safe first cleanup. Images come from a shared CI Mac; names, counts and times are examples, not expected values for your Mac.

## 1. Open the app
After [installing](install.md), open Spacelyzer from Applications. The first window is the welcome screen.

![Welcome screen on first launch](../images/quickstart-welcome.png)

## 2. Scan a location
Start a scan of your disk or a folder. The app reads everything it is allowed to read and shows progress as it goes. Locations macOS protects appear in the Not scanned list with their reason; [Full Disk Access](install.md#protected-folders) widens coverage but never guarantees every protected path.

![Scan in progress](../images/quickstart-scanning.png)

## 3. Explore the result
Follow folders in the outline, compare areas in the treemap, or use Kinds and Largest for focused lists. Filters combine across every view.

![Outline and treemap after a scan](../images/quickstart-overview.png)

## 4. Review, then remove
Select an item and check it on disk: preview, full path and size, refreshed from the filesystem. If it is what you expect, Move to Trash. The removal is confirmed with the full path, and Undo is available from the removal history. Batch removal moves several reviewed items in one pass with one undo.

<!-- CAPTURE PENDING: the on-disk review capture is the one missing docs capture from run 39602481035 (10 of 11 landed; the capture flow was repaired in PR126 but has not produced a capture on Mac yet). Add docs/images/quickstart-review.png from a future verified CI capture; no stand-in. -->

Protected paths, selections outside the current filter and selections awaiting a filter result are refused. Read [space, filters and safe removal](space-and-safety.md) before deleting anything unfamiliar, and the [visual tour](tour.md) for a full walk of the views.
