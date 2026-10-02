//! Flattened outline projection: the visible rows of an expandable tree, computed in Rust so
//! the UI never walks or materialises the dataset. Rows are (node, depth) in display order.
use crate::tree::{NodeId, Tree};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Row {
    pub node: NodeId,
    pub depth: u32,
}

/// Children of `root` (depth 0), then recursively the children of every node in `expanded`.
/// `sizes` (from a filter) hides nodes with zero filtered size. Nothing is capped.
pub fn visible_rows(tree: &Tree, root: NodeId, expanded: &HashSet<NodeId>, sizes: Option<&[u64]>) -> Vec<Row> {
    let mut out = Vec::new();
    let mut stack: Vec<(std::ops::Range<NodeId>, u32)> = vec![(tree.children(root), 0)];
    while let Some((range, depth)) = stack.last_mut() {
        let Some(id) = range.next() else {
            stack.pop();
            continue;
        };
        if let Some(s) = sizes {
            if s[id as usize] == 0 {
                continue;
            }
        }
        let d = *depth;
        out.push(Row { node: id, depth: d });
        if expanded.contains(&id) && tree.child_count(id) > 0 {
            stack.push((tree.children(id), d + 1));
        }
    }
    out
}

/// Sibling ordering for the outline. `SizeDesc` is the tree's native order and needs no sort.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortMode {
    SizeDesc,
    SizeAsc,
    NameAsc,
    ItemsDesc,
    ModifiedDesc,
}

impl SortMode {
    pub fn from_u32(v: u32) -> SortMode {
        match v {
            1 => SortMode::SizeAsc,
            2 => SortMode::NameAsc,
            3 => SortMode::ItemsDesc,
            4 => SortMode::ModifiedDesc,
            _ => SortMode::SizeDesc,
        }
    }
}

fn ordered_children(tree: &Tree, id: NodeId, mode: SortMode, sizes: Option<&[u64]>) -> Vec<NodeId> {
    let mut v: Vec<NodeId> = tree.children(id).collect();
    let key_size = |n: NodeId| sizes.map(|s| s[n as usize]).unwrap_or_else(|| tree.size(n));
    match mode {
        SortMode::SizeDesc => {
            if sizes.is_some() {
                v.sort_by_key(|&n| std::cmp::Reverse(key_size(n)));
            }
        }
        SortMode::SizeAsc => v.sort_by_key(|&n| key_size(n)),
        SortMode::NameAsc => v.sort_by_cached_key(|&n| tree.name(n).to_lowercase()),
        SortMode::ItemsDesc => v.sort_by_key(|&n| std::cmp::Reverse(tree.child_count(n))),
        SortMode::ModifiedDesc => v.sort_by_key(|&n| std::cmp::Reverse(tree.mtime(n))),
    }
    v
}

/// Like `visible_rows`, with a chosen sibling order. Ties keep the native (size-descending) order
/// because the sorts are stable. Nothing is capped.
pub fn visible_rows_sorted(tree: &Tree, root: NodeId, expanded: &HashSet<NodeId>, sizes: Option<&[u64]>, mode: SortMode) -> Vec<Row> {
    let mut out = Vec::new();
    let mut stack: Vec<(std::vec::IntoIter<NodeId>, u32)> = vec![(ordered_children(tree, root, mode, sizes).into_iter(), 0)];
    while let Some((it, depth)) = stack.last_mut() {
        let Some(id) = it.next() else {
            stack.pop();
            continue;
        };
        if let Some(s) = sizes {
            if s[id as usize] == 0 {
                continue;
            }
        }
        let d = *depth;
        out.push(Row { node: id, depth: d });
        if expanded.contains(&id) && tree.child_count(id) > 0 {
            stack.push((ordered_children(tree, id, mode, sizes).into_iter(), d + 1));
        }
    }
    out
}
