//! Engine-only unit coverage for the pure modules that had none: tree arena
//! accessors/invariants, category classification, squarified layout + hit test,
//! and the outline projection. All fixtures come from Tree::synthetic (no
//! filesystem, no FFI, deterministic).

use spacelyzer_engine::layout::{self, LayoutOptions};
use spacelyzer_engine::outline::{self, SortMode};
use spacelyzer_engine::tree::{Kind, Tree};
use spacelyzer_engine::Category;
use std::collections::HashSet;

fn tree(n: usize) -> Tree {
    Tree::synthetic(n)
}

// ---------- tree ----------

#[test]
fn synthetic_shape_and_links() {
    let t = tree(500);
    assert_eq!(t.len(), 500);
    assert_eq!(t.items, 499);
    assert_eq!(t.root(), 0);
    assert_eq!(t.root_path(), "/synthetic");
    assert!(t.parent(t.root()).is_none());
    for id in 1..t.len() as u32 {
        let p = t.parent(id).expect("non-root has a parent");
        assert!(p < id, "parents are always created before children");
        assert!(t.children(p).contains(&id), "id {id} is in its parent's child range");
        assert!(t.child_count(p) > 0);
    }
    // Every child range stays inside the arena.
    for id in 0..t.len() as u32 {
        let r = t.children(id);
        assert!(r.end as usize <= t.len());
        assert_eq!(r.len(), t.child_count(id) as usize);
    }
}

#[test]
fn path_find_roundtrip() {
    let t = tree(500);
    for id in (0..t.len() as u32).step_by(7) {
        let p = t.path(id);
        assert_eq!(t.find(&p), Some(id), "roundtrip failed for {p}");
    }
    assert_eq!(t.path(t.root()), "/synthetic");
    assert_eq!(t.find("/synthetic"), Some(t.root()));
    assert_eq!(t.find("/synthetic/"), Some(t.root()));
    assert_eq!(t.find("/elsewhere"), None);
    assert_eq!(t.find("/synthetic/no-such-node"), None);
}

#[test]
fn own_bytes_and_category_totals_accounting() {
    let t = tree(500);
    let mut file_count = 0u64;
    let mut file_bytes = 0u64;
    for id in 0..t.len() as u32 {
        let kids: u64 = t.children(id).map(|c| t.size(c)).sum();
        if t.kind(id) == Kind::Directory {
            assert!(!t.children(id).is_empty() || t.size(id) == 0);
            assert_eq!(t.own_bytes(id), t.size(id).saturating_sub(kids));
        } else {
            assert_eq!(t.own_bytes(id), t.size(id), "leaf own bytes are its size");
            assert!(t.children(id).is_empty());
            file_count += 1;
            file_bytes += t.size(id);
        }
    }
    let totals = t.category_totals();
    let sum_bytes: u64 = totals.iter().map(|b| b.0).sum();
    let sum_items: u64 = totals.iter().map(|b| b.1).sum();
    assert_eq!(sum_bytes, file_bytes);
    assert_eq!(sum_items, file_count);
    // Directories contribute nothing to the totals.
    assert_eq!(totals[Category::Folder as usize], (0, 0));
}

#[test]
fn largest_files_descending_files_only() {
    let t = tree(500);
    let top = t.largest_files(10);
    assert_eq!(top.len(), 10);
    assert!(top.iter().all(|&i| t.kind(i) == Kind::File));
    assert!(top.windows(2).all(|w| t.size(w[0]) >= t.size(w[1])));
    // Asking for more than exists returns every file; n = 0 returns nothing.
    let total_files = (0..t.len() as u32).filter(|&i| t.kind(i) == Kind::File).count();
    assert_eq!(t.largest_files(usize::MAX).len(), total_files);
    assert!(t.largest_files(0).is_empty());
}

#[test]
fn forget_zeroes_subtree_and_repairs_ancestors() {
    let mut t = tree(500);
    // Deepest directory that still has children.
    let dir = (1..t.len() as u32)
        .rev()
        .find(|&i| t.kind(i) == Kind::Directory && t.child_count(i) > 0)
        .expect("synthetic tree has a nested directory");
    let removed = t.size(dir);
    assert!(removed > 0);
    let root_before = t.size(t.root());
    let parent = t.parent(dir).unwrap();
    let parent_before = t.size(parent);
    t.forget(dir);
    assert_eq!(t.size(dir), 0);
    // Descendants zeroed.
    let mut stack: Vec<u32> = t.children(dir).collect();
    while let Some(n) = stack.pop() {
        assert_eq!(t.size(n), 0);
        stack.extend(t.children(n));
    }
    // Ancestor totals repaired by exactly the removed amount.
    assert_eq!(t.size(parent), parent_before - removed);
    assert_eq!(t.size(t.root()), root_before - removed);
    // Forgetting an already-empty directory is a no-op.
    t.forget(dir);
    assert_eq!(t.size(t.root()), root_before - removed);
}

