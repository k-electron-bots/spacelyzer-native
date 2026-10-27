# Development

## Build and test
```sh
cargo test --release -p spacelyzer-engine
cargo build --release
./target/release/spz scan <path>
./scripts/build-engine.sh && swift build -c release  # macOS only
```

The native app requires macOS 14+. The Rust engine tests also run on Linux. [Dependencies](../DEPENDENCIES.md) are deliberately limited; CI enforces the policy.

## Navigate the implementation
[Architecture](architecture.md) explains the Rust/Swift boundary. The [CLI reference](cli.md) covers the scan and verification tools. [Contributing](contributing.md) describes the working rules.
