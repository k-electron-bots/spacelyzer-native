//! Flattened outline projection: the visible rows of an expandable tree, computed in Rust so
//! the UI never walks or materialises the dataset. Rows are (node, depth) in display order.
use crate::filter::FilterResult;
use crate::tree::{NodeId, Tree};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Row {
    pub node: NodeId,
    pub depth: u32,
}

/// Children of `root` (depth 0), then recursively the children of every node in `expanded`.
/// A filter hides nodes with no matching files (by match count, so zero-byte matches stay visible). Nothing is capped.
pub fn visible_rows(tree: &Tree, root: NodeId, expanded: &HashSet<NodeId>, filter: Option<&FilterResult>) -> Vec<Row> {
    let mut out = Vec::new();
    let tab = tree.table();
    if tab.is_dead(tree, root) { return Vec::new(); }
    let mut stack: Vec<(std::ops::Range<NodeId>, u32)> = vec![(tree.children(root), 0)];
    while let Some((range, depth)) = stack.last_mut() {
        let Some(id) = range.next() else {
            stack.pop();
            continue;
        };
        if tab.forgotten.binary_search(&id).is_ok() { continue; }
        if let Some(f) = filter {
            if f.counts[id as usize] == 0 {
                continue;
            }
        }
        let d = *depth;
        out.push(Row { node: id, depth: d });
        if expanded.contains(&id) && tree.live_child_count_in(&tab, id) > 0 {
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

/// Direct children `id` would show as outline rows when expanded: live (not removed) children, and under a filter only those with
/// at least one matching file (the same match-count predicate the rows use, so a zero-byte match counts and a non-match does not).
/// Unfiltered it equals `live_child_count_in`. This is a display count; `live_child_count_in` stays the structural count for navigation.
pub fn visible_child_count_in(tree: &Tree, tab: &crate::tree::SizeTable, id: NodeId, filter: Option<&FilterResult>) -> u32 {
    match filter {
        None => tree.live_child_count_in(tab, id),
        Some(f) => tree.children(id).filter(|&c| tab.forgotten.binary_search(&c).is_err() && f.counts[c as usize] != 0).count() as u32,
    }
}

fn ordered_children(tree: &Tree, tab: &crate::tree::SizeTable, id: NodeId, mode: SortMode, filter: Option<&FilterResult>) -> Vec<NodeId> {
    let sizes = filter.map(|f| f.sizes.as_slice());
    let mut v: Vec<NodeId> = tree.children(id).collect();
    let key_size = |n: NodeId| sizes.map(|s| s[n as usize]).unwrap_or_else(|| tab.sizes[n as usize]);
    match mode {
        SortMode::SizeDesc => {
            if sizes.is_some() {
                v.sort_by_key(|&n| std::cmp::Reverse(key_size(n)));
            }
        }
        SortMode::SizeAsc => v.sort_by_key(|&n| key_size(n)),
        SortMode::NameAsc => v.sort_by_cached_key(|&n| tree.name(n).to_lowercase()),
        // Items count what the row displays: visible children under a filter (live total breaks ties), the live count otherwise. Stable.
        SortMode::ItemsDesc => v.sort_by_cached_key(|&n| (std::cmp::Reverse(visible_child_count_in(tree, tab, n, filter)), std::cmp::Reverse(tree.live_child_count_in(tab, n)))),
        SortMode::ModifiedDesc => v.sort_by_key(|&n| std::cmp::Reverse(tree.mtime(n))),
    }
    v
}

/// Like `visible_rows`, with a chosen sibling order. Ties keep the native (size-descending) order
/// because the sorts are stable. Nothing is capped.
pub fn visible_rows_sorted(tree: &Tree, root: NodeId, expanded: &HashSet<NodeId>, filter: Option<&FilterResult>, mode: SortMode) -> Vec<Row> {
    visible_rows_sorted_in(tree, &tree.table(), root, expanded, filter, mode)
}

/// One captured table is used for every expanded directory in this call.
pub fn visible_rows_sorted_in(tree: &Tree, tab: &crate::tree::SizeTable, root: NodeId, expanded: &HashSet<NodeId>, filter: Option<&FilterResult>, mode: SortMode) -> Vec<Row> {
    let gone = tab.forgotten.as_slice();
    let mut out = Vec::new();
    // A displayed root that was removed, or sits inside a removed folder, has no rows (its children are not tombstoned themselves).
    if tab.is_dead(tree, root) { return out; }
    let mut stack: Vec<(std::vec::IntoIter<NodeId>, u32)> = vec![(ordered_children(tree, tab, root, mode, filter).into_iter(), 0)];
    while let Some((it, depth)) = stack.last_mut() {
        let Some(id) = it.next() else {
            stack.pop();
            continue;
        };
        // A removed subtree stays in the arena with size 0; hide it by the table's removal list (zero-byte files stay visible).
        if gone.binary_search(&id).is_ok() { continue; }
        if let Some(f) = filter {
            if f.counts[id as usize] == 0 {
                continue;
            }
        }
        let d = *depth;
        out.push(Row { node: id, depth: d });
        if expanded.contains(&id) && tree.live_child_count_in(tab, id) > 0 {
            stack.push((ordered_children(tree, tab, id, mode, filter).into_iter(), d + 1));
        }
    }
    out
}
