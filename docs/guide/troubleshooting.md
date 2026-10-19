# Troubleshooting

Each entry is a failure mode seen in the app's code or logs: the symptom, what it means, and what to do.

## macOS blocks the first launch
**Symptom:** a warning says the app cannot be opened, or that Apple cannot check it for malicious software.
**Meaning:** the build is self-signed, not notarized, so Gatekeeper stops the first open.
**Fix:** open **System Settings > Privacy & Security** and choose **Open Anyway** for Spacelyzer, as in [Install and permissions](install.md). Do not disable Gatekeeper or clear quarantine flags.

## A banner asks for Full Disk Access
**Symptom:** a banner at the top of the window offers Full Disk Access.
**Meaning:** without it, macOS hides protected locations from the scan.
**Fix:** grant Spacelyzer Full Disk Access in **System Settings > Privacy & Security**, then relaunch and rescan. Some locations stay unreadable even then.

## The footer says locations were not scanned
**Symptom:** the status bar reports a count of unreadable locations after a scan.
**Meaning:** those entries were permission-denied or otherwise unreadable. They are listed as skipped; their bytes are in no total.
**Fix:** click the underlined "not readable" count in the footer for the exact list (VoiceOver: the "Show locations not scanned" action). Full Disk Access plus a relaunch covers more of them. Treat a scan with skipped locations as a partial view of the disk.

## The numbers look wrong, or the app reports an internal engine error
**Symptom:** a message says the engine reported an internal error and numbers on screen may be wrong.
**Meaning:** the app stops trusting the current tree and disables removal.
**Fix:** rescan. Removal stays disabled until you do.

## A removal skipped some items
**Symptom:** the summary reads "Moved N of M items to the Trash" and names skipped items.
**Meaning:** each skipped item carries its reason: the results changed since the scan, the item is outside the current filter, the path is protected, its size could not be verified, the engine reported an internal error, or the batch was canceled.
**Fix:** rescan, reselect, and try again. A protected path cannot be removed from inside the app.

## Put Back did not restore an item
**Symptom:** a restore from the removal history fails.
**Meaning:** the item could not be moved back to its original location, for example because something now occupies that path.
**Fix:** the item is still in the Trash. Open the Trash in Finder and use **Put Back**, or drag the item where you want it.

## A scan is taking a while
**Meaning:** scanning runs off the main thread, so the interface stays responsive while a large folder is read.
**Reference:** historical, informational measurements (not a benchmark) are in [performance notes](../development/performance.md): a 153k-item folder scanned in about 2 seconds on a shared CI Mac.
