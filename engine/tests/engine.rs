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
            let p = std::env::temp_dir().join(format!("spz-test-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
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
