# Development

Read [AGENTS.md](../../AGENTS.md) before changing threading, publication or destructive-action paths.

## Build and test
```sh
cargo test --release -p spacelyzer-engine
cargo build --release
./target/release/spz scan <path>
./scripts/build-engine.sh && swift build -c release  # macOS only
```

The native app requires macOS 14+. The Rust engine tests can also run on Linux. [Dependencies](../DEPENDENCIES.md) are deliberately limited; CI enforces the policy.

## Navigate the implementation
[Architecture](architecture.md) explains the Rust/Swift boundary. [CLI reference](cli.md) covers scan/verification tools. [Performance notes](performance.md) distinguish engine time from publication and drawing.

## Validation and delivery
CI assertions and inspected images are scoped evidence. Consult [verification status](../verification/README.md), then add dated results to the [checkpoint ledger](../verification/checkpoints.md). Keep failures and missing evidence explicit. Do not append test narratives to the product README or label a source-only fix verified.

Changes are thin commits inside an epic. Coordinate substantive checkpoints rather than rerunning a full visual workflow for documentation-only changes. [Roadmap](../ROADMAP.md) owns future work, not a rolling duplicate of the CI log.
