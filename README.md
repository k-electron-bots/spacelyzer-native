# Spacelyzer Native

See what is using your disk. A native macOS disk-space analyzer with a SwiftUI interface and a Rust engine.

![Earlier CI interface: outline and treemap showing a scan of Library](docs/images/overview.png)

*October 1 CI capture of the earlier three-tab interface, not the latest feature branch. [Version and verification status](docs/verification/README.md).*

## Explore before you remove

- Follow folders in the outline or compare their size in the treemap.
- Switch to Kinds for a file-type breakdown, or Largest for the 200 largest matching files.
- Combine name, extension, kind, size and modified-date filters across outline, treemap, Kinds and Largest. The feature-branch Folders list is unfiltered.
- Review the full path before moving an item to Trash. Hidden, protected and pending-filter selections are refused; removal has undo.

Sizes describe allocated disk space, with hard links counted once. Scans stay on your Mac; the app has no networking code.

## Try the development build

Requires macOS 14 or later. [Development DMGs](https://github.com/k-electron-bots/spacelyzer-native/releases) are self-signed, not notarized. This is **not a release-ready app**. Current branch UI and test-only Swift compilation are unverified after CI128. Real-Mac, VoiceOver and actual IME testing remain open.

[Install and permissions](docs/guide/install.md) explains first launch and Full Disk Access without weakening macOS security. [Take the visual tour](docs/guide/tour.md) to see the views, filters and safe-removal workflow.

The images show a shared CI Mac, not a personal Mac. They illustrate the interface, not exhaustive validation or a speed comparison.

## Work in progress, not a new release

The `item-inspect-engine-stack` branch adds Folders, Largest CSV export and read-only Check on disk. These are source features, not a shipped or UI-verified update. [Branch feature guide](docs/guide/branch-features.md) explains their limits. CI128 built the production app and packaged a DMG, but failed test-only compilation before the UI ran; no artifact or new release was delivered.

## Find the right documentation

| You want to... | Start here |
|---|---|
| Learn the app | [Visual tour](docs/guide/tour.md) · [Space, filters and Trash](docs/guide/space-and-safety.md) |
| Build or change it | [Development](docs/development/README.md) · [Architecture](docs/development/architecture.md) · [Engine CLI](docs/development/cli.md) |
| Check what is actually verified | [Verification status](docs/verification/README.md) |
| Understand priorities | [Roadmap](docs/ROADMAP.md) |
| Browse all guides and references | [Documentation index](docs/README.md) |

MIT. See [LICENSE](LICENSE).
