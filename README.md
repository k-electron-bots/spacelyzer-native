# Spacelyzer Native

A native macOS disk space analyzer. SwiftUI for the Mac interface, a Rust engine for the heavy work.
Based on the intent and visual design of [k-electron/spacelyzer](https://github.com/k-electron/spacelyzer)
(read-only reference; nothing here modifies it).

## Architecture

- `engine/` Rust crate. Parallel work-stealing scanner (`getattrlistbulk` on macOS, `readdir`+`lstat`
  fallback), compact size-sorted arena tree, hard-link and firmlink de-duplication, squarified
  treemap layout, hit testing, kind breakdown. Exposed as a C ABI (`Sources/CSpacelyzer/include/spacelyzer.h`).
- `Sources/Spacelyzer` SwiftUI app: outline + treemap + kinds + largest files, Trash with confirm and undo.
- `scripts/` engine build, signing import, DMG packaging. `.github/workflows/ci.yml` builds, tests, signs, publishes.

Why it should be faster than the Swift original: one syscall per directory batch with sizes included,
no per-entry Foundation objects, one flat arena instead of a value tree, and layout/hit-testing in Rust
off the main thread. Treat that as a hypothesis until measured on a real Mac (`spz bench <path>`).

## Status

See the latest GitHub Release for the DMG. Builds are self-signed (certificate label
`Spacelyzer Self-Signed (k.electron.ai@gmail.com)`), not notarized: right-click the app, choose Open.
Full Disk Access (System Settings > Privacy & Security) is needed for a complete scan.

## Not yet done

Duplicate detection, filters bar, exclusions UI, Quick Look preview, volume accounting/purgeable breakdown,
app icon. Native visual and real-disk behaviour are validated by hand on a Mac.

## Develop

```bash
cargo test -p spacelyzer-engine
./target/release/spz scan <path>      # after cargo build --release
./scripts/build-engine.sh && swift build -c release   # macOS only
```
