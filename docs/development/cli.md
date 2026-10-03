# Engine CLI reference

Developer tool, not the desktop app's user interface. The reference follows `engine/src/bin/spz.rs`.

## Synopsis
```text
spz scan <path>
spz verify <path>
spz bench <path> [runs]
spz filterbench <path>
spz filterbench synthetic [nodes]
```

## Commands
| Command | Behavior |
|---|---|
| `scan` | Print totals, skipped count, scan time, up to ten root children, and a treemap-layout timing. |
| `verify` | Compare default and portable scan totals. On macOS this compares backend paths; a changing volume can produce a mismatch. Use a quiet disposable fixture. |
| `bench` | Repeated scans and wall times; default 5 runs. Disk/OS caches affect results. |
| `filterbench` | Run built-in name, kind, extension, size and combined filters, with layout timings. `synthetic` defaults to 1,000,000 nodes. |

## Examples
```sh
cargo build --release
./target/release/spz scan /path/to/fixture
./target/release/spz verify /path/to/quiet-fixture
./target/release/spz bench /path/to/fixture 3
./target/release/spz filterbench synthetic 1000000
```

## Exit behavior and limits
Missing/unknown commands exit 2. A backend-total mismatch exits 1. Scan failures currently panic; the tool does not provide a stable structured-error interface. A parse failure for optional run/node counts uses the default. `filterbench` exists in source even though the short usage line only names scan/verify/bench.

Times are diagnostic measurements, not promises of app responsiveness or comparisons with other products.
