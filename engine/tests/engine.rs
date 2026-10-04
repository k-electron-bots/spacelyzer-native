use spacelyzer_engine::*;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

fn naive(dir: &Path, seen: &mut std::collections::HashSet<(u64, u64)>) -> u64 {
    let mut t = 0;
    for e in fs::read_dir(dir).unwrap() {
        let e = e.unwrap();
        let md = fs::symlink_metadata(e.path()).unwrap();
        if md.is_dir() {
            t += naive(&e.path(), seen);
        } else if md.nlink() > 1 && !seen.insert((md.dev(), md.ino())) {
        } else {
            t += md.blocks() * 512;
        }
    }
    t
}

fn fixture() -> tempdir::T {
    let t = tempdir::T::new();
    let r = t.path();
    for d in 0..6 {
        for s in 0..4 {
            let dir = r.join(format!("d{d}/s{s}"));
            fs::create_dir_all(&dir).unwrap();
            for f in 0..5 {
                fs::write(dir.join(format!("f{f}.txt")), vec![7u8; (d * 3000 + s * 700 + f * 130 + 1) as usize]).unwrap();
            }
        }
    }
    fs::write(r.join("big.mov"), vec![1u8; 300_000]).unwrap();
    fs::hard_link(r.join("big.mov"), r.join("d0/link.mov")).unwrap();
    std::os::unix::fs::symlink("big.mov", r.join("sym")).unwrap();
    fs::create_dir_all(r.join("Foo.app/Contents")).unwrap();
    fs::write(r.join("Foo.app/Contents/bin"), vec![2u8; 50_000]).unwrap();
    t
}

mod tempdir {
    pub struct T(std::path::PathBuf);
    impl T {
        pub fn new() -> T {
            static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let p = std::env::temp_dir().join(format!("spz-test-{}-{}", std::process::id(), N.fetch_add(1, std::sync::atomic::Ordering::SeqCst)));
            std::fs::create_dir_all(&p).unwrap();
            T(p)
        }
        pub fn path(&self) -> &std::path::Path { &self.0 }
    }
    impl Drop for T {
        fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
    }
}

#[test]
fn total_matches_naive_walk_and_hardlinks_counted_once() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let expect = naive(&t.path().canonicalize().unwrap(), &mut Default::default());
    assert_eq!(tree.size(0), expect);
    assert!(tree.find(&format!("{}/Foo.app", tree.root_path())).map(|n| tree.kind(n) == Kind::Package).unwrap());
}

#[test]
fn children_sorted_and_sizes_add_up() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    for id in 0..tree.len() as u32 {
        let r = tree.children(id);
        if r.is_empty() { continue; }
        let sizes: Vec<u64> = r.clone().map(|c| tree.size(c)).collect();
        assert!(sizes.windows(2).all(|w| w[0] >= w[1]));
        let own: u64 = tree.own_bytes(id);
        assert_eq!(sizes.iter().sum::<u64>() + own, tree.size(id));
    }
}

#[test]
fn exclusion_and_path_roundtrip() {
    let t = fixture();
    let root = t.path().canonicalize().unwrap();
    let opts = ScanOptions { exclude: vec![root.join("d1")], ..Default::default() };
    let tree = scan(&root, &opts, &ScanProgress::default()).unwrap();
    assert!(tree.find(&format!("{}/d1", tree.root_path())).is_none());
    assert!(tree.skipped.iter().any(|s| s.reason == spacelyzer_engine::tree::SkipReason::UserExcluded));
    let n = tree.find(&format!("{}/d2/s1/f3.txt", tree.root_path())).unwrap();
    assert_eq!(tree.path(n), format!("{}/d2/s1/f3.txt", tree.root_path()));
}

#[test]
fn layout_conserves_area_and_hit_test_finds_leaf() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let opts = LayoutOptions { width: 1000.0, height: 700.0, min_edge: 0.0, inset: 0.0, ..Default::default() };
    let rects = layout(&tree, 0, &opts);
    // Top-level children tile the whole canvas.
    let top: f32 = rects.iter().filter(|r| r.depth == 1).map(|r| r.w * r.h).sum();
    assert!((top - 700_000.0).abs() < 700_000.0 * 1e-3, "area {top}");
    for r in &rects {
        assert!(r.x >= -0.01 && r.y >= -0.01 && r.x + r.w <= 1000.01 && r.y + r.h <= 700.01);
    }
    let big = rects.iter().position(|r| r.depth == 1 && tree.name(r.node) == "big.mov").unwrap();
    let r = rects[big];
    let hit = hit_test(&rects, r.x + r.w / 2.0, r.y + r.h / 2.0).unwrap();
    assert_eq!(rects[hit].node, r.node);
}

#[test]
fn cancel_returns_partial_flagged() {
    let t = fixture();
    let p = ScanProgress::default();
    p.cancel();
    let tree = scan(t.path(), &ScanOptions::default(), &p).unwrap();
    assert!(tree.cancelled);
}