#[test]
fn kind_from_u8_mapping() {
    assert_eq!(Kind::from_u8(0), Kind::File);
    assert_eq!(Kind::from_u8(1), Kind::Directory);
    assert_eq!(Kind::from_u8(2), Kind::Package);
    assert_eq!(Kind::from_u8(3), Kind::Symlink);
    assert_eq!(Kind::from_u8(4), Kind::File);
    assert_eq!(Kind::from_u8(255), Kind::File);
}

// ---------- category ----------

#[test]
fn classify_by_extension() {
    use Category::*;
    let cases: &[(&str, Category)] = &[
        ("photo.PNG", Image),
        ("clip.mov", Video),
        ("song.Mp3", Audio),
        ("backup.zip", Archive),
        ("font.ttf", Font),
        ("main.rs", Code),
        ("App.swift", Code),
        ("Installer.app", Application),
        ("lib.so", Application),
        ("data.json", Data),
        ("readme.txt", Document),
        ("paper.PDF", Document),
        ("unknown.xyz", Other),
        ("no-extension", Other),
        (".hidden", Other),
        ("trailing.", Other),
        ("toolongextension.abcdefghijklm", Other),
    ];
    for (name, want) in cases {
        assert_eq!(Category::classify(name), *want, "classify({name})");
    }
}

#[test]
fn category_from_u8_roundtrip_and_labels() {
    let mut labels = HashSet::new();
    for v in 0..11u8 {
        let c = Category::from_u8(v);
        assert_eq!(c as u8, v);
        assert!(labels.insert(c.label()), "labels are distinct");
    }
    assert_eq!(Category::from_u8(11), Category::Other);
    assert_eq!(Category::from_u8(255), Category::Other);
}

// ---------- layout ----------

#[test]
fn layout_rects_stay_in_bounds() {
    let t = tree(500);
    let opts = LayoutOptions::default();
    let rects = layout::layout(&t, t.root(), &opts);
    assert!(!rects.is_empty());
    assert!(rects.len() <= opts.max_rects);
    for r in &rects {
        assert!(r.x.is_finite() && r.y.is_finite() && r.w.is_finite() && r.h.is_finite());
        assert!(r.x >= 0.0 && r.y >= 0.0, "rect {:?} starts outside", r);
        assert!(r.w >= 0.0 && r.h >= 0.0);
        assert!(r.x + r.w <= opts.width + 0.01, "rect {:?} overflows width", r);
        assert!(r.y + r.h <= opts.height + 0.01, "rect {:?} overflows height", r);
    }
}

#[test]
fn layout_siblings_do_not_overlap() {
    let t = tree(300);
    let opts = LayoutOptions::default();
    let rects = layout::layout(&t, t.root(), &opts);
    let overlap = |a: &layout::Rect, b: &layout::Rect| {
        a.x < b.x + b.w - 0.001 && b.x < a.x + a.w - 0.001 && a.y < b.y + b.h - 0.001 && b.y < a.y + a.h - 0.001
    };
    for (i, a) in rects.iter().enumerate() {
        for b in &rects[i + 1..] {
            if a.depth != b.depth {
                continue;
            }
            let (pa, pb) = (t.parent(a.node), t.parent(b.node));
            if pa.is_some() && pa == pb {
                assert!(!overlap(a, b), "sibling rects {:?} and {:?} overlap", a, b);
            }
        }
    }
}

#[test]
fn hit_test_finds_deepest_rect_at_leaf_center() {
    let t = tree(300);
    let opts = LayoutOptions::default();
    let rects = layout::layout(&t, t.root(), &opts);
    let mut checked = 0;
    for (i, r) in rects.iter().enumerate() {
        if r.flags != layout::FLAG_LEAF || r.w < 2.0 || r.h < 2.0 {
            continue;
        }
        let hit = layout::hit_test(&rects, r.x + r.w / 2.0, r.y + r.h / 2.0);
        assert_eq!(hit, Some(i), "center of leaf rect {:?} hit {:?}", r, hit.map(|h| rects[h]));
        checked += 1;
    }
    assert!(checked > 0, "no leaf rects large enough to test");
    assert_eq!(layout::hit_test(&rects, -1.0, -1.0), None);
    assert_eq!(layout::hit_test(&rects, opts.width + 1.0, opts.height + 1.0), None);
}

