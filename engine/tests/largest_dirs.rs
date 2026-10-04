//! Largest folders: deterministic order, root and removed folders excluded, sizes from one capture (Linux Rust evidence only).
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::Tree;
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("spz-ldirs-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d.canonicalize().unwrap()
}
fn scanned(d: &Path) -> Tree { scan(d, &ScanOptions::default(), &ScanProgress::default()).unwrap() }
fn node(t: &Tree, p: &Path) -> u32 { t.find(p.to_str().unwrap()).expect("node") }
fn dirs(t: &Tree, cap: u32) -> (Vec<u32>, Vec<u64>, u64, i32) {
    let mut ids = vec![0u32; cap as usize]; let mut sizes = vec![0u64; cap as usize]; let (mut v, mut st) = (0u64, -1i32);
    let n = unsafe { spz_largest_dirs_status(t as *const Tree, cap, ids.as_mut_ptr(), sizes.as_mut_ptr(), u64::MAX, &mut v, &mut st) } as usize;
    ids.truncate(n); sizes.truncate(n); (ids, sizes, v, st)
}

#[test]
fn folders_rank_by_cumulative_size_exclude_root_and_nest_both_ways() {
    let d = fixture("rank");
    std::fs::create_dir_all(d.join("big/inner")).unwrap(); std::fs::create_dir_all(d.join("small")).unwrap(); std::fs::create_dir_all(d.join("empty")).unwrap();
    std::fs::write(d.join("big/inner/f"), vec![1u8; 200_000]).unwrap(); std::fs::write(d.join("big/g"), vec![1u8; 20_000]).unwrap(); std::fs::write(d.join("small/h"), vec![1u8; 8_000]).unwrap();
    let t = scanned(&d);
    let (ids, sizes, _v, st) = dirs(&t, 10);
    assert_eq!(st, 0);
    let (big, inner, small) = (node(&t, &d.join("big")), node(&t, &d.join("big/inner")), node(&t, &d.join("small")));
    assert_eq!(ids, vec![big, inner, small], "root excluded; the empty folder (size 0) excluded; nested folder listed on its own; ordered by cumulative size");
    assert!(sizes[0] >= sizes[1] && sizes[1] >= sizes[2] && sizes[0] > sizes[1], "a parent's cumulative size includes the child");
    assert_eq!(sizes[0], t.size(big)); assert!(!ids.contains(&0));
    let (cap2, ..) = dirs(&t, 2); assert_eq!(cap2, vec![big, inner], "cap respected");
    assert_eq!(dirs(&t, 0).0.len(), 0);
}

#[test]
fn removed_folder_and_its_subfolders_leave_the_list_and_sizes_come_from_one_table() {
    let d = fixture("forget");
    std::fs::create_dir_all(d.join("a/sub")).unwrap(); std::fs::create_dir_all(d.join("b")).unwrap();
    std::fs::write(d.join("a/sub/f"), vec![1u8; 100_000]).unwrap(); std::fs::write(d.join("b/g"), vec![1u8; 40_000]).unwrap();
    let t = scanned(&d);
    let (a, sub, b) = (node(&t, &d.join("a")), node(&t, &d.join("a/sub")), node(&t, &d.join("b")));
    assert_eq!(dirs(&t, 10).0, vec![a, sub, b]);
    let v0 = t.table().version;
    t.forget(a).unwrap();
    let (ids, sizes, v, st) = dirs(&t, 10);
    assert_eq!(st, 0); assert_eq!(v, v0 + 1, "version reported is the table the list was read from");
    assert_eq!(ids, vec![b], "a removed folder and the folders inside it are gone");
    assert_eq!(sizes, vec![t.size(b)]);
}

#[test]
fn bad_arguments_are_status_3_and_a_stale_expected_version_is_status_1() {
    let d = fixture("args"); std::fs::create_dir_all(d.join("x")).unwrap(); std::fs::write(d.join("x/f"), b"abc").unwrap();
    let t = scanned(&d);
    let (mut v, mut st) = (0u64, -1i32);
    let n = unsafe { spz_largest_dirs_status(&t as *const Tree, 4, std::ptr::null_mut(), std::ptr::null_mut(), u64::MAX, &mut v, &mut st) };
    assert_eq!((n, st), (0, 3));
    let mut ids = [0u32; 4]; let mut sizes = [0u64; 4];
    let n = unsafe { spz_largest_dirs_status(&t as *const Tree, 4, ids.as_mut_ptr(), sizes.as_mut_ptr(), 999, &mut v, &mut st) };
    assert_eq!((n, st), (0, 1));
    let n = unsafe { spz_largest_dirs_status(std::ptr::null(), 4, ids.as_mut_ptr(), sizes.as_mut_ptr(), u64::MAX, &mut v, &mut st) };
    assert_eq!((n, st), (0, 3));
}

