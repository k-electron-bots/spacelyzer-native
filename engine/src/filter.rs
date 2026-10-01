//! Filtering a finished scan. One parallel pass decides which files match, then a reverse
//! pass over the arena (children always sit after their parent) rolls matched sizes and
//! counts up to every ancestor. The result drives both the layout and the outline, so the
//! two views cannot disagree (FR-042).

use crate::category::Category;
use crate::tree::{Kind, NodeId, Tree};
use rayon::prelude::*;

#[derive(Clone, Debug, Default)]
pub struct Filter {
    /// Case-insensitive substring of the file name. Empty = any.
    pub text: String,
    /// Bitmask over `Category as u8`; 0 = any.
    pub category_mask: u32,
    /// Extension without dot, case-insensitive. Empty = any.
    pub extension: String,
    pub min_size: Option<u64>,
    pub max_size: Option<u64>,
    /// Modified time bounds, unix seconds, inclusive.
    pub modified_from: Option<i64>,
    pub modified_to: Option<i64>,
}

impl Filter {
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
            && self.category_mask == 0
            && self.extension.is_empty()
            && self.min_size.is_none()
            && self.max_size.is_none()
            && self.modified_from.is_none()
            && self.modified_to.is_none()
    }
}

pub struct FilterResult {
    /// Matched bytes per node (own for files, rolled up for directories).
    pub sizes: Vec<u64>,
    /// Matched file count per node.
    pub counts: Vec<u32>,
    pub total_bytes: u64,
    pub total_count: u64,
}

fn contains_ci(hay: &str, needle_lower: &[u8]) -> bool {
    if needle_lower.is_empty() {
        return true;
    }
    let h = hay.as_bytes();
    if h.len() < needle_lower.len() {
        return false;
    }
    'outer: for i in 0..=h.len() - needle_lower.len() {
        for (j, &n) in needle_lower.iter().enumerate() {
            if h[i + j].to_ascii_lowercase() != n {
                continue 'outer;
            }
        }
        return true;
    }
    false
}

pub fn apply(tree: &Tree, f: &Filter) -> FilterResult {
    let n = tree.len();
    let text = f.text.to_ascii_lowercase().into_bytes();
    let ext = f.extension.trim_start_matches('.').to_ascii_lowercase();
    let min = f.min_size.unwrap_or(0);
    let max = f.max_size.unwrap_or(u64::MAX);
    let (mf, mt) = (f.modified_from.unwrap_or(i64::MIN), f.modified_to.unwrap_or(i64::MAX));

    // Leaf pass, parallel. Directories contribute only through their descendants.
    let leaf: Vec<(u64, u32)> = (0..n)
        .into_par_iter()
        .map(|i| {
            let kind = tree.kind[i];
            if kind == Kind::Directory as u8 {
                return (0, 0);
            }
            // A package or file counts by its own bytes; a package is one item.
            let size = tree.own_bytes(i as NodeId);
            if size < min || size > max {
                return (0, 0);
            }
            let m = tree.mtime[i];
            if m < mf || m > mt {
                return (0, 0);
            }
            if f.category_mask != 0 && f.category_mask & (1u32 << tree.category[i]) == 0 {
                return (0, 0);
            }
            let name: &str = &tree.names[i];
            if !ext.is_empty() {
                let e = match name.rfind('.') {
                    Some(p) if p > 0 => &name[p + 1..],
                    _ => "",
                };
                if !e.eq_ignore_ascii_case(&ext) {
                    return (0, 0);
                }
            }
            if !contains_ci(name, &text) {
                return (0, 0);
            }
            (size, 1)
        })
        .collect();

    let mut sizes: Vec<u64> = leaf.iter().map(|l| l.0).collect();
    let mut counts: Vec<u32> = leaf.iter().map(|l| l.1).collect();
    // Children come after parents in the arena, so a reverse sweep rolls everything up.
    for i in (1..n).rev() {
        let p = tree.parent[i] as usize;
        if p < n {
            sizes[p] += sizes[i];
            counts[p] += counts[i];
        }
    }
    FilterResult { total_bytes: sizes[0], total_count: counts[0] as u64, sizes, counts }
}

/// Convenience: category mask from categories.
pub fn mask(cats: &[Category]) -> u32 {
    cats.iter().fold(0, |m, c| m | (1u32 << (*c as u8)))
}