#[test]
fn layout_with_size_override_changes_areas() {
    let t = tree(300);
    let opts = LayoutOptions::default();
    let base = layout::layout(&t, t.root(), &opts);
    let flat = vec![100u64; t.len()];
    let even = layout::layout_with(&t, t.root(), &opts, Some(&flat));
    // None sizes must be identical to layout().
    let none = layout::layout_with(&t, t.root(), &opts, None);
    assert_eq!(base.len(), none.len());
    for (a, b) in base.iter().zip(&none) {
        assert_eq!((a.x, a.y, a.w, a.h, a.node), (b.x, b.y, b.w, b.h, b.node));
    }
    // Equal sizes for every node change at least one rect's area.
    let differs = base.iter().zip(&even).any(|(a, b)| (a.w * a.h - b.w * b.h).abs() > 0.5);
    assert!(differs, "size override had no effect on the layout");
}

// ---------- outline ----------

#[test]
fn outline_collapsed_shows_root_children_only() {
    let t = tree(500);
    let rows = outline::visible_rows(&t, t.root(), &HashSet::new(), None);
    assert_eq!(rows.len(), t.child_count(t.root()) as usize);
    assert!(rows.iter().all(|r| r.depth == 0));
    let native: Vec<u32> = t.children(t.root()).collect();
    assert_eq!(rows.iter().map(|r| r.node).collect::<Vec<_>>(), native);
}

#[test]
fn outline_expansion_inserts_children_after_parent() {
    let t = tree(500);
    let dir = t
        .children(t.root())
        .find(|&c| t.kind(c) == Kind::Directory && t.child_count(c) > 0)
        .expect("root has an expandable directory");
    let mut expanded = HashSet::new();
    expanded.insert(dir);
    let rows = outline::visible_rows(&t, t.root(), &expanded, None);
    let pos = rows.iter().position(|r| r.node == dir).unwrap();
    let kids: Vec<u32> = t.children(dir).collect();
    for (off, kid) in kids.iter().enumerate() {
        let row = &rows[pos + 1 + off];
        assert_eq!(row.node, *kid);
        assert_eq!(row.depth, 1);
    }
    // The row after the inserted block is back at depth 0 (or the dir is last).
    let after = pos + 1 + kids.len();
    if after < rows.len() {
        assert_eq!(rows[after].depth, 0);
    }
}

#[test]
fn outline_sort_modes() {
    let t = tree(500);
    let root = t.root();
    // NameAsc: case-insensitive ascending.
    let rows = outline::visible_rows_sorted(&t, root, &HashSet::new(), None, SortMode::NameAsc);
    let names: Vec<String> = rows.iter().map(|r| t.name(r.node).to_lowercase()).collect();
    assert!(names.windows(2).all(|w| w[0] <= w[1]), "NameAsc order: {names:?}");
    // SizeAsc: non-decreasing sizes.
    let rows = outline::visible_rows_sorted(&t, root, &HashSet::new(), None, SortMode::SizeAsc);
    assert!(rows.windows(2).all(|w| t.size(w[0].node) <= t.size(w[1].node)));
    // ItemsDesc: non-increasing child counts.
    let rows = outline::visible_rows_sorted(&t, root, &HashSet::new(), None, SortMode::ItemsDesc);
    assert!(rows.windows(2).all(|w| t.child_count(w[0].node) >= t.child_count(w[1].node)));
    // ModifiedDesc: non-increasing mtimes.
    let rows = outline::visible_rows_sorted(&t, root, &HashSet::new(), None, SortMode::ModifiedDesc);
    assert!(rows.windows(2).all(|w| t.mtime(w[0].node) >= t.mtime(w[1].node)));
    // from_u32 mapping.
    assert_eq!(SortMode::from_u32(0), SortMode::SizeDesc);
    assert_eq!(SortMode::from_u32(1), SortMode::SizeAsc);
    assert_eq!(SortMode::from_u32(2), SortMode::NameAsc);
    assert_eq!(SortMode::from_u32(3), SortMode::ItemsDesc);
    assert_eq!(SortMode::from_u32(4), SortMode::ModifiedDesc);
    assert_eq!(SortMode::from_u32(99), SortMode::SizeDesc);
}