/// Property: with a cap larger than the tree, a node is listed exactly when it is a directory or package, not the root, not removed, and
/// has a non-zero cumulative size; the list is ordered by (size desc, id asc) and every size equals the table's.
fn assert_list_matches_rule(t: &Tree) {
    let n = t.len() as u32;
    let (ids, sizes, _v, st) = dirs(t, n + 5);
    assert_eq!(st, 0);
    let tab = t.table();
    let dead = tab.dead_mask(t);
    let want: std::collections::BTreeSet<u32> = (1..n).filter(|&i| {
        let k = t.kind(i);
        (k == spacelyzer_engine::tree::Kind::Directory || k == spacelyzer_engine::tree::Kind::Package) && t.size(i) > 0 && !dead.as_ref().map_or(false, |d| d[i as usize])
    }).collect();
    let got: std::collections::BTreeSet<u32> = ids.iter().copied().collect();
    assert_eq!(got, want, "listed set must follow the rule");
    assert_eq!(ids.len(), got.len(), "no duplicates");
    for (i, id) in ids.iter().enumerate() { assert_eq!(sizes[i], t.size(*id)); }
    assert!(ids.windows(2).zip(sizes.windows(2)).all(|(w, s)| s[0] > s[1] || (s[0] == s[1] && w[0] < w[1])), "size desc, then id asc");
}

#[test]
fn equal_sizes_break_ties_by_id_and_packages_are_listed() {
    let d = fixture("ties");
    for name in ["p1", "p2", "p3.app"] { std::fs::create_dir_all(d.join(name)).unwrap(); std::fs::write(d.join(name).join("f"), vec![1u8; 50_000]).unwrap(); }
    let t = scanned(&d);
    assert_list_matches_rule(&t);
    let (ids, sizes, ..) = dirs(&t, 10);
    assert_eq!(ids.len(), 3);
    assert!(sizes.iter().all(|s| *s == sizes[0]), "same content, same cumulative size");
    assert!(ids.windows(2).all(|w| w[0] < w[1]), "ties ordered by node id");
    let app = node(&t, &d.join("p3.app"));
    assert!(ids.contains(&app), "a package is listed like a folder");
    assert!(t.kind(app) == spacelyzer_engine::tree::Kind::Package, "the scanner classifies .app by name, so this folder is a Package");
    assert!(t.kind(node(&t, &d.join("p1"))) == spacelyzer_engine::tree::Kind::Directory);
}

#[test]
fn trees_with_only_empty_folders_or_only_files_list_nothing() {
    let d = fixture("zero");
    std::fs::create_dir_all(d.join("e1/e2")).unwrap(); std::fs::create_dir_all(d.join("e3")).unwrap();
    let t = scanned(&d);
    assert_list_matches_rule(&t);
    assert!(dirs(&t, 10).0.is_empty(), "empty folders have no size, so they are not listed");
    let d2 = fixture("filesonly"); std::fs::write(d2.join("a"), vec![1u8; 10_000]).unwrap();
    let t2 = scanned(&d2);
    assert!(dirs(&t2, 10).0.is_empty(), "only the root holds files, and the root is never listed");
}

#[test]
fn hard_links_across_folders_follow_the_same_rule_as_the_table() {
    let d = fixture("hl");
    std::fs::create_dir_all(d.join("a")).unwrap(); std::fs::create_dir_all(d.join("b")).unwrap();
    std::fs::write(d.join("a/f"), vec![1u8; 90_000]).unwrap(); std::fs::hard_link(d.join("a/f"), d.join("b/f")).unwrap();
    let t = scanned(&d);
    assert_list_matches_rule(&t);   // whichever folder the scan charged the shared data to, the list and the table agree and no zero folder appears
}

