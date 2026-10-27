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

## Keyboard focus
Plain forward Tab moves from the outline to the name-filter field, and backtab from that field returns to the outline. The move checks that the controls are visible and enabled and that the window is active, and it confirms the destination. If a move is refused or lands somewhere unexpected, focus is restored. All other keys keep native handling.
