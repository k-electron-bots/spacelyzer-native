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
- Export the Largest list as a CSV file (built, awaiting Mac verification).
- Skip chosen locations with exclusions; the Not scanned list shows what was skipped and why.

Sizes describe allocated disk space, with hard links counted once. Scans stay on your Mac; the app has no networking code.

## Install

Requires macOS 14 or later. [Development DMGs](https://github.com/k-electron-bots/spacelyzer-native/releases) are self-signed, not notarized. This is **not a release-ready app**. Keyboard focus verification is under repair; real-Mac, VoiceOver and actual IME testing remain open.

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
