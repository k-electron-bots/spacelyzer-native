# FAQ

**What is Spacelyzer?**
A native macOS disk analyzer. It scans a folder or volume and shows where the space went: an outline you can sort, a treemap, a file-kind breakdown and the largest files. A Rust engine does every computation over the dataset; the interface is SwiftUI.

**Which macOS do I need?**
macOS 14 or later.

**Is Spacelyzer free?**
Yes. It is open source under the MIT license. Development DMGs are published on [GitHub releases](https://github.com/k-electron-bots/spacelyzer-native/releases). Builds are in development; [verification status](../verification/README.md) says what has and has not been checked.

**Does it connect to the internet?**
No. The app contains no networking code. Scanning, filtering and removal all run locally.

**Why does macOS warn me the first time I open it?**
Builds are self-signed, not notarized, so Gatekeeper blocks the first launch. The supported way past it takes under a minute: see [Install and permissions](install.md).

**What do the sizes mean?**
Sizes are allocated bytes (filesystem blocks), not logical file lengths, so a small file can take more space than its contents suggest. Hard-linked files count once.

**Why is the total smaller than what Finder shows?**
Three reasons, all by design or open work: locations the app cannot read are skipped and their bytes are in no total; a canceled or partial scan covers less; purgeable space, APFS snapshots and clone accounting are not modeled yet. [Space, filters and safe removal](space-and-safety.md) has the details.

**Does Spacelyzer delete files permanently?**
No. Removal moves items to the Trash, always after a confirmation that shows the full path. Every removal this session is listed in the removal history with its own Put Back, and a batch removal has one undo for the batch.

**Why is removal unavailable for my selection?**
The app refuses removal when the selection is outside the current filter, a filter result is still pending, the on-screen numbers are out of date, the path is protected, or the engine reported an internal error. Rescan and reselect; if the path is protected, remove it from outside the app.

**Where are the keyboard shortcuts and menus?**
See the [visual tour](tour.md) for the interface.
