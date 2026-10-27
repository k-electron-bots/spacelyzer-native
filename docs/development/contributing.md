# Contributing

Spacelyzer is a native macOS app with a Rust engine. Contributions are welcome. The bar below keeps the app fast, polished and honest about what it does.

## Principles
- The main thread only renders and handles input. Anything that scales with the dataset runs in Rust off the main thread and publishes one result.
- Removal is Move to Trash only, always after a confirmation that shows the full path.
- Docs and release notes say only what was measured or looked at.

## Build and test
```sh
cargo test --release -p spacelyzer-engine
cargo build --release
./target/release/spz scan <path>
./scripts/build-engine.sh && swift build -c release  # macOS only
```
The native app requires macOS 14+. The Rust engine tests also run on Linux. [Development](README.md) has the map of the implementation.

## Shape of a change
- One concern per commit, in dependency order. Do not bundle architecture, filters, visual fixes and packaging.
- Fix the cause, not the symptom.
- Write the failing check first when you can: a Rust test, or a UI assertion in the demo run.
- A visual change is not done until you have looked at the pixels at the sizes that matter.

## Dependencies
Dependencies are deliberately limited. Add a row to [docs/DEPENDENCIES.md](../DEPENDENCIES.md) first; `scripts/check-deps.sh` enforces the allowlist. Only widely used crates from crates.io with a named maintainer; no git or path dependencies.

## What CI checks
The workflow builds, tests, signs (self-signed), runs a scripted demo that posts real events to the app window, takes screenshots and runs UI assertions. Any failed assertion fails the build.
