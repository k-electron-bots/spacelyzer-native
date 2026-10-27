# Spacelyzer Native

See what is using your disk. A native macOS disk-space analyzer with a SwiftUI interface and a Rust engine.

![Outline and treemap showing a scan of Library](docs/images/overview.png)

## Explore before you remove

![Kinds view grouping files by type with counts and allocated sizes](docs/images/readme-kinds.png)

- Follow folders in the outline or compare their size in the treemap.
- Switch to Kinds for a file-type breakdown, or Largest for the 200 largest matching files.
- Combine name, extension, kind, size and modified-date filters across outline, treemap, Kinds and Largest. The Folders list is unfiltered.

![On-disk review popover: preview, sizes, and the read-only safety note](docs/images/readme-review.png)

- Check a scanned item on disk before deciding: preview, full path, size, then Move to Trash with Undo.
- Move several reviewed items at once, and put any of them back from the removal history.
- Review duplicate groups and move extra copies to the Trash.
- Export the Largest list as a CSV file (the save-panel export was exercised on a CI Mac, see Install below).
- Skip chosen locations with exclusions; the Not scanned list shows what was skipped and why.

![Removal History showing a sample file moved to Trash and its Put Back action](docs/images/removal-history.png)

Removal History lists this session's removals. This compact-window capture is from
[run 40050466225](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40050466225)
on a shared CI Mac with disposable sample files. It shows the history, not proof
that Put Back was exercised in this capture. Wide-window history and the automated
Not scanned identity check still failed in that run. Later runs fixed this: in run 40218097822 (October 25, all steps and the evidence gate green) the wide-window history was captured as two on-display captures of a 1280-wide window (not a full-width image); screenshots still need human pixel review. [Current evidence](docs/verification/2026-10-23-combined-verification.md).

Sizes describe allocated disk space, with hard links counted once. Scans stay on your Mac; the app has no networking code.

## Install

Requires macOS 14 or later. Spacelyzer 0.9.x is early software. The DMG is self-signed and not notarized, and validation of the public candidate build is still pending. On a CI Mac (run [40498184629](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40498184629), development build 0.1.10) the demo UI assertions, the ordering checks, the DMG install checks, a real save-panel CSV export (header, order, encoding and a cancel path) and a real mounted-volume test passed. A scripted Cmd-O, Escape and Tab/Shift-Tab check also passed; that is keyboard focus only and does not verify actual IME text composition, which is still unverified. Not yet done: a manual 1M-item test, native Mac verification of burst coalescing, and an explanation for a possible slowdown reading some fields. Details: [verification status](docs/verification/README.md). VoiceOver speech is untested - the accessibility features are built, but VoiceOver is not a v1 gate.

1. Download the DMG and open it.
2. Drag Spacelyzer onto Applications.
3. Open it once, then approve it in **System Settings > Privacy & Security > Open Anyway**.

[Install and permissions](docs/guide/install.md) walks through each step with pictures, then [take the visual tour](docs/guide/tour.md).

The images show a shared CI Mac, not a personal Mac. They illustrate the interface, not exhaustive validation or a speed comparison.

## Find the right documentation

| You want to... | Start here |
|---|---|
| Learn the app | [Quick start](docs/guide/quick-start.md) · [Visual tour](docs/guide/tour.md) · [Space, filters and Trash](docs/guide/space-and-safety.md) |
| Build or change it | [Development](docs/development/README.md) · [Architecture](docs/development/architecture.md) · [Engine CLI](docs/development/cli.md) |
| Check what is actually verified | [Verification status](docs/verification/README.md) |
| Understand priorities | [Roadmap](docs/ROADMAP.md) |
| Browse all guides and references | [Documentation index](docs/README.md) |

MIT. See [LICENSE](LICENSE).
