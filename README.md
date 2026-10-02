# Spacelyzer Native

See what is using your disk. A native macOS disk space analyzer: a SwiftUI interface on top of a Rust engine
built for speed.

![Spacelyzer scanning /Library: outline on the left, treemap on the right](docs/images/overview.png)

*A scan of `/Library` (153,203 items, 41.82 GB, scanned in 2.1 s on a shared GitHub CI Mac). Screenshots in this
README come from CI at 1024x768, not from a personal Mac.*

## What you get

| | |
|---|---|
| **Outline** | Every folder and file with size and share bars, largest first by default; a sort menu offers size (either way), name, most items and recently modified. Folders show their item count when the sidebar is wide enough (>= 400 pt). Selecting a file hidden in collapsed folders expands its ancestors. Expand one folder or all 24,903 of them. Arrow keys move, Right/Left expand and collapse, Return drills in. |
| **Treemap** | Area equals size. Colour by folder, kind or depth. Hover for a readout, click to select, double-click to drill. Tiny items fold into one labelled remainder, nothing is dropped. |
| **Kinds** | Where the space goes by file type, ranked by size. |
| **Largest** | The 200 largest files, with full paths. The header says when the list is capped. |
| **Filter** | Name, extension, kind, minimum and maximum size, and a modified-date window (7 days, 30 days, year), combined; "Clear all filters" resets them. One filter drives every view, so the outline, treemap, Kinds and Largest always describe the same files. The status bar shows the match count and total. |
| **Trash** | Move to Trash after a confirmation that shows the full path, with undo. Protected system paths are refused. Items hidden by the filter cannot be removed. |

![Kinds view](docs/images/kinds.png)

![Largest files under the filter "lib": only matching files, count in the status bar](docs/images/filtered-largest.png)

*Filter "lib": 3,463 matching files, 620 MB. The selected folder is outside the filter, so the app says so and keeps
Move to Trash off until you clear the filter or select something else.*

![No matches state in both panes](docs/images/no-matches.png)

## How it is built

```
SwiftUI (visible rows and rectangles only)
        |  C ABI: small calls, flat arrays
Rust engine
  scan      parallel, getattrlistbulk on macOS
  tree      one flat arena, hard links counted once
  filter    parallel pass + roll-up to ancestors
  outline   flattened visible rows (no cap)
  layout    squarified treemap + hit-testing index
```

- **The UI thread only draws and handles input.** Scanning, filtering, outline projection, treemap layout, the Largest
  and Kinds lists all run in Rust off the main thread, are cancelled when superseded, and publish a single result.
  The previous picture stays up until the new one is ready.
- **Rust owns the data.** Dataset, filter, sort, aggregation, layout and hit-testing live in the engine. SwiftUI never
  holds a node per file: the outline is windowed, so only the visible rows get views.
- **Honest numbers.** Sizes are allocated bytes (block-rounded), like Finder's "Size on disk". Hard-linked files count once.

## Measured so far

All from a shared GitHub Actions Mac, one folder (`/Library`, 153k items). Informational, not a benchmark. No comparison
with any other disk analyzer has been run, so no speed-up claim is made.

| What | Rust engine | Notes |
|---|---|---|
| Scan, 153k items | about 2 s wall | includes disk and OS cache effects |
| Filter by name, 153k items | 10-20 ms | 1M synthetic nodes on a 2-core Linux box: 8-28 ms |
| Treemap layout, 215 rects | 0.1 ms | plus 0.05 ms to copy into Swift |
| Outline projection, 153k rows (everything expanded) | 18 ms | rows reach the UI in 40-106 ms after the windowed outline; 16.9 s before it |

The last row is how long until the rows arrived on the main thread, not a full redraw measurement.
Engine timings are reported separately from UI and copy timings.

## In development

E2 adaptive filter surface and action accessibility labels are committed but not yet compiled or visually verified. No VoiceOver or accessibility-mode pass is claimed.

## Verification status

E1 is not signed off. Diagnostic v0.1.89 failed its UI gate (26 of 28 checks reached); it is not a recommended delivery. Zero-byte filtering fixes passed independent engine review. Run37036910990 compiled and passed date/sort/reset effect checks, but failed one count-threshold check and missed later screenshots. Run37040037876 also failed image capture; runner-owned state/capture acknowledgement is under verification. Run37043128105 passed30 checks and produced22 images, but pixel review found missing visible depth12 count evidence. E1 still needs the corrected deep-row fixture and independent signoff.

Performance research: [index-assisted early results and dua-cli inspiration](docs/EVAL-index-accelerant.md), evaluation only. No Spotlight query or progressive result list is implemented.

## Get it

Download the DMG from the [latest release](https://github.com/k-electron-bots/spacelyzer-native/releases).

The build is **self-signed, not notarized**. macOS will block the first launch. Use System Settings > Privacy &
Security > scroll to Security > **Open Anyway** (the button stays for about an hour and asks for your login password).
Do not clear quarantine flags or turn Gatekeeper off. Full Disk Access (Privacy & Security) is needed for a complete
scan of protected folders; the app reports how many locations it could not read.

## Not done yet

Duplicate detection, exclusions UI and persistence, a reviewable skipped-items list, volume accounting (purgeable
space, snapshots), Quick Look and item details, batch removal and history, size-unit toggle, Full Disk Access detection,
app icon, VoiceOver pass. Not yet tested: real Mac behaviour at other window sizes and multi-volume setups. See
[docs/ROADMAP.md](docs/ROADMAP.md) for the ordered plan.

## Develop

```bash
cargo test --release -p spacelyzer-engine           # engine tests
cargo build --release && ./target/release/spz scan <path>
./scripts/build-engine.sh && swift build -c release  # macOS only
```

Read [AGENTS.md](AGENTS.md) first: threading rules, polish bar, destructive-action rules, how CI verifies the UI.
Dependencies are `libc` and `rayon` (plus rayon's own crates), see [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md);
CI fails if anything else appears.

## License

MIT. See [LICENSE](LICENSE).