#[test]
fn forget_updates_ancestors() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let before = tree.size(0);
    let n = tree.find(&format!("{}/d3", tree.root_path())).unwrap();
    let sz = tree.size(n);
    assert!(tree.forget(n).is_ok());
    assert_eq!(tree.size(0), before - sz);
}

#[test]
fn default_backend_agrees_with_portable_backend() {
    // On macOS the default backend is getattrlistbulk; elsewhere both are the portable path.
    let t = fixture();
    let a = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let b = scan(t.path(), &ScanOptions { force_portable: true, ..Default::default() }, &ScanProgress::default()).unwrap();
    assert_eq!(a.items, b.items);
    assert_eq!(a.size(0), b.size(0));
    for id in 0..a.len() as u32 {
        assert_eq!(a.name(id), b.name(id));
        assert_eq!(a.size(id), b.size(id), "size differs for {}", a.path(id));
    }
}

#[test]
fn filter_counts_and_rollups_match_brute_force() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let f = Filter { text: "F3".into(), min_size: Some(1000), ..Default::default() };
    let r = apply_filter(&tree, &f);
    let mut count = 0u64;
    let mut bytes = 0u64;
    for id in 0..tree.len() as u32 {
        if tree.kind(id) == Kind::Directory { continue; }
        let sz = tree.own_bytes(id);
        if tree.name(id).to_ascii_lowercase().contains("f3") && sz >= 1000 { count += 1; bytes += sz; }
    }
    assert!(count > 0);
    assert_eq!(r.total_count, count);
    assert_eq!(r.total_bytes, bytes);
    for id in 0..tree.len() as u32 {
        if tree.child_count(id) > 0 {
            let s: u64 = tree.children(id).map(|c| r.sizes[c as usize]).sum();
            assert_eq!(r.sizes[id as usize], s + if tree.kind(id) == Kind::Directory { 0 } else { r.sizes[id as usize] - s });
        }
    }
}

#[test]
fn empty_filter_matches_everything_and_extension_kind_work() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let all = apply_filter(&tree, &Filter::default());
    assert_eq!(all.total_bytes, tree.size(0));
    let mov = apply_filter(&tree, &Filter { extension: ".MOV".into(), ..Default::default() });
    assert_eq!(mov.total_count, 2); // big.mov and its hard link entry (link counted 0 bytes)
    let vid = apply_filter(&tree, &Filter { category_mask: spacelyzer_engine::filter::mask(&[spacelyzer_engine::Category::Video]), ..Default::default() });
    assert_eq!(vid.total_bytes, mov.total_bytes);
    let none = apply_filter(&tree, &Filter { max_size: Some(0), min_size: Some(1), ..Default::default() });
    assert_eq!(none.total_count, 0);
}

#[test]
fn modified_time_filter_and_filtered_layout() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let future = Filter { modified_from: Some(i64::MAX - 1), ..Default::default() };
    assert_eq!(apply_filter(&tree, &future).total_count, 0);
    let recent = Filter { modified_from: Some(1), ..Default::default() };
    assert_eq!(apply_filter(&tree, &recent).total_bytes, tree.size(0));
    let r = apply_filter(&tree, &Filter { text: "f1".into(), ..Default::default() });
    let rects = spacelyzer_engine::layout_with(&tree, 0, &LayoutOptions { min_edge: 0.0, inset: 0.0, ..Default::default() }, Some(&r.sizes));
    assert!(!rects.is_empty());
    // Only nodes with matching bytes are drawn.
    assert!(rects.iter().filter(|x| x.depth > 0).all(|x| r.sizes[x.node as usize] > 0));
}

