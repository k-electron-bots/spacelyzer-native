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
        SortMode::NameAsc => {
            // Case-insensitive (Unicode lowercase) name ascending.
            if v.iter().any(|&n| !tree.name(n).is_ascii()) {
                // Any non-ASCII name: the original per-key lowercase sort. Exact
                // Unicode semantics (incl. contextual final sigma), one String
                // allocation per sibling as before - no per-comparison allocs.
                v.sort_by_cached_key(|&n| tree.name(n).to_lowercase());
            } else {
                // All-ASCII: allocation-free comparator (byte fold, identical to
                // the old lowercase keys for ASCII). The explicit position
                // tiebreak keeps the pre-sort order on equal keys, matching the
                // old stable sort.
                let mut order: Vec<u32> = (0..v.len() as u32).collect();
                order.sort_unstable_by(|&a, &b| name_cmp(tree.name(v[a as usize]), tree.name(v[b as usize])).then(a.cmp(&b)));
                let mut sorted = Vec::with_capacity(v.len());
                for &i in &order { sorted.push(v[i as usize]); }
                v = sorted;
            }
        }
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


// Filesystem fixture intentionally needs distinct case-only names (AA/aa).
// Do not run it on case-insensitive macOS volumes. This is Linux execution evidence only.
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use crate::scan::{scan, ScanOptions, ScanProgress};
    use std::fs;
    use std::time::{Duration, SystemTime};

    /// alpha(4096) beta{b2(8192), nested/b3(4096)} casepair{AA(4096), aa(2048)}
    /// EMPTYMATCH.txt(0) f(64) m1/m2/m3(64, mtimes now+100/+200/+300)
    fn fixture(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("spz-outline-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("Alpha")).unwrap();
        fs::create_dir_all(dir.join("beta/nested")).unwrap();
        fs::create_dir_all(dir.join("casepair")).unwrap();
        fs::write(dir.join("Alpha/a1"), vec![1u8; 4096]).unwrap();
        fs::write(dir.join("beta/b2"), vec![1u8; 8192]).unwrap();
        fs::write(dir.join("beta/nested/b3"), vec![1u8; 4096]).unwrap();
        fs::write(dir.join("casepair/AA"), vec![1u8; 4096]).unwrap();
        fs::write(dir.join("casepair/aa"), vec![1u8; 2048]).unwrap();
        fs::write(dir.join("EMPTYMATCH.txt"), b"").unwrap();
        fs::write(dir.join("f"), vec![1u8; 64]).unwrap();
        let now = SystemTime::now();
        for (n, plus) in [("m1", 100u64), ("m2", 200), ("m3", 300)] {
            let p = dir.join(n);
            fs::write(&p, vec![1u8; 64]).unwrap();
            fs::File::options().write(true).open(&p).unwrap().set_modified(now + Duration::from_secs(plus)).unwrap();
        }
        dir.canonicalize().unwrap()
    }

    fn tree_of(root: &std::path::Path) -> Tree {
        scan(root, &ScanOptions::default(), &ScanProgress::default()).unwrap()
    }

    fn named(tree: &Tree, rows: &[Row]) -> Vec<(String, u32)> {
        rows.iter().map(|r| (tree.name(r.node).to_string(), r.depth)).collect()
    }

    fn id(tree: &Tree, root: &std::path::Path, rel: &str) -> NodeId {
        tree.find(&format!("{}/{rel}", root.display())).unwrap_or_else(|| panic!("node {rel} exists"))
    }

    #[test]
    fn a_collapsed_root_lists_only_its_own_children_at_depth_zero() {
        let root = fixture("collapsed");
        let tree = tree_of(&root);
        let rows = visible_rows(&tree, tree.root(), &HashSet::new(), None);
        let got = named(&tree, &rows);
        assert_eq!(got.len(), 8, "exactly the root's children: {got:?}");
        assert!(got.iter().all(|(_, d)| *d == 0), "nothing deeper without expansion: {got:?}");
        for n in ["Alpha", "beta", "casepair", "EMPTYMATCH.txt", "f", "m1", "m2", "m3"] {
            assert!(got.iter().any(|(name, _)| name == n), "{n} present");
        }
        let pos = |n: &str| got.iter().position(|(name, _)| name == n).unwrap();
        assert!(pos("beta") < pos("casepair") && pos("casepair") < pos("Alpha"), "native order is size-descending");
        assert_eq!(got.last().unwrap().0, "EMPTYMATCH.txt", "zero bytes sorts last");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn expansion_recurses_dfs_into_expanded_dirs_only_with_exact_depths() {
        let root = fixture("expand");
        let tree = tree_of(&root);
        let beta = id(&tree, &root, "beta");
        let nested = id(&tree, &root, "beta/nested");
        let alpha = id(&tree, &root, "Alpha");
        // Only Alpha expanded: its child appears, beta's subtree stays shut.
        let rows = visible_rows(&tree, tree.root(), &HashSet::from([alpha]), None);
        let got = named(&tree, &rows);
        assert!(got.contains(&("a1".to_string(), 1)), "expanded child at depth 1: {got:?}");
        assert!(!got.iter().any(|(n, _)| n == "b2" || n == "nested"), "unexpanded dirs stay shut: {got:?}");
        // beta and nested expanded: full DFS order, parent before child, depths exact.
        let rows = visible_rows(&tree, tree.root(), &HashSet::from([beta, nested]), None);
        let got = named(&tree, &rows);
        let expect_prefix: Vec<(String, u32)> = vec![
            ("beta".into(), 0), ("b2".into(), 1), ("nested".into(), 1), ("b3".into(), 2),
        ];
        assert_eq!(&got[..4], &expect_prefix[..], "DFS order and depths: {got:?}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_forgotten_subtree_vanishes_from_rows_and_a_dead_root_has_none() {
        let root = fixture("forget");
        let tree = tree_of(&root);
        let beta = id(&tree, &root, "beta");
        let nested = id(&tree, &root, "beta/nested");
        let beta_bytes = tree.size(beta);
        let root_before = tree.size(tree.root());
        let version = tree.forget(beta).unwrap();
        assert_eq!(version, 1, "forget returns the new table version");
        assert_eq!(tree.size(beta), 0, "the forgotten node stays in the arena at size 0");
        assert_eq!(tree.size(tree.root()), root_before - beta_bytes, "ancestor totals are fixed by exactly the removed bytes");
        let rows = visible_rows(&tree, tree.root(), &HashSet::from([beta, nested]), None);
        let got = named(&tree, &rows);
        assert!(!got.iter().any(|(n, _)| n == "beta" || n == "b2" || n == "nested" || n == "b3"),
                "the whole forgotten subtree is hidden even when expanded: {got:?}");
        assert_eq!(got.len(), 7, "one subtree (4 nodes) gone from 11");
        let dead = visible_rows(&tree, beta, &HashSet::from([beta]), None);
        assert!(dead.is_empty(), "a removed root displays no rows");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_filter_hides_nonmatching_subtrees_but_a_zero_byte_match_stays_visible() {
        let root = fixture("filter");
        let tree = tree_of(&root);
        let alpha = id(&tree, &root, "Alpha");
        let a1 = id(&tree, &root, "Alpha/a1");
        let beta = id(&tree, &root, "beta");
        let zero = id(&tree, &root, "EMPTYMATCH.txt");
        let mut counts = vec![0u32; tree.len()];
        let mut sizes = vec![0u64; tree.len()];
        counts[alpha as usize] = 1;
        counts[a1 as usize] = 1;
        sizes[alpha as usize] = 4096;
        sizes[a1 as usize] = 4096;
        counts[zero as usize] = 1; // a zero-BYTE match: count-based visibility, not size-based
        let filter = FilterResult { sizes, counts, total_bytes: 4096, total_count: 2 };
        let rows = visible_rows(&tree, tree.root(), &HashSet::from([alpha, beta]), Some(&filter));
        let got = named(&tree, &rows);
        assert!(got.contains(&("EMPTYMATCH.txt".to_string(), 0)), "zero-byte match stays visible: {got:?}");
        assert!(!got.iter().any(|(n, _)| n == "beta" || n == "b2" || n == "nested"), "nonmatching subtree hidden even expanded: {got:?}");
        assert!(got.contains(&("Alpha".to_string(), 0)) && got.contains(&("a1".to_string(), 1)), "matching subtree shows through: {got:?}");
        let tab = tree.table();
        let shown = visible_child_count_in(&tree, &tab, tree.root(), Some(&filter));
        assert_eq!(shown, got.iter().filter(|(_, d)| *d == 0).count() as u32, "the disclosure triangle count matches the rows");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sort_modes_order_siblings_as_documented() {
        let root = fixture("sort");
        let tree = tree_of(&root);
        let none = HashSet::new();
        let order = |mode: SortMode| named(&tree, &visible_rows_sorted(&tree, tree.root(), &none, None, mode)).into_iter().map(|(n, _)| n).collect::<Vec<_>>();
        let asc = order(SortMode::SizeAsc);
        assert_eq!(asc.first().unwrap(), "EMPTYMATCH.txt", "smallest first");
        assert_eq!(asc.last().unwrap(), "beta", "largest last: {asc:?}");
        let names = order(SortMode::NameAsc);
        let expect = vec!["Alpha", "beta", "casepair", "EMPTYMATCH.txt", "f", "m1", "m2", "m3"];
        assert_eq!(names, expect, "case-insensitive name order");
        let items = order(SortMode::ItemsDesc);
        let pos = |v: &[String], n: &str| v.iter().position(|x| x == n).unwrap();
        assert!(pos(&items, "beta") < pos(&items, "Alpha") && pos(&items, "Alpha") < pos(&items, "f"),
                "more visible children first: {items:?}");
        let mods = order(SortMode::ModifiedDesc);
        assert_eq!(&mods[..3], &["m3", "m2", "m1"], "future-set mtimes beat the creation-time dirs: {mods:?}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn name_sort_is_case_insensitive_and_stable_on_case_only_ties() {
        let root = fixture("casetie");
        let tree = tree_of(&root);
        let cp = id(&tree, &root, "casepair");
        let rows = visible_rows_sorted(&tree, tree.root(), &HashSet::from([cp]), None, SortMode::NameAsc);
        let got = named(&tree, &rows);
        let inner: Vec<&String> = got.iter().filter(|(n, d)| *d == 1).map(|(n, _)| n).collect();
        // "AA" and "aa" fold equal; the tie keeps native (size-descending) order: the 4096-byte "AA" first.
        assert_eq!(inner, ["AA", "aa"], "case-only tie keeps native order: {got:?}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sort_mode_from_u32_maps_known_values_and_defaults_the_rest() {
        assert_eq!(SortMode::from_u32(1), SortMode::SizeAsc);
        assert_eq!(SortMode::from_u32(2), SortMode::NameAsc);
        assert_eq!(SortMode::from_u32(3), SortMode::ItemsDesc);
        assert_eq!(SortMode::from_u32(4), SortMode::ModifiedDesc);
        for v in [0u32, 5, 99, u32::MAX] {
            assert_eq!(SortMode::from_u32(v), SortMode::SizeDesc, "unknown {v} falls back to the native order");
        }
    }
}
