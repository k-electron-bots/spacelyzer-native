//! Scanned-identity comparison and the C boundary of the inspect functions (Linux Rust evidence only, unless a Mac run says otherwise).
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::inspect::{Inspect, IdentityCheck as C};
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::Tree;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

#[cfg(feature = "failpoints")]
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
fn fixture(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("spz-ident-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d.canonicalize().unwrap()
}
fn scanned(d: &Path) -> Tree { scan(d, &ScanOptions::default(), &ScanProgress::default()).unwrap() }
fn node(t: &Tree, p: &Path) -> u32 { t.find(p.to_str().unwrap()).expect("node") }
fn check(t: &Tree, id: u32) -> i32 { unsafe { spz_tree_check_identity(t as *const Tree, id) } }

#[test]
fn unchanged_items_are_same_including_root() {
    let d = fixture("same"); std::fs::create_dir(d.join("sub")).unwrap(); std::fs::write(d.join("sub/f"), b"abc").unwrap();
    let t = scanned(&d);
    assert_eq!(check(&t, 0), C::Same as i32);
    assert_eq!(check(&t, node(&t, &d.join("sub"))), C::Same as i32);
    assert_eq!(check(&t, node(&t, &d.join("sub/f"))), C::Same as i32);
}

#[test]
fn same_kind_replacement_with_new_inode_is_different_not_same() {
    let d = fixture("repl"); std::fs::write(d.join("f"), b"abc").unwrap();
    let t = scanned(&d); let id = node(&t, &d.join("f"));
    // Same name, same kind, same size and a fresh file: only the inode tells them apart. Keep the old inode alive so it cannot be reused.
    let keep = std::fs::File::open(d.join("f")).unwrap();
    std::fs::remove_file(d.join("f")).unwrap(); std::fs::write(d.join("f"), b"abc").unwrap();
    assert_eq!(check(&t, id), C::Different as i32);
    drop(keep);
}

#[test]
fn kind_swap_gone_and_ancestor_symlink_are_refused_distinctly() {
    let d = fixture("kinds");
    std::fs::create_dir_all(d.join("a/b")).unwrap(); std::fs::write(d.join("a/b/f"), b"1").unwrap(); std::fs::write(d.join("g"), b"1").unwrap(); std::fs::write(d.join("h"), b"1").unwrap();
    let t = scanned(&d);
    let (f, g, h) = (node(&t, &d.join("a/b/f")), node(&t, &d.join("g")), node(&t, &d.join("h")));
    std::fs::remove_file(d.join("g")).unwrap(); std::fs::create_dir(d.join("g")).unwrap();
    assert_eq!(check(&t, g), C::Different as i32, "file replaced by directory");
    std::fs::remove_file(d.join("h")).unwrap();
    assert_eq!(check(&t, h), C::Gone as i32);
    std::fs::rename(d.join("a"), d.join("a_real")).unwrap(); std::os::unix::fs::symlink(d.join("a_real"), d.join("a")).unwrap();
    assert_eq!(check(&t, f), C::AncestorSymlink as i32, "an ancestor below the root became a symlink");
}

#[test]
fn hard_link_dedup_does_not_make_either_link_look_changed() {
    let d = fixture("hl"); std::fs::write(d.join("a"), vec![1u8; 9000]).unwrap(); std::fs::hard_link(d.join("a"), d.join("b")).unwrap();
    let t = scanned(&d);
    let (a, b) = (node(&t, &d.join("a")), node(&t, &d.join("b")));
    assert_eq!(check(&t, a), C::Same as i32); assert_eq!(check(&t, b), C::Same as i32);
}

#[test]
fn non_utf8_name_is_unaddressable_and_errors_are_distinct() {
    let d = fixture("lossy");
    let bad = d.join(std::ffi::OsStr::from_bytes(b"bad\xff"));
    if std::fs::write(&bad, b"x").is_err() { return; } // filesystem refuses non-UTF-8 names: nothing to test here
    let t = scanned(&d);
    let id = (1..t.len() as u32).find(|&i| t.name(i).contains('\u{FFFD}')).expect("lossy name node");
    assert_eq!(check(&t, id), C::Unaddressable as i32);
    // Boundary errors: bad id, null tree, tree with no recorded identity.
    assert_eq!(check(&t, 9999), -1);
    assert_eq!(unsafe { spz_tree_check_identity(std::ptr::null(), 0) }, -1);
    assert_eq!(check(&Tree::synthetic(10), 1), C::NoScannedIdentity as i32);
}

fn zeroed() -> Inspect { unsafe { std::mem::zeroed() } }
fn sentinel() -> Inspect { let mut s = zeroed(); s.allocated = 0xAAAA; s.ino = 0xBBBB; s.kind = 9; s }

#[test]
fn inspect_path_boundary_contract() {
    let d = fixture("abi"); std::fs::write(d.join("f"), b"hello").unwrap();
    let p = CString::new(d.join("f").as_os_str().as_bytes()).unwrap();
    let mut out = sentinel();
    // null arguments: -1, `out` untouched. (No dangling pointers are used.)
    assert_eq!(unsafe { spz_inspect_path(std::ptr::null(), &mut out) }, -1);
    assert_eq!(unsafe { spz_inspect_path(p.as_ptr(), std::ptr::null_mut()) }, -1);
    assert_eq!(out, sentinel());
    // missing path: ENOENT, `out` untouched.
    let missing = CString::new(d.join("nope").as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { spz_inspect_path(missing.as_ptr(), &mut out) }, 2);
    assert_eq!(out, sentinel());
    // not a directory component: ENOTDIR, a different positive errno.
    let notdir = CString::new(d.join("f/x").as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { spz_inspect_path(notdir.as_ptr(), &mut out) }, 20);
    assert_eq!(out, sentinel());
    // success writes the struct. A non-UTF-8 path is used byte-for-byte.
    assert_eq!(unsafe { spz_inspect_path(p.as_ptr(), &mut out) }, 0); assert_eq!(out.logical, 5);
    let weird = d.join(std::ffi::OsStr::from_bytes(b"w\xfe\xff"));
    if std::fs::write(&weird, b"xy").is_ok() {
        let wp = CString::new(weird.as_os_str().as_bytes()).unwrap(); let mut o2 = zeroed();
        assert_eq!(unsafe { spz_inspect_path(wp.as_ptr(), &mut o2) }, 0); assert_eq!(o2.logical, 2);
    }
}

#[test]
fn layout_export_matches_rust_struct_and_header_numbers() {
    let mut v = [0u64; 7]; unsafe { spz_inspect_layout(v.as_mut_ptr()); }
    assert_eq!(v, [48, 8, 16, 24, 32, 40, 44]);
    unsafe { spz_inspect_layout(std::ptr::null_mut()); } // must not crash
}

#[cfg(feature = "failpoints")]
#[test]
fn caught_panic_returns_minus_two_and_leaves_out_untouched() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let d = fixture("panic"); std::fs::write(d.join("f"), b"x").unwrap();
    let p = CString::new(d.join("f").as_os_str().as_bytes()).unwrap();
    let t = scanned(&d); let id = node(&t, &d.join("f"));
    let before = spz_engine_panic_count(); let mut out = sentinel();
    spacelyzer_engine::tree::set_failpoint(9);
    assert_eq!(unsafe { spz_inspect_path(p.as_ptr(), &mut out) }, -2);
    spacelyzer_engine::tree::set_failpoint(9);
    assert_eq!(check(&t, id), -2);
    spacelyzer_engine::tree::set_failpoint(0);
    assert_eq!(out, sentinel()); assert!(spz_engine_panic_count() >= before + 2);
    assert_eq!(unsafe { spz_inspect_path(p.as_ptr(), &mut out) }, 0, "works again after the failpoint is cleared");
}

