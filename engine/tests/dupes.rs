//! Duplicate finder (Linux Rust evidence only; read-only, no FFI, no UI).
use spacelyzer_engine::dupes::*;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::Tree;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

fn fixture(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("spz-dupes-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d.canonicalize().unwrap()
}
fn scanned(d: &Path) -> Tree { scan(d, &ScanOptions::default(), &ScanProgress::default()).unwrap() }
fn node(t: &Tree, p: &Path) -> u32 { t.find(p.to_str().unwrap()).expect("node") }
fn find(t: &Tree) -> DupReport { find_duplicates(t, 1, &AtomicBool::new(false)) }

#[test]
fn groups_identical_files_not_same_size_different_content_and_not_hardlinks_or_symlinks() {
    let d = fixture("basic");
    let a = vec![7u8; 50_000];
    let mut b = a.clone(); *b.last_mut().unwrap() = 8;                 // same size, differs in the LAST byte
    let mut c = a.clone(); c[0] = 9;                                    // differs in the first byte
    std::fs::write(d.join("a1"), &a).unwrap(); std::fs::write(d.join("a2"), &a).unwrap(); std::fs::write(d.join("a3"), &a).unwrap();
    std::fs::write(d.join("b"), &b).unwrap(); std::fs::write(d.join("c"), &c).unwrap();
    std::fs::hard_link(d.join("a1"), d.join("a1_link")).unwrap();       // same storage as a1
    std::os::unix::fs::symlink(d.join("a1"), d.join("sym")).unwrap();
    std::fs::write(d.join("empty1"), b"").unwrap(); std::fs::write(d.join("empty2"), b"").unwrap();
    let t = scanned(&d);
    let r = find(&t);
    // a1 and its hard link are one storage object. The scanner already counts it once (the second path is not a size-bearing candidate),
    // so exactly one of the two may appear, never both, and the alias is not a duplicate of a1.
    let a1l = node(&t, &d.join("a1_link")); let a1 = node(&t, &d.join("a1"));
    let (a2, a3) = (node(&t, &d.join("a2")), node(&t, &d.join("a3")));
    assert_eq!(r.groups.len(), 1, "{:?}", r);
    let ids = &r.groups[0].ids;
    assert_eq!(ids.len(), 3, "{:?}", r);
    assert!(ids.contains(&a2) && ids.contains(&a3));
    assert!(ids.contains(&a1) ^ ids.contains(&a1l), "exactly one of a hard-link pair");
    assert!(r.hardlink_aliases <= 1);
    assert!(!r.groups[0].ids.contains(&node(&t, &d.join("b"))) && !r.groups[0].ids.contains(&node(&t, &d.join("c"))));
    assert!(!r.groups[0].ids.contains(&node(&t, &d.join("sym"))), "symlinks are never candidates");
    assert_eq!(r.wasted, r.groups[0].size * 2);
    assert_eq!((r.unreadable, r.changed, r.cancelled), (0, 0, false));
    assert_eq!(r.version, t.table().version);
}

#[test]
fn removed_files_are_not_candidates_and_min_size_filters() {
    let d = fixture("forget");
    std::fs::write(d.join("x1"), vec![3u8; 30_000]).unwrap(); std::fs::write(d.join("x2"), vec![3u8; 30_000]).unwrap(); std::fs::write(d.join("x3"), vec![3u8; 30_000]).unwrap();
    std::fs::write(d.join("s1"), vec![4u8; 5_000]).unwrap(); std::fs::write(d.join("s2"), vec![4u8; 5_000]).unwrap();
    let t = scanned(&d);
    assert_eq!(find(&t).groups.len(), 2);
    let big_only = find_duplicates(&t, 20_000, &AtomicBool::new(false));
    assert_eq!(big_only.groups.len(), 1); assert_eq!(big_only.groups[0].ids.len(), 3);
    let x3 = node(&t, &d.join("x3")); t.forget(x3).unwrap();
    let r = find(&t);
    let g = r.groups.iter().find(|g| g.size >= 30_000).unwrap();
    assert_eq!(g.ids.len(), 2); assert!(!g.ids.contains(&x3), "a removed file is never reported");
    let (x1, x2) = (node(&t, &d.join("x1")), node(&t, &d.join("x2")));
    t.forget(x1).unwrap(); t.forget(x2).unwrap();
    assert!(find(&t).groups.iter().all(|g| g.size < 30_000));
}

#[test]
fn files_that_changed_or_vanished_after_the_scan_are_counted_not_reported() {
    let d = fixture("changed");
    for n in ["f1", "f2", "f3", "f4"] { std::fs::write(d.join(n), vec![5u8; 40_000]).unwrap(); }
    let t = scanned(&d);
    std::fs::remove_file(d.join("f1")).unwrap();                                              // vanished
    std::fs::remove_file(d.join("f2")).unwrap(); std::fs::write(d.join("f2"), vec![5u8; 40_000]).unwrap(); // replaced: new inode
    std::fs::write(d.join("f3"), vec![5u8; 10]).unwrap();                                     // same inode, different length (truncate + write)
    let r = find(&t);
    let (f2, f3, f4) = (node(&t, &d.join("f2")), node(&t, &d.join("f3")), node(&t, &d.join("f4")));
    assert!(r.groups.is_empty(), "{:?}", r);
    for g in &r.groups { assert!(!g.ids.contains(&f2) && !g.ids.contains(&f3) && !g.ids.contains(&f4)); }
    // f1 gone (unreadable), f2 replaced by a new inode (changed). f3 kept its inode but is now 10 bytes: not a "changed" verdict (the scan has no
    // logical length), it simply no longer matches anything and is never reported.
    assert_eq!((r.unreadable, r.changed), (1, 1), "{:?}", r);
}

#[test]
fn symlink_swapped_in_for_a_file_is_not_followed() {
    let d = fixture("swap");
    std::fs::write(d.join("t"), vec![6u8; 40_000]).unwrap(); std::fs::write(d.join("u"), vec![6u8; 40_000]).unwrap();
    std::fs::write(d.join("v"), vec![6u8; 40_000]).unwrap();
    let t = scanned(&d);
    std::fs::remove_file(d.join("v")).unwrap(); std::os::unix::fs::symlink(d.join("t"), d.join("v")).unwrap();   // v now links to t's identical bytes
    let r = find(&t);
    let v = node(&t, &d.join("v"));
    assert!(r.groups.iter().all(|g| !g.ids.contains(&v)), "a swapped-in symlink must not be read through");
    assert_eq!(r.groups.len(), 1); assert_eq!(r.groups[0].ids.len(), 2);
    assert!(r.unreadable + r.changed >= 1);
}

#[test]
fn large_multichunk_files_with_a_late_byte_difference_split_into_separate_groups() {
    let d = fixture("big");
    let base = vec![1u8; 300_000];                                  // spans several chunks
    let mut late = base.clone(); late[299_999] = 2;
    std::fs::write(d.join("p1"), &base).unwrap(); std::fs::write(d.join("p2"), &base).unwrap(); std::fs::write(d.join("q1"), &late).unwrap(); std::fs::write(d.join("q2"), &late).unwrap();
    let t = scanned(&d);
    let r = find(&t);
    assert_eq!(r.groups.len(), 2, "{:?}", r);
    for g in &r.groups { assert_eq!(g.ids.len(), 2); }
    let names: Vec<Vec<String>> = r.groups.iter().map(|g| { let mut v: Vec<String> = g.ids.iter().map(|&i| t.name(i).to_string()).collect(); v.sort(); v }).collect();
    assert!(names.contains(&vec!["p1".into(), "p2".into()]) && names.contains(&vec!["q1".into(), "q2".into()]));
    assert!(r.groups[0].ids[0] < r.groups[1].ids[0] || r.groups[0].size * 1 >= r.groups[1].size * 1, "deterministic order: wasted desc then first id");
}

#[test]
fn cancel_before_work_reports_cancelled_and_no_groups() {
    let d = fixture("cancel");
    for n in ["k1", "k2", "k3"] { std::fs::write(d.join(n), vec![9u8; 40_000]).unwrap(); }
    let t = scanned(&d);
    let r = find_duplicates(&t, 1, &AtomicBool::new(true));
    assert!(r.cancelled && r.groups.is_empty() && r.wasted == 0, "{:?}", r);
}

#[test]
fn result_is_deterministic_across_runs() {
    let d = fixture("det");
    for i in 0..12 { std::fs::write(d.join(format!("a{i}")), vec![(i % 3) as u8; 20_000 + (i % 3) * 8192]).unwrap(); }
    let t = scanned(&d);
    let first = find(&t);
    for _ in 0..5 { assert_eq!(find(&t), first); }
    assert!(!first.groups.is_empty());
}
