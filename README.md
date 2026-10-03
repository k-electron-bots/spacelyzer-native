# Spacelyzer Native

See what is using your disk. A native macOS disk-space analyzer with a SwiftUI interface and a Rust engine.

![Outline and treemap showing a scan of Library](docs/images/overview.png)

## Explore before you remove

- Follow folders in the outline or compare their size in the treemap.
- Switch to Kinds for a file-type breakdown, or Largest for the 200 largest matching files.
- Combine name, extension, kind, size and modified-date filters across every view.
- Review the full path before moving an item to Trash. Hidden, protected and pending-filter selections are refused; removal has undo.

Sizes describe allocated disk space, with hard links counted once. Scans stay on your Mac; the app has no networking code.

## Try the development build

Requires macOS 14 or later. [Development DMGs](https://github.com/k-electron-bots/spacelyzer-native/releases) are self-signed, not notarized. This is **not a release-ready app**. Keyboard focus verification is under repair; real-Mac, VoiceOver and actual IME testing remain open.

[Install and permissions](docs/guide/install.md) explains first launch and Full Disk Access without weakening macOS security. [Take the visual tour](docs/guide/tour.md) to see the views, filters and safe-removal workflow.

The images show a shared CI Mac, not a personal Mac. They illustrate the interface, not exhaustive validation or a speed comparison.

## Find the right documentation

| You want to... | Start here |
|---|---|
| Learn the app | [Visual tour](docs/guide/tour.md) · [Space, filters and Trash](docs/guide/space-and-safety.md) |
| Build or change it | [Development](docs/development/README.md) · [Architecture](docs/development/architecture.md) · [Engine CLI](docs/development/cli.md) |
| Check what is actually verified | [Verification status](docs/verification/README.md) |
| Understand priorities | [Roadmap](docs/ROADMAP.md) |
| Browse all guides and references | [Documentation index](docs/README.md) |

MIT. See [LICENSE](LICENSE).
