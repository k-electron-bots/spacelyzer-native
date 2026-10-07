//! Spacelyzer engine: scan a directory tree into a compact arena, lay it out as a
//! squarified treemap, and answer hit-test / breakdown queries. The Swift app talks to
//! this crate through the C ABI in `ffi`.

pub mod category;
pub mod events;
pub mod filter;
pub mod outline;
pub mod ffi;
pub mod layout;
pub mod scan;
pub mod tree;

pub use category::Category;
pub use filter::{apply as apply_filter, Filter, FilterResult};
pub use layout::{layout, layout_with, hit_test, LayoutOptions, Rect};
pub use tree::{SkipReason, Skipped};
pub use events::{EventKind, PreviewCollector, PreviewEvents, PreviewSnapshot, ScanEvent, CHANNEL_BOUND, PREVIEW_INTERVAL};
pub use scan::{scan, scan_with_events, ScanOptions, ScanProgress};
pub use tree::{Kind, NodeId, Tree};

#[cfg(target_os = "macos")]
pub(crate) mod scan_macos;
