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

// Preserve the allocation-free ASCII hot path; use the same Unicode lowercase semantics
// as outline name sorting when either side contains non-ASCII letters. No normalization.
fn contains_ci(hay: &str, needle_lower: &str) -> bool {
    // An empty name query matches every name without scanning or allocating it.
    if needle_lower.is_empty() { return true; }
    if hay.is_ascii() && needle_lower.is_ascii() {
        let needle = needle_lower.as_bytes();
        return needle.is_empty() || hay.as_bytes().windows(needle.len()).any(|w|
            w.iter().zip(needle).all(|(h, n)| h.to_ascii_lowercase() == *n));
    }
    hay.to_lowercase().contains(needle_lower)
}

pub fn apply(tree: &Tree, f: &Filter) -> FilterResult {
    let n = tree.len();
    let text = f.text.to_lowercase();
    let ext = f.extension.trim_start_matches('.').to_lowercase();
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
                if !(if e.is_ascii() && ext.is_ascii() { e.eq_ignore_ascii_case(&ext) } else { e.to_lowercase() == ext }) {
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

/// The `n` largest matching regular files, largest first. Mirrors `Tree::largest_files` over the filtered set.
pub fn largest_files(tree: &Tree, r: &FilterResult, n: usize) -> Vec<NodeId> {
    let mut v: Vec<NodeId> = (0..tree.len() as NodeId)
        .filter(|&i| tree.kind[i as usize] == Kind::File as u8 && r.counts[i as usize] > 0)
        .collect();
    let n = n.min(v.len());
    if n == 0 {
        return vec![];
    }
    v.select_nth_unstable_by_key(n - 1, |&i| std::cmp::Reverse(r.sizes[i as usize]));
    v.truncate(n);
    v.sort_by_key(|&i| std::cmp::Reverse(r.sizes[i as usize]));
    v
}

/// Matching bytes and item counts per category (same units as `Tree::category_totals`).
pub fn category_totals(tree: &Tree, r: &FilterResult) -> [(u64, u64); crate::category::CATEGORY_COUNT] {
    let mut out = [(0u64, 0u64); crate::category::CATEGORY_COUNT];
    for i in 0..tree.len() {
        if tree.kind[i] == Kind::Directory as u8 || r.counts[i] == 0 {
            continue;
        }
        let c = tree.category[i] as usize;
        out[c].0 += r.sizes[i];
        out[c].1 += 1;
    }
    out
}

#[cfg(test)]
mod matching_parity {
    use super::contains_ci;
    fn strings(alphabet: &[&str], max_len: usize) -> Vec<String> {
        let mut all = vec![String::new()];
        let mut level = vec![String::new()];
        for _ in 0..max_len {
            let mut next = Vec::new();
            for prefix in &level { for letter in alphabet { next.push(format!("{prefix}{letter}")); } }
            all.extend(next.iter().cloned()); level = next;
        }
        all
    }
    #[test]
    fn empty_and_unicode_examples_match_lowercase_substring() {
        for hay in ["", "ASCII_FILE.TXT", "École", "ΩΜΕΓΑ", "文件", "İstanbul", "Straße", "Cafe\u{301}", "Kelvin", "kELVIN"] {
            for query in ["", "file", "ÉCOLE", "ω", "文", "i", "İ", "ß", "SS", "é", "e\u{301}", "not-here", "k", "K", "kelvin"] {
                let needle = query.to_lowercase();
                assert_eq!(contains_ci(hay, &needle), hay.to_lowercase().contains(&needle), "hay={hay:?} query={query:?}");
            }
        }
    }
    #[test]
    fn exhaustive_small_ascii_and_unicode_lowercase_parity() {
        let names = strings(&["A", "b", "É", "Ω", "文"], 4);
        let queries = strings(&["a", "B", "é", "ω", "文"], 2);
        for hay in &names { for query in &queries {
            let needle = query.to_lowercase();
            assert_eq!(contains_ci(hay, &needle), hay.to_lowercase().contains(&needle), "hay={hay:?} query={query:?}");
        } }
    }
}
