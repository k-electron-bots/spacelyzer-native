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
