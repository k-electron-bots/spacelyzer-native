//! Spacelyzer engine: scan a directory tree into a compact arena, lay it out as a
//! squarified treemap, and answer hit-test / breakdown queries. The Swift app talks to
//! this crate through the C ABI in `ffi`.

pub mod category;
pub mod ffi;
pub mod layout;
pub mod scan;
pub mod tree;

pub use category::Category;
pub use layout::{layout, hit_test, LayoutOptions, Rect};
pub use tree::{SkipReason, Skipped};
pub use scan::{scan, ScanOptions, ScanProgress};
pub use tree::{Kind, NodeId, Tree};

#[cfg(target_os = "macos")]
pub(crate) mod scan_macos;
