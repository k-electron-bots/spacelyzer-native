//! Squarified treemap layout (Bruls, Huizing, van Wijk) over the size-sorted arena, plus
//! hit testing. Output is a flat vector of rectangles, parents before children, so the UI
//! draws in order and a reverse scan finds the deepest rectangle under a point.

use crate::tree::{Kind, NodeId, Tree};

#[derive(Clone, Copy, Debug)]
pub struct LayoutOptions {
    pub width: f32,
    pub height: f32,
    /// Rectangles with an edge shorter than this are folded into a remainder.
    pub min_edge: f32,
    /// Inset applied inside a directory before laying out its children.
    pub inset: f32,
    /// Hard cap on emitted rectangles, so drawing stays cheap at any scan size.
    pub max_rects: usize,
    pub max_depth: u32,
}

impl Default for LayoutOptions {
    fn default() -> Self {
        LayoutOptions { width: 800.0, height: 600.0, min_edge: 3.0, inset: 1.5, max_rects: 30_000, max_depth: 12 }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    /// Node id; for a remainder this is the parent directory.
    pub node: NodeId,
    pub depth: u32,
    /// Index of the top-level child of the displayed root this rect lies under (colour hue).
    pub branch: u32,
    /// 1 = leaf (file, package, collapsed dir), 2 = remainder, 0 = directory frame.
    pub flags: u32,
    pub size: u64,
}

pub const FLAG_DIR: u32 = 0;
pub const FLAG_LEAF: u32 = 1;
pub const FLAG_REMAINDER: u32 = 2;

struct Item {
    id: NodeId,
    area: f64,
}

pub fn layout(tree: &Tree, root: NodeId, opts: &LayoutOptions) -> Vec<Rect> {
    layout_with(tree, root, opts, None)
}

/// Layout using per-node sizes from a filter result instead of the tree's own sizes.
/// Children are re-sorted by those sizes.
pub fn layout_with(tree: &Tree, root: NodeId, opts: &LayoutOptions, sizes: Option<&[u64]>) -> Vec<Rect> {
    layout_in(tree, &tree.table(), root, opts, sizes)
}

/// Layout against a table the caller captured: every size in this layout comes from that one version.
pub fn layout_in(tree: &Tree, tab: &crate::tree::SizeTable, root: NodeId, opts: &LayoutOptions, sizes: Option<&[u64]>) -> Vec<Rect> {
    let sz = |id: NodeId| -> u64 { sizes.map(|s| s[id as usize]).unwrap_or_else(|| tab.sizes[id as usize]) };
    let mut out = Vec::new();
    let total = sz(root);
    if total == 0 || opts.width <= 0.0 || opts.height <= 0.0 {
        return out;
    }
    out.push(Rect {
        x: 0.0, y: 0.0, w: opts.width, h: opts.height,
        node: root, depth: 0, branch: 0, flags: FLAG_DIR, size: total,
    });
    let mut work: std::collections::VecDeque<(NodeId, (f32, f32, f32, f32), u32, u32)> = Default::default();
    work.push_back((root, (0.0, 0.0, opts.width, opts.height), 0, u32::MAX));
    // Breadth-first so the cap trims the finest detail, not whole branches.
    while let Some((dir, (x, y, w, h), depth, branch)) = work.pop_front() {
        let inset = if depth == 0 { 0.0 } else { opts.inset };
        let (x, y, w, h) = (x + inset, y + inset, w - 2.0 * inset, h - 2.0 * inset);
        if w < opts.min_edge || h < opts.min_edge {
            continue;
        }
        let dir_total = sz(dir) as f64;
        if dir_total <= 0.0 {
            continue;
        }
        let scale = (w as f64 * h as f64) / dir_total;
        let mut items: Vec<Item> = Vec::new();
        let mut small = 0.0f64;
        let mut small_bytes = 0u64;
        let min_area = (opts.min_edge as f64) * (opts.min_edge as f64);
        let mut kids: Vec<NodeId> = tree.children(dir).collect();
        if sizes.is_some() {
            kids.retain(|&c| sz(c) > 0);
            kids.sort_unstable_by_key(|&c| std::cmp::Reverse(sz(c)));
        }
        for c in kids {
            let s = sz(c);
            if s == 0 {
                continue;
            }
            let a = s as f64 * scale;
            if a < min_area {
                small += a;
                small_bytes += s;
            } else {
                items.push(Item { id: c, area: a });
            }
        }
        let mut rects: Vec<(Option<NodeId>, f64, f32, f32, f32, f32)> = Vec::new();
        let mut all: Vec<(Option<NodeId>, f64)> = items.iter().map(|i| (Some(i.id), i.area)).collect();
        if small > 0.0 {
            all.push((None, small));
        }
        squarify(&all, x, y, w, h, &mut rects);
        for (idx, (id, area, rx, ry, rw, rh)) in rects.into_iter().enumerate() {
            let _ = area;
            if out.len() >= opts.max_rects {
                return out;
            }
            match id {
                None => out.push(Rect {
                    x: rx, y: ry, w: rw, h: rh, node: dir, depth: depth + 1,
                    branch: if branch == u32::MAX { 0 } else { branch },
                    flags: FLAG_REMAINDER, size: small_bytes,
                }),
                Some(c) => {
                    let b = if branch == u32::MAX { idx as u32 } else { branch };
                    let descend = tree.kind(c) == Kind::Directory
                        && tree.child_count(c) > 0
                        && depth + 1 < opts.max_depth
                        && rw > opts.min_edge * 3.0
                        && rh > opts.min_edge * 3.0;
                    out.push(Rect {
                        x: rx, y: ry, w: rw, h: rh, node: c, depth: depth + 1, branch: b,
                        flags: if descend { FLAG_DIR } else { FLAG_LEAF }, size: sz(c),
                    });
                    if descend {
                        work.push_back((c, (rx, ry, rw, rh), depth + 1, b));
                    }
                }
            }
        }
    }
    out
}

fn worst(row: &[f64], sum: f64, side: f64) -> f64 {
    let (mut mn, mut mx) = (f64::MAX, 0.0f64);
    for &a in row {
        mn = mn.min(a);
        mx = mx.max(a);
    }
    let s2 = side * side;
    ((s2 * mx) / (sum * sum)).max((sum * sum) / (s2 * mn))
}

fn squarify(
    items: &[(Option<NodeId>, f64)],
    mut x: f32, mut y: f32, mut w: f32, mut h: f32,
    out: &mut Vec<(Option<NodeId>, f64, f32, f32, f32, f32)>,
) {
    let mut i = 0;
    while i < items.len() {
        let side = w.min(h) as f64;
        if side <= 0.0 {
            // Degenerate: collapse remaining items onto the line.
            for it in &items[i..] {
                out.push((it.0, it.1, x, y, 0.0, 0.0));
            }
            return;
        }
        let mut j = i;
        let mut sum = 0.0;
        let mut row: Vec<f64> = Vec::new();
        let mut prev = f64::MAX;
        while j < items.len() {
            row.push(items[j].1);
            let s = sum + items[j].1;
            let wr = worst(&row, s, side);
            if wr > prev {
                row.pop();
                break;
            }
            prev = wr;
            sum = s;
            j += 1;
        }
        if j == i {
            j = i + 1;
            sum = items[i].1;
        }
        let thick = (sum / side) as f32;
        let horizontal = w >= h; // lay the row along the short side
        let mut off = 0.0f32;
        for it in &items[i..j] {
            let len = if sum > 0.0 { (it.1 / sum) as f32 * side as f32 } else { 0.0 };
            if horizontal {
                out.push((it.0, it.1, x, y + off, thick, len));
            } else {
                out.push((it.0, it.1, x + off, y, len, thick));
            }
            off += len;
        }
        if horizontal {
            x += thick;
            w -= thick;
        } else {
            y += thick;
            h -= thick;
        }
        i = j;
    }
}

/// Deepest rectangle containing the point, or None. Rects are ordered parents first, so the
/// last match is the deepest.
pub fn hit_test(rects: &[Rect], px: f32, py: f32) -> Option<usize> {
    rects
        .iter()
        .rposition(|r| px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h)
}
