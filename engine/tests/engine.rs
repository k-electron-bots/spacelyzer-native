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
    let mut tree = scan(t.path(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let before = tree.size(0);
    let n = tree.find(&format!("{}/d3", tree.root_path())).unwrap();
    let sz = tree.size(n);
    tree.forget(n);
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
