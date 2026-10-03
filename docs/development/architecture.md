# Architecture

```text
SwiftUI: visible rows, rectangles and user input
        | C ABI: small calls and flat arrays
Rust engine
  scan      parallel traversal, getattrlistbulk on macOS
  tree      flat arena, hard links counted once
  filter    parallel pass and roll-up to ancestors
  outline   flattened visible rows, no row cap
  layout    squarified treemap and hit-testing index
```

Rust owns datasets, filter/sort, aggregation, layout and hit-testing. SwiftUI does not create one view per file; the outline is windowed. Scanning, filtering and derived work run off the main thread. Superseded work is canceled and publication validates its current identity before replacing state.

The previous picture may remain while new work computes; that does not authorize interaction with stale layout coordinates. Main-actor publication gates are part of correctness, not merely a performance detail.

## Native focus boundary
The current source explicitly moves plain forward Tab from the outline to the known name-filter field and unmarked backtab from its actual editor to the outline. It checks source identity, visible/enabled controls and the active key window, and verifies the destination. Refused or unexpected moves have restoration handling; failed restoration consumes the command rather than masking an unknown landing with native fallback.

Other routes retain native handling. This is a deliberate functional-boundary design, **not** proof that the old native key-view graph was repaired. Runtime acceptance, real modified-key/fallback behavior and actual IME remain separate gates in [verification](../verification/README.md).