#[test]
fn symlink_cycles_and_dir_symlinks_are_not_followed_or_double_counted() {
    let t = fixture();
    let r = t.path();
    std::fs::create_dir_all(r.join("real/inner")).unwrap();
    std::fs::write(r.join("real/inner/data.bin"), vec![1u8; 100_000]).unwrap();
    std::os::unix::fs::symlink(r.join("real"), r.join("real/inner/loop")).unwrap();
    std::os::unix::fs::symlink(r.join("real"), r.join("alias_dir")).unwrap();
    let base = scan(r, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let data: u64 = (0..base.len() as u32).filter(|&i| base.name(i) == "data.bin").map(|i| base.own_bytes(i)).sum();
    assert!(data >= 100_000 && data < 110_000, "one allocation of data.bin");
    let count = (0..base.len() as u32).filter(|&i| base.name(i) == "data.bin").count();
    assert_eq!(count, 1);
    let total = base.size(0);
    let again = scan(r, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    assert_eq!(again.size(0), total, "repeat scan is stable");
}

#[test]
fn hard_link_across_directories_counted_once() {
    let t = fixture();
    let r = t.path();
    std::fs::create_dir_all(r.join("a")).unwrap();
    std::fs::create_dir_all(r.join("b")).unwrap();
    std::fs::write(r.join("a/x"), vec![2u8; 200_000]).unwrap();
    std::fs::hard_link(r.join("a/x"), r.join("b/y")).unwrap();
    let before = scan(r, &ScanOptions::default(), &ScanProgress::default()).unwrap().size(0);
    std::fs::remove_file(r.join("b/y")).unwrap();
    let after = scan(r, &ScanOptions::default(), &ScanProgress::default()).unwrap().size(0);
    assert_eq!(before, after, "second hard link adds no bytes");
}

#[test]
fn outline_rows_expand_collapse_and_never_cap() {
    use std::collections::HashSet;
    let tree = spacelyzer_engine::Tree::synthetic(200_000);
    let none = spacelyzer_engine::outline::visible_rows(&tree, 0, &HashSet::new(), None);
    assert_eq!(none.len() as u32, tree.child_count(0));
    assert!(none.iter().all(|r| r.depth == 0));
    // Expand every directory: all non-root nodes appear exactly once, in parent-before-child order.
    let all: HashSet<u32> = (0..tree.len() as u32).collect();
    let rows = spacelyzer_engine::outline::visible_rows(&tree, 0, &all, None);
    assert_eq!(rows.len(), tree.len() - 1);
    let mut seen = HashSet::new();
    for r in &rows { assert!(seen.insert(r.node)); }
    // Expanding one folder adds exactly its children.
    let d = (1..tree.len() as u32).find(|&i| tree.child_count(i) > 0 && tree.parent(i) == Some(0)).unwrap();
    let one = spacelyzer_engine::outline::visible_rows(&tree, 0, &HashSet::from([d]), None);
    assert_eq!(one.len() as u32, tree.child_count(0) + tree.child_count(d));
}

#[test]
fn ffi_filter_roundtrip_matches_engine_filter() {
    use std::ffi::CString;
    let t = fixture();
    let tree = Box::new(scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap());
    let tp: *const spacelyzer_engine::Tree = &*tree;
    let text = CString::new("f1").unwrap();
    let f = spacelyzer_engine::ffi::SpzFilter { category_mask: 0, has_min: 0, has_max: 0, has_from: 0, has_to: 0, min_size: 0, max_size: 0, modified_from: 0, modified_to: 0 };
    unsafe {
        let h = spacelyzer_engine::ffi::spz_filter_apply(tp, text.as_ptr(), std::ptr::null(), f);
        let direct = apply_filter(&tree, &Filter { text: "f1".into(), ..Default::default() });
        assert_eq!(spacelyzer_engine::ffi::spz_filter_total_bytes(h), direct.total_bytes);
        assert_eq!(spacelyzer_engine::ffi::spz_filter_total_count(h), direct.total_count);
        assert_eq!(spacelyzer_engine::ffi::spz_filter_size(h, 0), direct.sizes[0]);
        let n = spacelyzer_engine::ffi::spz_outline_rows_filtered(tp, 0, std::ptr::null(), 0, h, std::ptr::null_mut(), 0);
        let hidden: usize = tree.children(0).filter(|&c| direct.sizes[c as usize] == 0).count();
        assert_eq!(n as usize, tree.child_count(0) as usize - hidden);
        spacelyzer_engine::ffi::spz_filter_free(h);
    }
}

#[test]
fn overlapping_roots_agree_on_the_shared_subtree() {
    let t = fixture();
    let r = t.path();
    std::fs::create_dir_all(r.join("outer/inner")).unwrap();
    std::fs::write(r.join("outer/inner/a.bin"), vec![3u8; 300_000]).unwrap();
    std::fs::write(r.join("outer/b.bin"), vec![4u8; 50_000]).unwrap();
    let outer = scan(&r.join("outer"), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let inner = scan(&r.join("outer/inner"), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let in_outer = (0..outer.len() as u32).find(|&i| outer.name(i) == "inner").expect("inner dir present");
    assert_eq!(outer.size(in_outer), inner.size(0), "same subtree, same bytes, whichever root you scan");
    assert!(outer.size(0) > inner.size(0));
    assert_eq!(outer.size(0), outer.size(in_outer) + (0..outer.len() as u32).filter(|&i| outer.name(i) == "b.bin").map(|i| outer.own_bytes(i)).sum::<u64>());
}

/// macOS only: /Applications is a firmlink to /System/Volumes/Data/Applications. Reaching it through
/// both paths must not double count. Everything else is excluded to keep this fast.
#[cfg(target_os = "macos")]
#[test]
fn macos_firmlink_reached_twice_is_counted_once() {
    use std::path::PathBuf;
    let keep_top = ["Applications", "System"];
    let mut exclude: Vec<PathBuf> = Vec::new();
    for e in std::fs::read_dir("/").unwrap().flatten() {
        let n = e.file_name().to_string_lossy().to_string();
        if !keep_top.contains(&n.as_str()) { exclude.push(e.path()); }
    }
    // Under /System keep only /System/Volumes (so the Data volume is reachable); skip the rest.
    for e in std::fs::read_dir("/System").unwrap().flatten() {
        if e.file_name() != "Volumes" { exclude.push(e.path()); }
    }
    // Under the Data volume keep only Applications.
    for e in std::fs::read_dir("/System/Volumes").unwrap().flatten() {
        if e.file_name() != "Data" { exclude.push(e.path()); }
    }
    if let Ok(rd) = std::fs::read_dir("/System/Volumes/Data") {
        for e in rd.flatten() {
            if e.file_name() != "Applications" { exclude.push(e.path()); }
        }
    }
    let opts = ScanOptions { exclude, cross_devices: true, ..Default::default() };
    let both = scan(std::path::Path::new("/"), &opts, &ScanProgress::default()).unwrap();
    let only = scan(std::path::Path::new("/Applications"), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    // Only the /Applications entry points: a direct child of "/" or of the Data volume (app bundles
    // contain unrelated folders that happen to be named "Applications").
    let apps: Vec<u32> = (0..both.len() as u32)
        .filter(|&i| both.name(i) == "Applications")
        .filter(|&i| both.parent(i).map(|p| p == 0 || both.name(p) == "Data").unwrap_or(false))
        .collect();
    // The directory exists at most once in the tree, and its size matches a direct scan of /Applications.
    assert!(apps.len() <= 2, "Applications dir nodes: {}", apps.len());
    let sum: u64 = apps.iter().map(|&i| both.size(i)).sum();
    let direct = only.size(0);
    let ratio = sum as f64 / direct.max(1) as f64;
    eprintln!("firmlink check: nodes={} sum={} direct={} ratio={:.4}", apps.len(), sum, direct, ratio);
    assert!(ratio < 1.05, "double counted: ratio {ratio}");
}

#[test]
fn filtered_largest_and_kinds_honor_the_filter() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let f = Filter { text: "f1".into(), ..Default::default() };
    let r = apply_filter(&tree, &f);
    let big = spacelyzer_engine::filter::largest_files(&tree, &r, 1000);
    assert!(!big.is_empty());
    for w in big.windows(2) { assert!(r.sizes[w[0] as usize] >= r.sizes[w[1] as usize]); }
    for &i in &big { assert!(tree.name(i).to_ascii_lowercase().contains("f1")); }
    assert_eq!(big.len() as u64, r.total_count);
    let cats = spacelyzer_engine::filter::category_totals(&tree, &r);
    assert_eq!(cats.iter().map(|c| c.0).sum::<u64>(), r.total_bytes);
    assert_eq!(cats.iter().map(|c| c.1).sum::<u64>(), r.total_count);
    // Nothing matches: both are empty, never the unfiltered list.
    let none = apply_filter(&tree, &Filter { text: "zzzqqq-no-such".into(), ..Default::default() });
    assert!(spacelyzer_engine::filter::largest_files(&tree, &none, 10).is_empty());
    assert!(spacelyzer_engine::filter::category_totals(&tree, &none).iter().all(|c| c.0 == 0 && c.1 == 0));
}

#[test]
fn ffi_rejects_stale_ids_and_foreign_filters_without_panicking() {
    use spacelyzer_engine::ffi::*;
    let t = fixture();
    let mut big = Box::new(scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap());
    big.uid = 1;
    let mut small = Box::new(scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap());
    small.uid = 2;
    // Pretend `big` had many more nodes than `small` by using ids far past the end of either.
    let (bp, sp): (*const spacelyzer_engine::Tree, *const spacelyzer_engine::Tree) = (&*big, &*small);
    let stale = small.len() as u32 + 1_000_000;
    let f = SpzFilter { category_mask: 0, has_min: 0, has_max: 0, has_from: 0, has_to: 0, min_size: 0, max_size: 0, modified_from: 0, modified_to: 0 };
    unsafe {
        // Out-of-range ids: zero/empty results, no panic.
        let n = spz_tree_node(sp, stale);
        assert_eq!((n.size, n.child_count), (0, 0));
        let s = spz_tree_name(sp, stale); assert_eq!(std::ffi::CStr::from_ptr(s).to_bytes().len(), 0); spz_string_free(s);
        let s = spz_tree_path(sp, stale); assert_eq!(std::ffi::CStr::from_ptr(s).to_bytes().len(), 0); spz_string_free(s);
        spz_tree_forget(sp as *mut _, stale);
        let l = spz_layout_new(sp, stale, 100.0, 100.0); assert_eq!(spz_layout_count(l), 0); spz_layout_free(l);
        let stale_expanded = [stale, 0];
        let rows = spz_outline_rows(sp, 0, stale_expanded.as_ptr(), 2, std::ptr::null_mut(), 0);
        assert!(rows > 0);
        assert_eq!(spz_outline_rows(sp, stale, std::ptr::null(), 0, std::ptr::null_mut(), 0), 0);
        // A filter made for one tree must not be applied to another.
        let h = spz_filter_apply(bp, std::ptr::null(), std::ptr::null(), f);
        assert!(spz_filter_size(h, 0) > 0);
        assert_eq!(spz_filter_size(h, stale), 0);
        assert_eq!(spz_filter_count(h, stale), 0);
        assert_eq!(spz_outline_rows_filtered(sp, 0, std::ptr::null(), 0, h, std::ptr::null_mut(), 0), 0);
        let l = spz_layout_new_filtered(sp, 0, 100.0, 100.0, h); assert_eq!(spz_layout_count(l), 0); spz_layout_free(l);
        let mut out = [0u32; 4];
        assert_eq!(spz_filter_largest_files(sp, h, 4, out.as_mut_ptr()), 0);
        let mut tot = [9u64; spacelyzer_engine::category::CATEGORY_COUNT * 2];
        spz_filter_category_totals(sp, h, tot.as_mut_ptr());
        assert!(tot.iter().all(|&x| x == 0));
        spz_filter_free(h);
        // Null handles are safe too.
        assert_eq!(spz_tree_node_count(std::ptr::null()), 0);
    }
}

#[test]
fn outline_sort_modes_order_siblings_and_keep_every_row() {
    use spacelyzer_engine::outline::{visible_rows, visible_rows_sorted, SortMode};
    use std::collections::HashSet;
    let tree = spacelyzer_engine::Tree::synthetic(5_000);
    let all: HashSet<u32> = (0..tree.len() as u32).collect();
    let base = visible_rows(&tree, 0, &all, None);
    for mode in [SortMode::SizeDesc, SortMode::SizeAsc, SortMode::NameAsc, SortMode::ItemsDesc, SortMode::ModifiedDesc] {
        let rows = visible_rows_sorted(&tree, 0, &all, None, mode);
        assert_eq!(rows.len(), base.len(), "{mode:?} must not drop or add rows");
        let a: HashSet<u32> = rows.iter().map(|r| r.node).collect();
        assert_eq!(a.len(), rows.len());
    }
    assert_eq!(visible_rows_sorted(&tree, 0, &all, None, SortMode::SizeDesc), base);
    let top: Vec<u32> = visible_rows_sorted(&tree, 0, &HashSet::new(), None, SortMode::SizeAsc).iter().map(|r| r.node).collect();
    assert!(top.windows(2).all(|w| tree.size(w[0]) <= tree.size(w[1])));
    let names: Vec<String> = visible_rows_sorted(&tree, 0, &HashSet::new(), None, SortMode::NameAsc).iter().map(|r| tree.name(r.node).to_lowercase()).collect();
    assert!(names.windows(2).all(|w| w[0] <= w[1]));
}

#[test]
fn filtered_outline_shows_zero_byte_matches_and_their_folders() {
    use spacelyzer_engine::filter::{apply, Filter};
    use spacelyzer_engine::outline::{visible_rows_sorted, SortMode};
    use std::collections::HashSet;
    let t = tempdir::T::new();
    let r = t.path();
    fs::create_dir_all(r.join("only_empty_files")).unwrap();
    fs::write(r.join("only_empty_files/zero.pdf"), b"").unwrap();
    fs::write(r.join("top_zero.pdf"), b"").unwrap();
    fs::write(r.join("other.bin"), vec![1u8; 4096]).unwrap();
    let tree = scan(r, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let f = apply(&tree, &Filter { extension: "pdf".into(), ..Default::default() });
    assert_eq!(f.total_count, 2);
    let all: HashSet<u32> = (0..tree.len() as u32).collect();
    for mode in [SortMode::SizeDesc, SortMode::NameAsc] {
        let rows = visible_rows_sorted(&tree, 0, &all, Some(&f), mode);
        let names: HashSet<&str> = rows.iter().map(|x| tree.name(x.node)).collect();
        assert!(names.contains("zero.pdf") && names.contains("top_zero.pdf") && names.contains("only_empty_files"), "{names:?}");
        assert!(!names.contains("other.bin"));
    }
}

#[test]
fn edge_empty_and_missing_or_file_roots() {
    let t = tempdir::T::new();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    assert_eq!(tree.len(), 1);
    assert_eq!(tree.child_count(0), 0);
    assert!(outline::visible_rows(&tree, 0, &Default::default(), None).is_empty());
    let file = t.path().join("file"); fs::write(&file, b"x").unwrap();
    assert!(scan(&file, &ScanOptions::default(), &ScanProgress::default()).is_err());
    fs::remove_file(&file).unwrap();
    assert!(scan(&file, &ScanOptions::default(), &ScanProgress::default()).is_err());
}

#[test]
fn edge_names_roundtrip_and_mixed_case_extensions() {
    let t = tempdir::T::new();
    for name in [" leading.PDF", "trailing .pDf", "line\nbreak.PDF", "quote'\"$.PDF", "日本語.PDF", ".hidden.pdf", "no-extension"] {
        fs::write(t.path().join(name), b"abc").unwrap();
    }
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    for id in 0..tree.len() as u32 { assert_eq!(tree.find(&tree.path(id)), Some(id)); }
    let result = apply_filter(&tree, &Filter { extension: ".pDf".into(), ..Default::default() });
    assert_eq!(result.total_count, 6);
    let rows = outline::visible_rows(&tree, 0, &Default::default(), Some(&result));
    assert_eq!(rows.len(), 6);
}

#[test]
fn edge_inverted_and_extreme_filter_bounds_are_empty() {
    let t = fixture();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    for f in [
        Filter { min_size: Some(u64::MAX), max_size: Some(0), ..Default::default() },
        Filter { modified_from: Some(i64::MAX), modified_to: Some(i64::MIN), ..Default::default() },
        Filter { text: "not-present-at-all".into(), ..Default::default() },
    ] {
        let result = apply_filter(&tree, &f);
        assert_eq!(result.total_count, 0); assert_eq!(result.total_bytes, 0);
        assert!(outline::visible_rows(&tree, 0, &Default::default(), Some(&result)).is_empty());
    }
}

#[test]
fn edge_sparse_and_zero_hardlinks_preserve_allocated_accounting() {
    let t = tempdir::T::new();
    let sparse = t.path().join("sparse.bin");
    std::fs::File::create(&sparse).unwrap().set_len(64 * 1024 * 1024).unwrap();
    fs::write(t.path().join("zero.pdf"), []).unwrap();
    fs::create_dir(t.path().join("nested")).unwrap();
    fs::hard_link(t.path().join("zero.pdf"), t.path().join("nested/link.pdf")).unwrap();
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    assert_eq!(tree.size(0), naive(t.path(), &mut Default::default()));
    let result = apply_filter(&tree, &Filter { extension: "pdf".into(), ..Default::default() });
    assert_eq!(result.total_count, 2); assert_eq!(result.total_bytes, 0);
    let all = (0..tree.len() as u32).collect();
    assert_eq!(outline::visible_rows(&tree, 0, &all, Some(&result)).len(), 3);
}

#[test]
fn edge_depth_and_root_child_identity_exclusion() {
    let t = tempdir::T::new();
    fs::create_dir(t.path().join("b-large")).unwrap();
    fs::write(t.path().join("b-large/file"), []).unwrap();
    let mut p = t.path().to_path_buf();
    for i in 1..=24 { p.push(format!("deep-{i}")); fs::create_dir(&p).unwrap(); }
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let large = (0..tree.len() as u32).find(|&n| tree.parent(n) == Some(0) && tree.name(n) == "b-large").unwrap();
    let expanded = (0..tree.len() as u32).filter(|&n| tree.child_count(n) > 0 && n != large).collect();
    let rows = outline::visible_rows(&tree, 0, &expanded, None);
    assert!(rows.iter().any(|r| r.depth >= 12));
    assert!(!rows.iter().any(|r| tree.name(r.node) == "file"));
}


use spacelyzer_engine::outline::{visible_rows_sorted, SortMode};
use std::{collections::HashSet,time::{UNIX_EPOCH,Duration}};
fn independent_fixture()->(std::path::PathBuf,Tree){
 static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
 let p=std::env::temp_dir().join(format!("spz-independent-{}-{}",std::process::id(),N.fetch_add(1,std::sync::atomic::Ordering::SeqCst)));
 let _=fs::remove_dir_all(&p); fs::create_dir_all(p.join("a/sub")).unwrap();fs::create_dir_all(p.join("z")).unwrap();fs::create_dir_all(p.join("empty")).unwrap();
 for (name,n,time) in [("a/sub/old.PDF",8192,1000),("a/sub/new.pdf",4096,3000),("z/middle.bin",16384,2000),("zero.pdf",0,3000)] {
  fs::write(p.join(name),vec![1u8;n]).unwrap();let f=fs::File::options().write(true).open(p.join(name)).unwrap();f.set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH+Duration::from_secs(time))).unwrap();
 }
 let t=scan(&p,&ScanOptions::default(),&ScanProgress::default()).unwrap();(p,t)
}
#[test]fn independent_all_modes_every_nested_sibling_group_and_filtered_sizes(){
 let(p,t)=independent_fixture();let expanded=(0..t.len() as u32).collect::<HashSet<_>>();let f=apply_filter(&t,&Filter{extension:"pdf".into(),..Default::default()});
 for filter in [None,Some(&f)] {for mode in [SortMode::SizeDesc,SortMode::SizeAsc,SortMode::NameAsc,SortMode::ItemsDesc,SortMode::ModifiedDesc]{
  let sizes=filter.map(|f|f.sizes.as_slice()); let rows=visible_rows_sorted(&t,0,&expanded,filter,mode);
  let expected=(1..t.len() as u32).filter(|&i|filter.map(|f|f.counts[i as usize]>0).unwrap_or(true)).collect::<HashSet<_>>(); assert_eq!(rows.iter().map(|r|r.node).collect::<HashSet<_>>(),expected);
  for parent in 0..t.len() as u32 {let ids=rows.iter().filter(|r|t.parent(r.node)==Some(parent)).map(|r|r.node).collect::<Vec<_>>();for w in ids.windows(2){let(a,b)=(w[0],w[1]);let size=|i:u32|sizes.map(|s|s[i as usize]).unwrap_or(t.size(i));assert!(match mode{SortMode::SizeDesc=>size(a)>=size(b),SortMode::SizeAsc=>size(a)<=size(b),SortMode::NameAsc=>t.name(a).to_lowercase()<=t.name(b).to_lowercase(),SortMode::ItemsDesc=>t.child_count(a)>=t.child_count(b),SortMode::ModifiedDesc=>t.mtime(a)>=t.mtime(b)},"{mode:?} parent={parent}");}}
 }}fs::remove_dir_all(p).unwrap();
}
#[test]fn independent_extension_max_size_and_mtime_inclusive_boundaries(){
 let(p,t)=independent_fixture();let id=|name:&str|(1..t.len() as u32).find(|&i|t.name(i)==name).unwrap();let old=id("old.PDF");let new=id("new.pdf");
 let f=apply_filter(&t,&Filter{extension:".PdF".into(),max_size:Some(t.own_bytes(old)),modified_from:Some(1000),modified_to:Some(3000),..Default::default()});assert_eq!(f.total_count,3);assert_eq!(f.counts[old as usize],1);assert_eq!(f.counts[new as usize],1);
 let f=apply_filter(&t,&Filter{extension:"pdf".into(),modified_from:Some(1001),modified_to:Some(2999),..Default::default()});assert_eq!(f.total_count,0);
 let f=apply_filter(&t,&Filter{extension:"pdf".into(),max_size:Some(t.own_bytes(new)),modified_from:Some(3000),..Default::default()});assert_eq!(f.total_count,2);assert_eq!(f.counts[old as usize],0);assert_eq!(f.counts[new as usize],1);
 fs::remove_dir_all(p).unwrap();
}
#[test]fn independent_zero_byte_match_is_visible_in_filtered_outline(){
 let(p,t)=independent_fixture();let zero=(1..t.len() as u32).find(|&i|t.name(i)=="zero.pdf").unwrap();let f=apply_filter(&t,&Filter{text:"zero.pdf".into(),..Default::default()});assert_eq!(f.total_count,1);let rows=visible_rows_sorted(&t,0,&HashSet::new(),Some(&f),SortMode::SizeDesc);assert!(rows.iter().any(|r|r.node==zero),"one matching zero-byte file counted but omitted from outline");let _=fs::remove_dir_all(p);
}
#[test]fn independent_sorted_ffi_invalid_inputs_and_output_cap(){
 use spacelyzer_engine::ffi::*;
 let(p,mut t)=independent_fixture();t.uid=777;let mut foreign=Tree::synthetic(40);foreign.uid=778;
 let params=SpzFilter{category_mask:0,has_min:0,has_max:0,has_from:0,has_to:0,min_size:0,max_size:0,modified_from:0,modified_to:0};
 unsafe{let h=spz_filter_apply(&foreign,std::ptr::null(),std::ptr::null(),params);let expanded=[0,u32::MAX];
  for sort in [0,1,2,3,4,999]{
   assert_eq!(spz_outline_rows_sorted(std::ptr::null(),0,std::ptr::null(),0,std::ptr::null(),sort,std::ptr::null_mut(),0),0);
   assert_eq!(spz_outline_rows_sorted(&t,u32::MAX,std::ptr::null(),0,std::ptr::null(),sort,std::ptr::null_mut(),0),0);
   assert_eq!(spz_outline_rows_sorted(&t,0,std::ptr::null(),0,h,sort,std::ptr::null_mut(),0),0);
   let n=spz_outline_rows_sorted(&t,0,expanded.as_ptr(),2,std::ptr::null(),sort,std::ptr::null_mut(),0);assert!(n>1);
   let sentinel=spacelyzer_engine::outline::Row{node:u32::MAX,depth:u32::MAX};let mut out=[sentinel;3];
   assert_eq!(spz_outline_rows_sorted(&t,0,expanded.as_ptr(),2,std::ptr::null(),sort,out.as_mut_ptr(),1),n);assert_ne!(out[0],sentinel);assert_eq!(out[1],sentinel);assert_eq!(out[2],sentinel);
  }spz_filter_free(h);
 }fs::remove_dir_all(p).unwrap();
}
#[test]fn independent_combined_filter_contradictions_and_zero_boundary(){
 let(p,t)=independent_fixture();
 for f in [Filter{min_size:Some(8193),max_size:Some(4096),..Default::default()},Filter{modified_from:Some(3001),modified_to:Some(1000),..Default::default()},Filter{extension:"pdf".into(),category_mask:1<<spacelyzer_engine::Category::Video as u8,..Default::default()}]{
  let r=apply_filter(&t,&f);assert_eq!(r.total_count,0);assert!(visible_rows_sorted(&t,0,&HashSet::new(),Some(&r),SortMode::NameAsc).is_empty());
 }
 let r=apply_filter(&t,&Filter{extension:"pdf".into(),max_size:Some(0),..Default::default()});assert_eq!(r.total_count,1);assert_eq!(r.total_bytes,0);assert_eq!(visible_rows_sorted(&t,0,&HashSet::new(),Some(&r),SortMode::NameAsc).len(),1);
 fs::remove_dir_all(p).unwrap();
}
#[test]fn independent_non_ascii_case_insensitive_name_contract(){
 let(p,_)=independent_fixture();fs::write(p.join("Ä-report.pdf"),vec![1u8;4096]).unwrap();let t=scan(&p,&ScanOptions::default(),&ScanProgress::default()).unwrap();
 let r=apply_filter(&t,&Filter{text:"ä-report".into(),..Default::default()});let _=fs::remove_dir_all(p);assert_eq!(r.total_count,1,"documented case-insensitive name search should match non-ASCII case pair");
}
#[test]fn independent_zero_match_cross_view_consistency(){
 let(p,t)=independent_fixture();let r=apply_filter(&t,&Filter{text:"zero.pdf".into(),..Default::default()});let rows=visible_rows_sorted(&t,0,&HashSet::new(),Some(&r),SortMode::NameAsc);let largest=spacelyzer_engine::filter::largest_files(&t,&r,200);let _=fs::remove_dir_all(p);assert_eq!(rows.len(),1);assert_eq!(largest.len(),1,"zero-byte matching regular file visible in outline should remain in Largest");
}