fn review(t: &Tree, id: u32) -> (i32, spacelyzer_engine::inspect::SpzReview) {
    let mut r: spacelyzer_engine::inspect::SpzReview = unsafe { std::mem::zeroed() }; r.live_state = 77; r.live.ino = 0xDEAD;
    let rc = unsafe { spz_tree_review(t as *const Tree, id, &mut r) }; (rc, r)
}

#[test]
fn review_carries_live_data_only_when_the_leaf_was_observed_and_labels_the_item() {
    let d = fixture("review"); std::fs::create_dir_all(d.join("a")).unwrap(); std::fs::write(d.join("f"), b"abcd").unwrap(); std::fs::write(d.join("g"), b"x").unwrap(); std::fs::write(d.join("h"), b"y").unwrap(); std::fs::write(d.join("a/z"), b"z").unwrap();
    let t = scanned(&d); let (f, g, h, z) = (node(&t, &d.join("f")), node(&t, &d.join("g")), node(&t, &d.join("h")), node(&t, &d.join("a/z")));
    // Same: live data comes from the same lstat, equal to a direct inspect.
    let (rc, r) = review(&t, f); assert_eq!(rc, C::Same as i32); assert_eq!(r.live_state, 1);
    let direct = spacelyzer_engine::inspect::inspect(&d.join("f")).unwrap(); assert_eq!((r.live.dev, r.live.ino, r.live.logical), (direct.dev, direct.ino, 4));
    // Different (replaced by a directory): live data is present but tagged as a DIFFERENT item.
    std::fs::remove_file(d.join("g")).unwrap(); std::fs::create_dir(d.join("g")).unwrap();
    let (rc, r) = review(&t, g); assert_eq!(rc, C::Different as i32); assert_eq!(r.live_state, 2); assert_eq!(r.live.kind, 1);
    // Gone: no live data, zeroed.
    std::fs::remove_file(d.join("h")).unwrap();
    let (rc, r) = review(&t, h); assert_eq!(rc, C::Gone as i32); assert_eq!(r.live_state, 0); assert_eq!((r.live.ino, r.live.logical), (0, 0));
    // Ancestor symlink: leaf never inspected, so no live data.
    std::fs::rename(d.join("a"), d.join("a2")).unwrap(); std::os::unix::fs::symlink(d.join("a2"), d.join("a")).unwrap();
    let (rc, r) = review(&t, z); assert_eq!(rc, C::AncestorSymlink as i32); assert_eq!(r.live_state, 0); assert_eq!(r.live.ino, 0);
    // Errors: out untouched.
    let (rc, r) = review(&t, 9999); assert_eq!(rc, -1); assert_eq!((r.live_state, r.live.ino), (77, 0xDEAD));
    assert_eq!(unsafe { spz_tree_review(&t as *const Tree, f, std::ptr::null_mut()) }, -1);
}

