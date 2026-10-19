# Quick start

Four steps from download to a safe first cleanup. Images come from a shared CI Mac; names, counts and times are examples, not expected values for your Mac.

## 1. Open the app
After [installing](install.md), open Spacelyzer from Applications. The first window is the welcome screen.

<!-- CAPTURE: docs/images/quickstart-welcome.png <- CI artifact screenshot-welcome-1280x800.png -->
![Welcome screen on first launch](../images/quickstart-welcome.png)

## 2. Scan a location
Start a scan of your disk or a folder. The app reads everything it is allowed to read and shows progress as it goes. Locations macOS protects appear in the Not scanned list with their reason; [Full Disk Access](install.md#protected-folders) widens coverage but never guarantees every protected path.

<!-- CAPTURE: docs/images/quickstart-scanning.png <- CI artifact screenshot-scanning.png -->
![Scan in progress](../images/quickstart-scanning.png)

## 3. Explore the result
Follow folders in the outline, compare areas in the treemap, or use Kinds and Largest for focused lists. Filters combine across every view.

<!-- CAPTURE: docs/images/quickstart-overview.png <- refresh docs/images/overview.png source, reused here -->
![Outline and treemap after a scan](../images/quickstart-overview.png)

## 4. Review, then remove
Select an item and check it on disk: preview, full path and size, refreshed from the filesystem. If it is what you expect, Move to Trash. The removal is confirmed with the full path, and Undo is available from the removal history. Batch removal moves several reviewed items in one pass with one undo.

<!-- CAPTURE: docs/images/quickstart-review.png <- CI demo capture of the on-disk review panel -->
![On-disk review before removal](../images/quickstart-review.png)

Protected paths, selections outside the current filter and selections awaiting a filter result are refused. Read [space, filters and safe removal](space-and-safety.md) before deleting anything unfamiliar, and the [visual tour](tour.md) for a full walk of the views.
