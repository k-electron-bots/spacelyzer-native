//! Path-level comparison of two scanned trees, used by `spz verify` when backend totals disagree.
//! The comparison logic is pure map work so tests stay deterministic; `tree_size_map` is the only
//! place a `Tree` is read.

use crate::Tree;
use std::collections::{HashMap, HashSet};

/// One differing path in a comparison of two trees: which side(s) had it and the cumulative
/// subtree bytes each side recorded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffEntry {
    OnlyInA { path: String, bytes: u64 },
    OnlyInB { path: String, bytes: u64 },
    SizeDiffers { path: String, a_bytes: u64, b_bytes: u64 },
}

impl DiffEntry {
    pub fn path(&self) -> &str {
        match self {
            DiffEntry::OnlyInA { path, .. } => path,
            DiffEntry::OnlyInB { path, .. } => path,
            DiffEntry::SizeDiffers { path, .. } => path,
        }
    }
}

/// All paths that differ between two trees, sorted by path (ancestors of a differing path
/// usually differ too, because their cumulative size includes the descendant).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PathDiff {
    pub entries: Vec<DiffEntry>,
}

impl PathDiff {
    pub fn len(&self) -> usize {
        self.entries.len()
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
    /// Entries with no differing descendant: the leaf-most differences that explain the rest.
    /// A directory whose size differs only because something under it differs is dropped.
    pub fn leaf_most(&self) -> Vec<&DiffEntry> {
        let mut has_differing_descendant: HashSet<&str> = HashSet::new();
        for e in &self.entries {
            let mut cur = e.path();
            while let Some(i) = cur.rfind('/') {
                cur = &cur[..i];
                has_differing_descendant.insert(cur);
            }
        }
        self.entries.iter().filter(|e| !has_differing_descendant.contains(e.path())).collect()
    }
    /// Count of exact paths that differ in both diffs.
    pub fn overlap(&self, other: &PathDiff) -> usize {
        let a: HashSet<&str> = self.entries.iter().map(|e| e.path()).collect();
        other.entries.iter().filter(|e| a.contains(e.path())).count()
    }
}

/// Compare two path -> cumulative-bytes maps. Result entries are sorted by path.
pub fn diff_maps(a: &HashMap<String, u64>, b: &HashMap<String, u64>) -> PathDiff {
    let mut entries = Vec::new();
    for (p, &ba) in a {
        match b.get(p) {
            None => entries.push(DiffEntry::OnlyInA { path: p.clone(), bytes: ba }),
            Some(&bb) if bb != ba => entries.push(DiffEntry::SizeDiffers { path: p.clone(), a_bytes: ba, b_bytes: bb }),
            _ => {}
        }
    }
    for (p, &bb) in b {
        if !a.contains_key(p) {
            entries.push(DiffEntry::OnlyInB { path: p.clone(), bytes: bb });
        }
    }
    entries.sort_by(|x, y| x.path().cmp(y.path()));
    PathDiff { entries }
}

/// Absolute path -> cumulative subtree bytes for every node, root included.
pub fn tree_size_map(tree: &Tree) -> HashMap<String, u64> {
    (0..tree.len() as u32).map(|id| (tree.path(id), tree.size(id))).collect()
}
