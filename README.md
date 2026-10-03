# Spacelyzer Native

See what is using your disk. A native macOS disk-space analyzer with a SwiftUI interface and a Rust engine.

![Spacelyzer outline and treemap](docs/images/overview.png)

## What it does

- Explore folders in an outline, treemap, file-type summary or list of the 200 largest files.
- Filter by name, extension, kind, size and modified date across the views.
- Scan off the UI thread, report allocated bytes and count hard-linked files once.
- Move a selected item to Trash after a full-path confirmation, with undo. Protected paths and hidden or pending-filter selections are refused.

Scans stay on your Mac. The app has no networking code.

## Try it

Requires macOS 14 or later. This is a development build, **not a release-ready app**. Exact Tab/Shift-Tab navigation is still failing verification. Real-Mac, VoiceOver, actual IME and broader accessibility testing remain open.

Development DMGs are in [GitHub releases](https://github.com/k-electron-bots/spacelyzer-native/releases). They are self-signed, not notarized. If macOS blocks the first launch, use **System Settings > Privacy & Security > Open Anyway**. Do not disable Gatekeeper or clear quarantine flags.

Grant Full Disk Access there if you want to scan protected folders. Without it, the app reports unreadable locations rather than claiming complete coverage.

The screenshot above is from a shared CI Mac, not a personal Mac. CI results and timings are scoped evidence, not a claim of exhaustive testing or a speed advantage over other apps.

## Development and status

```bash
cargo test --release -p spacelyzer-engine
cargo build --release && ./target/release/spz scan <path>
./scripts/build-engine.sh && swift build -c release  # macOS only
```

- [Roadmap and verification notes](docs/ROADMAP.md)
- [Engineering details and checkpoint history](docs/README-HISTORY.md)
- [Index-assisted early-results evaluation](docs/EVAL-index-accelerant.md) - not implemented
- [Contribution and safety rules](AGENTS.md) · [Dependencies](docs/DEPENDENCIES.md)

MIT. See [LICENSE](LICENSE).
