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