#[test]
fn unicode_name_and_extension_lowercase_contract() {
    let t = tempdir::T::new();
    for name in ["Ä-report.Ü", "Σ-book.Ε", "日本語.txt"] { fs::write(t.path().join(name), b"x").unwrap(); }
    let tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    for (text, extension) in [("ä-report", "ü"), ("σ-book", "ε"), ("日本語", "TXT")] {
        let r = apply_filter(&tree, &Filter { text: text.into(), extension: extension.into(), ..Default::default() });
        assert_eq!(r.total_count, 1);
    }
                            }

/// A removed node stays in the arena with size 0, so size alone cannot tell it from a real zero-byte file.
/// The outline hides removed rows by the table's removal list and keeps genuine empty files and empty folders.
#[test]
fn outline_hides_forgotten_rows_but_keeps_zero_byte_files() {
    let t = tempdir::T::new();
    let r = t.path();
    fs::write(r.join("keep.bin"), vec![1u8; 20_000]).unwrap();
    fs::write(r.join("gone.bin"), vec![2u8; 30_000]).unwrap();
    fs::write(r.join("empty.txt"), b"").unwrap();
    fs::create_dir_all(r.join("emptydir")).unwrap();
    fs::create_dir_all(r.join("gonedir")).unwrap();
    fs::write(r.join("gonedir/inner.bin"), vec![3u8; 10_000]).unwrap();
    fs::create_dir_all(r.join("gonezero")).unwrap();   // an empty folder that is then removed
    let tree = scan(r, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let id = |n: &str| tree.find(&format!("{}/{}", tree.root_path(), n)).unwrap();
    let names = |t: &Tree| -> Vec<String> {
        let tab = t.table();
        outline::visible_rows_sorted_in(t, &tab, 0, &Default::default(), None, outline::SortMode::NameAsc).iter().map(|r| t.name(r.node).to_string()).collect()
    };
    let before = names(&tree);
    for n in ["keep.bin", "gone.bin", "empty.txt", "emptydir", "gonedir", "gonezero"] { assert!(before.contains(&n.to_string()), "missing {n} before"); }
    let v0 = tree.table().version;
    assert!(tree.forget(id("gone.bin")).is_ok());
    assert!(tree.forget(id("gonedir")).is_ok());
    assert!(tree.forget(id("gonezero")).is_ok());   // zero-size directory: still removed from the outline
    let after = names(&tree);
    for n in ["gone.bin", "gonedir", "gonezero"] { assert!(!after.contains(&n.to_string()), "{n} still listed: {after:?}"); }
    for n in ["keep.bin", "empty.txt", "emptydir"] { assert!(after.contains(&n.to_string()), "{n} wrongly hidden: {after:?}"); }
    assert_eq!(tree.table().version, v0 + 3);
    // Forgetting an already removed node changes nothing, including the version.
    let v = tree.table().version;
    assert!(tree.forget(id("gone.bin")).is_ok());
    assert_eq!(tree.table().version, v);
    assert_eq!(tree.table().forgotten.len(), 3);
}
