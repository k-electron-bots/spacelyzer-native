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
    let mut stack: Vec<(std::ops::Range<NodeId>, u32)> = vec![(tree.children(root), 0)];
    while let Some((range, depth)) = stack.last_mut() {
        let Some(id) = range.next() else {
            stack.pop();
            continue;
        };
        if let Some(f) = filter {
            if f.counts[id as usize] == 0 {
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


fn name_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    if a.is_ascii() && b.is_ascii() {
        // ASCII fast path: allocation-free byte fold. For ASCII-only strings this
        // is byte-identical to comparing `to_lowercase()` on both sides.
        let mut ai = a.bytes().map(|c| c.to_ascii_lowercase());
        let mut bi = b.bytes().map(|c| c.to_ascii_lowercase());
        loop {
            match (ai.next(), bi.next()) {
                (None, None) => return std::cmp::Ordering::Equal,
                (None, Some(_)) => return std::cmp::Ordering::Less,
                (Some(_), None) => return std::cmp::Ordering::Greater,
                (Some(x), Some(y)) => {
                    let o = x.cmp(&y);
                    if o != std::cmp::Ordering::Equal { return o; }
                }
            }
        }
    }
    // Non-ASCII: full-string lowercase, exactly the old sort key. This keeps the
    // context-sensitive Unicode rules (e.g. Greek final sigma) that a per-char
    // mapping would get wrong. Non-ASCII names allocate, as they did before.
    a.to_lowercase().cmp(&b.to_lowercase())
}

fn ordered_children(tree: &Tree, id: NodeId, mode: SortMode, filter: Option<&FilterResult>) -> Vec<NodeId> {
    let sizes = filter.map(|f| f.sizes.as_slice());
    let mut v: Vec<NodeId> = tree.children(id).collect();
    let key_size = |n: NodeId| sizes.map(|s| s[n as usize]).unwrap_or_else(|| tree.size(n));
    match mode {
        SortMode::SizeDesc => {
            if sizes.is_some() {
                v.sort_by_key(|&n| std::cmp::Reverse(key_size(n)));
            }
        }
        SortMode::SizeAsc => v.sort_by_key(|&n| key_size(n)),
        SortMode::NameAsc => {
            // Case-insensitive (Unicode lowercase) name ascending. Comparator-only:
            // ASCII names compare allocation-free (byte fold); non-ASCII names
            // compare full-string lowercase, the exact old key semantics (incl.
            // contextual final sigma). The explicit position tiebreak keeps the
            // pre-sort sibling order on equal keys, matching the old stable sort.
            let mut order: Vec<u32> = (0..v.len() as u32).collect();
            order.sort_unstable_by(|&a, &b| name_cmp(tree.name(v[a as usize]), tree.name(v[b as usize])).then(a.cmp(&b)));
            let mut sorted = Vec::with_capacity(v.len());
            for &i in &order { sorted.push(v[i as usize]); }
            v = sorted;
        }
        SortMode::ItemsDesc => v.sort_by_key(|&n| std::cmp::Reverse(tree.child_count(n))),
        SortMode::ModifiedDesc => v.sort_by_key(|&n| std::cmp::Reverse(tree.mtime(n))),
    }
    v
}

/// Like `visible_rows`, with a chosen sibling order. Ties keep the native (size-descending) order
/// because the sorts are stable. Nothing is capped.
pub fn visible_rows_sorted(tree: &Tree, root: NodeId, expanded: &HashSet<NodeId>, filter: Option<&FilterResult>, mode: SortMode) -> Vec<Row> {
    let mut out = Vec::new();
    let mut stack: Vec<(std::vec::IntoIter<NodeId>, u32)> = vec![(ordered_children(tree, root, mode, filter).into_iter(), 0)];
    while let Some((it, depth)) = stack.last_mut() {
        let Some(id) = it.next() else {
            stack.pop();
            continue;
        };
        if let Some(f) = filter {
            if f.counts[id as usize] == 0 {
                continue;
            }
        }
        let d = *depth;
        out.push(Row { node: id, depth: d });
        if expanded.contains(&id) && tree.child_count(id) > 0 {
            stack.push((ordered_children(tree, id, mode, filter).into_iter(), d + 1));
        }
    }
    out
}