#[test]
fn lists_stay_well_formed_while_folders_are_forgotten_concurrently() {
    let d = fixture("conc");
    for i in 0..12 { std::fs::create_dir_all(d.join(format!("d{i}/s"))).unwrap(); for j in 0..4 { std::fs::write(d.join(format!("d{i}/s/f{j}")), vec![1u8; 4096 * (i + 1)]).unwrap(); } }
    let t = scanned(&d);
    let n = t.len() as u32;
    let stop = std::sync::atomic::AtomicBool::new(false);
    let bad = std::sync::atomic::AtomicUsize::new(0); let reads = std::sync::atomic::AtomicUsize::new(0);
    std::thread::scope(|s| {
        for _ in 0..3 {
            s.spawn(|| {
                let mut last_v = 0u64;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    let (ids, sizes, v, st) = dirs(&t, n);
                    let ok = st == 0 && v >= last_v && !ids.contains(&0) && sizes.iter().all(|s| *s > 0)
                        && sizes.windows(2).all(|w| w[0] >= w[1]) && { let mut u = ids.clone(); u.sort_unstable(); u.dedup(); u.len() == ids.len() };
                    if !ok { bad.fetch_add(1, std::sync::atomic::Ordering::Relaxed); }
                    last_v = v; reads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            });
        }
        for id in 1..n { let _ = t.forget(id); std::thread::yield_now(); }
        let target = reads.load(std::sync::atomic::Ordering::Relaxed) + 6;
        let t0 = std::time::Instant::now();
        while reads.load(std::sync::atomic::Ordering::Relaxed) < target && t0.elapsed().as_secs() < 20 { std::thread::yield_now(); }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
    });
    assert!(reads.load(std::sync::atomic::Ordering::Relaxed) > 0);
    assert_eq!(bad.load(std::sync::atomic::Ordering::Relaxed), 0, "a list was malformed or a version went backwards");
    assert!(dirs(&t, n).0.is_empty(), "everything removed, nothing listed");
}

/// Several readouts of ONE table, before and after removals, on one fixture (Rust side only; the Swift views are not exercised, and this is
/// not a proof for other trees). Largest files: exactly the live regular files, each once, sizes equal to the table through the FFI.
fn assert_surfaces_agree(t: &Tree) {
    let tab = t.table();
    let n = t.len() as u32;
    let dead = tab.dead_mask(t);
    let alive = |i: u32| !dead.as_ref().map_or(false, |d| d[i as usize]);
    // 1. Kinds bytes (non-directory nodes) + live directories' own bytes == root size.
    let kinds_bytes: u64 = t.category_totals_in(&tab).iter().map(|c| c.0).sum();
    let dir_own: u64 = (0..n).filter(|&i| alive(i) && t.kind(i) == spacelyzer_engine::tree::Kind::Directory).map(|i| t.own_bytes_in(&tab.sizes, i)).sum();
    assert_eq!(kinds_bytes + dir_own, tab.sizes[0], "kinds + directory bytes must add up to the root");
    // 2. Largest files through the FFI (ids AND sizes): the exact live regular-file set, unique, sizes equal to the table, largest first.
    let cap = n + 5;
    let mut ids = vec![0u32; cap as usize]; let mut sizes = vec![0u64; cap as usize]; let (mut v, mut st) = (0u64, -1i32);
    let got = unsafe { spz_largest_sized_status(t as *const Tree, std::ptr::null(), cap, ids.as_mut_ptr(), sizes.as_mut_ptr(), u64::MAX, &mut v, &mut st) } as usize;
    assert_eq!(st, 0); assert_eq!(v, tab.version);
    ids.truncate(got); sizes.truncate(got);
    let want: std::collections::BTreeSet<u32> = (0..n).filter(|&i| alive(i) && t.kind(i) == spacelyzer_engine::tree::Kind::File).collect();
    let have: std::collections::BTreeSet<u32> = ids.iter().copied().collect();
    assert_eq!(have, want, "exactly the live regular files");
    assert_eq!(ids.len(), have.len(), "each once");
    for (i, id) in ids.iter().enumerate() { assert_eq!(sizes[i], tab.sizes[*id as usize], "size equals the table"); }
    assert!(sizes.windows(2).all(|w| w[0] >= w[1]), "largest first");
    // 3. Folders: the exact live-folder rule (set, order, sizes) from the property check.
    assert_list_matches_rule(t);
}

#[test]
fn kinds_largest_folders_and_root_agree_before_and_after_removals() {
    let d = fixture("surfaces");
    std::fs::create_dir_all(d.join("a/inner")).unwrap(); std::fs::create_dir_all(d.join("b.app/Contents")).unwrap(); std::fs::create_dir_all(d.join("c")).unwrap();
    std::fs::write(d.join("a/inner/f.txt"), vec![1u8; 70_000]).unwrap(); std::fs::write(d.join("a/g.png"), vec![1u8; 30_000]).unwrap();
    std::fs::write(d.join("b.app/Contents/x.bin"), vec![1u8; 55_000]).unwrap(); std::fs::write(d.join("c/h"), vec![1u8; 9_000]).unwrap();
    std::fs::hard_link(d.join("c/h"), d.join("a/h2")).unwrap(); std::os::unix::fs::symlink(d.join("c/h"), d.join("a/link")).unwrap();
    let t = scanned(&d);
    assert_surfaces_agree(&t);
    for rel in ["a/inner", "b.app", "c"] { t.forget(node(&t, &d.join(rel))).unwrap(); assert_surfaces_agree(&t); }
    t.forget(node(&t, &d.join("a"))).unwrap(); assert_surfaces_agree(&t);
}
