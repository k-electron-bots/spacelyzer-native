# Dependencies

The engine uses as few crates as possible, all from the crates.io registry, all maintained by well-known projects.
`scripts/check-deps.sh` runs in CI and fails the build if `Cargo.lock` contains any crate that is not on this list,
or any package from a non-registry source (git, path, other registries). Adding a crate means adding a row here first.

| Crate | Version in Cargo.lock | Why | Maintainer / source (checked on crates.io, 2 Oct 2026) |
|---|---|---|---|
| `libc` | 0.2.189 | `getattrlistbulk`, `lstat`, `open` FFI declarations | `rust-lang/libc`, owner `rust-lang-owner`, about 1.7 billion downloads |
| `rayon` | 1.12.0 | work-stealing parallel scan, filter and layout passes | `rayon-rs/rayon`, owners `cuviper`, `nikomatsakis`, about 573 million downloads |
| `rayon-core` | 1.13.0 | rayon's runtime | same repository as rayon |
| `crossbeam-deque`, `crossbeam-epoch`, `crossbeam-utils` | 0.8.8, 0.9.21, 0.8.23 | rayon's scheduler | `crossbeam-rs/crossbeam` |
| `either` | 1.18.0 | rayon's iterator plumbing | `rayon-rs/either` |
| `arc-swap` | 1.9.2 | atomically publishes the immutable size table; readers load an `Arc` snapshot | `vorner/arc-swap`, owners `vorner` and team `github:rust-bus:maintainers`, MIT OR Apache-2.0, about 345 million downloads, 1.9.2 published 28 Jun 2026, checksum `c049c0be4daef0b145cb3555416b3b8ef5b7888a38aea1a3a155801fe7b0810b` (crates.io API, checked 3 Oct 2026). Its docs say a load can occasionally wait; we do not claim a strictly wait-free main-thread read. |
| `rustversion` | 1.0.23 | proc-macro that `arc-swap` uses at build time to pick features by compiler version | `dtolnay/rustversion`, owner `dtolnay`, about 808 million downloads, checksum `cf54715a573b99ac80df0bc206da022bcd442c974952c7b9720069370852e21f` (crates.io API, checked 3 Oct 2026) |

No Swift packages are used. The app links the Rust engine as a static library and uses only Apple frameworks.