#[test]
fn review_of_lossy_name_and_missing_identity_never_inspects() {
    let d = fixture("review2"); let bad = d.join(std::ffi::OsStr::from_bytes(b"q\xff")); if std::fs::write(&bad, b"x").is_err() { return; }
    let t = scanned(&d); let id = (1..t.len() as u32).find(|&i| t.name(i).contains('\u{FFFD}')).unwrap();
    let (rc, r) = review(&t, id); assert_eq!(rc, C::Unaddressable as i32); assert_eq!((r.live_state, r.live.ino), (0, 0));
    let syn = Tree::synthetic(5); let (rc, r) = review(&syn, 1); assert_eq!(rc, C::NoScannedIdentity as i32); assert_eq!(r.live_state, 0);
}

#[test]
fn review_layout_matches_header_numbers() {
    let mut v = [0u64; 3]; unsafe { spz_review_layout(v.as_mut_ptr()); } assert_eq!(v, [56, 8, 48]);
    unsafe { spz_review_layout(std::ptr::null_mut()); }
}

#[cfg(feature = "failpoints")]
#[test]
fn review_caught_panic_returns_minus_two_and_leaves_out_untouched() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let d = fixture("review3"); std::fs::write(d.join("f"), b"x").unwrap(); let t = scanned(&d); let id = node(&t, &d.join("f"));
    spacelyzer_engine::tree::set_failpoint(9);
    let (rc, r) = review(&t, id); spacelyzer_engine::tree::set_failpoint(0);
    assert_eq!(rc, -2); assert_eq!((r.live_state, r.live.ino), (77, 0xDEAD));
}
