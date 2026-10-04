//! Skipped-entry accounting through the C ABI (Linux Rust evidence only). SeparateVolume cannot be produced on a single test filesystem and is untested here.
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::{SkipReason, Tree};
use std::ffi::{CStr, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Creating a non-UTF-8 file name is refused by some filesystems (APFS returns EILSEQ, errno 92; the first hosted-macOS run failed here). That is a fixture
/// limit, not an engine result: on those platforms the test reports SKIPPED and does not claim to have exercised anything. On Linux the creation must work,
/// so a failure there still fails the test (no silent pass).
#[allow(dead_code)]
fn made(r: std::io::Result<()>) -> bool {
    match r {
        Ok(()) => true,
        Err(e) if e.raw_os_error() == Some(92) && !cfg!(target_os = "linux") => { eprintln!("SKIPPED: this filesystem refuses non-UTF-8 names (EILSEQ); the case was NOT exercised"); false }
        Err(e) => panic!("fixture creation failed: {e}"),
    }
}

fn fixture(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("spz-skip-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d.canonicalize().unwrap()
}
fn scan_with(d: &Path, excl: Vec<PathBuf>) -> Tree { scan(d, &ScanOptions { exclude: excl, ..Default::default() }, &ScanProgress::default()).unwrap() }
fn item(t: &Tree, i: u32) -> (Option<String>, u8, u8, i32) {
    let (mut r, mut l, mut st) = (99u8, 99u8, -1i32);
    let p = unsafe { spz_tree_skipped_item_status(t, i, &mut r, &mut l, &mut st) };
    let s = if p.is_null() { None } else { let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned(); unsafe { spz_string_free(p) }; Some(s) };
    (s, r, l, st)
}
fn counts(t: &Tree) -> ([u32; 4], i32) { let mut o = [77u32; 4]; let mut st = -1; unsafe { spz_tree_skipped_counts_status(t, o.as_mut_ptr(), &mut st) }; (o, st) }

#[test]
fn order_is_sorted_and_stable_across_scans_and_counts_match_the_list() {
    let d = fixture("order");
    let mut excl = Vec::new();
    for i in (0..24).rev() { std::fs::create_dir_all(d.join(format!("x{i:02}/sub"))).unwrap(); std::fs::write(d.join(format!("x{i:02}/sub/f")), vec![1u8; 5000]).unwrap(); excl.push(d.join(format!("x{i:02}"))); }
    std::fs::write(d.join("keep"), vec![1u8; 5000]).unwrap();
    let first = scan_with(&d, excl.clone());
    let paths: Vec<String> = (0..first.skipped.len() as u32).map(|i| item(&first, i).0.unwrap()).collect();
    assert_eq!(paths.len(), 24);
    let mut sorted = paths.clone(); sorted.sort();
    assert_eq!(paths, sorted, "sorted by path");
    for _ in 0..8 { let t = scan_with(&d, excl.clone()); let p2: Vec<String> = (0..t.skipped.len() as u32).map(|i| item(&t, i).0.unwrap()).collect(); assert_eq!(p2, paths, "same index, same entry on every scan"); }
    let (c, st) = counts(&first); assert_eq!(st, 0);
    assert_eq!(c, [0, 0, 0, 24]);
    assert_eq!(c.iter().sum::<u32>(), unsafe { spz_tree_skipped_count(&first) });
    for i in 0..24 { let (_, r, l, st) = item(&first, i); assert_eq!((r, l, st), (SkipReason::UserExcluded as u8, 0, 0)); }
}

#[test]
fn bad_index_and_null_arguments_are_invalid_and_leave_outputs_untouched() {
    let d = fixture("bad");
    std::fs::create_dir_all(d.join("a")).unwrap();
    let t = scan_with(&d, vec![d.join("a")]);
    assert_eq!(t.skipped.len(), 1);
    let (p, r, l, st) = item(&t, 1);
    assert!(p.is_none()); assert_eq!((r, l, st), (99, 99, 3), "a bad index is INVALID, not a real-looking reason");
    let (p, ..) = { let (mut r, mut l, mut st) = (99u8, 99u8, -1i32); let q = unsafe { spz_tree_skipped_item_status(std::ptr::null(), 0, &mut r, &mut l, &mut st) }; (q.is_null(), st) }; assert!(p);
    let mut o = [77u32; 4]; let mut st = -1;
    unsafe { spz_tree_skipped_counts_status(std::ptr::null(), o.as_mut_ptr(), &mut st) }; assert_eq!((o, st), ([77; 4], 3));
    st = -1; unsafe { spz_tree_skipped_counts_status(&t, std::ptr::null_mut(), &mut st) }; assert_eq!(st, 3);
    // the old accessor still returns a value for a bad index (documented reason for the new one)
    assert_eq!(unsafe { spz_tree_skipped_reason(&t, 5) }, 1);
}

#[test]
fn a_non_utf8_path_is_flagged_lossy_and_a_utf8_one_is_not() {
    let d = fixture("lossy");
    let bad = d.join(OsStr::from_bytes(b"bad\xffname"));
    if !made(std::fs::create_dir_all(&bad)) { return; } std::fs::create_dir_all(d.join("good")).unwrap();
    // exclusion matches on the lossy rendering, which is what a user-supplied (UTF-8) exclude list can express
    let lossy_name = d.join(String::from_utf8_lossy(b"bad\xffname").into_owned());
    let t = scan_with(&d, vec![lossy_name, d.join("good")]);
    assert_eq!(t.skipped.len(), 2, "{:?}", t.skipped);
    let flags: Vec<(String, u8)> = (0..2).map(|i| { let (p, _, l, st) = item(&t, i); assert_eq!(st, 0); (p.unwrap(), l) }).collect();
    let bad_flag = flags.iter().find(|(p, _)| p.contains('\u{FFFD}')).expect("lossy entry").1;
    let good_flag = flags.iter().find(|(p, _)| p.ends_with("/good")).expect("utf8 entry").1;
    assert_eq!((bad_flag, good_flag), (1, 0));
}

#[test]
fn permission_denied_directories_are_counted_when_the_test_user_cannot_read_them() {
    use std::os::unix::fs::PermissionsExt;
    let d = fixture("perm");
    std::fs::create_dir_all(d.join("locked")).unwrap(); std::fs::write(d.join("locked/f"), vec![1u8; 5000]).unwrap();
    std::fs::set_permissions(d.join("locked"), std::fs::Permissions::from_mode(0o000)).unwrap();
    let readable_anyway = std::fs::read_dir(d.join("locked")).is_ok();           // root ignores the mode bits
    let t = scan_with(&d, vec![]);
    std::fs::set_permissions(d.join("locked"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let (c, st) = counts(&t); assert_eq!(st, 0);
    if readable_anyway { assert_eq!(c, [0, 0, 0, 0], "running as a user that can read it (e.g. root): nothing to skip, assertion on the denied path not exercised"); }
    else { assert_eq!(c, [1, 0, 0, 0]); let (p, r, l, st) = item(&t, 0); assert!(p.unwrap().ends_with("/locked")); assert_eq!((r, l, st), (SkipReason::PermissionDenied as u8, 0, 0)); }
}

/// Verifier repro: siblings `a\xff`, `a\xfe` and a literal `a<U+FFFD>` used to collapse to one lossy node name (the literal directory was then walked three
/// times and its contents counted three times). Now the two non-UTF-8 entries are left out and listed, and only the real literal directory is a node.
#[test]
fn lossy_name_siblings_cannot_alias_a_real_node_or_overmatch_an_exclusion() {
    use std::os::unix::ffi::OsStrExt;
    let d = std::env::temp_dir().join(format!("skp-lossy-{}", std::process::id())); let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); let d = d.canonicalize().unwrap();
    for n in [&b"a\xff"[..], &b"a\xfe"[..], "a\u{FFFD}".as_bytes()] { let p = d.join(std::ffi::OsStr::from_bytes(n)); if !made(std::fs::create_dir_all(&p)) { return; } std::fs::write(p.join("f"), vec![1u8; 5000]).unwrap(); }
    let t = scan(&d, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    let fs = (1..t.len() as u32).filter(|&i| t.name(i) == "f").count();
    assert_eq!(fs, 1, "only the real literal directory is walked, once");
    assert_eq!((1..t.len() as u32).filter(|&i| t.name(i).starts_with('a')).count(), 1);
    assert_eq!(t.skipped.iter().filter(|s| s.lossy).count(), 2);
    assert_eq!(t.skipped_counts()[1], 2);
    let t2 = scan(&d, &ScanOptions { exclude: vec![d.join("a\u{FFFD}")], ..Default::default() }, &ScanProgress::default()).unwrap();
    assert_eq!(t2.skipped.iter().filter(|s| s.reason as u8 == 3).count(), 1, "the literal exclusion matches the one real directory only");
    assert_eq!((1..t2.len() as u32).filter(|&i| t2.name(i) == "f").count(), 0);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_non_utf8_scan_root_is_refused_and_a_non_utf8_exclusion_matches_nothing() {
    let base = std::env::temp_dir().join(format!("skp-root-{}", std::process::id())); let _ = std::fs::remove_dir_all(&base);
    let bad = base.join(OsStr::from_bytes(b"r\xff")); if !made(std::fs::create_dir_all(&bad)) { return; } std::fs::write(bad.join("f"), b"x").unwrap();
    let e = scan(&bad, &ScanOptions::default(), &ScanProgress::default()).err().expect("must refuse");
    assert_eq!(e.kind(), std::io::ErrorKind::InvalidInput);
    // A non-UTF-8 exclusion must not overmatch the real U+FFFD-named sibling.
    let ok = base.join("ok"); std::fs::create_dir_all(ok.join("a\u{FFFD}")).unwrap(); std::fs::write(ok.join("a\u{FFFD}").join("f"), vec![1u8; 5000]).unwrap();
    let t = scan(&ok, &ScanOptions { exclude: vec![ok.join(OsStr::from_bytes(b"a\xff"))], ..Default::default() }, &ScanProgress::default()).unwrap();
    assert!(t.skipped.is_empty());
    assert_eq!((1..t.len() as u32).filter(|&i| t.name(i) == "f").count(), 1);
    let _ = std::fs::remove_dir_all(&base);
}

/// Audit gap: an entry whose metadata cannot be read (directory readable but not searchable: readdir works, lstat of each entry gets EACCES) used to
/// vanish from the tree AND from the skipped list, silently undercounting. Needs a non-root user; the test refuses to pass vacuously.
#[test]
fn entries_whose_metadata_cannot_be_read_are_listed_as_skipped_not_dropped() {
    use std::os::unix::fs::PermissionsExt;
    let d = std::env::temp_dir().join(format!("skp-nostat-{}", std::process::id())); let _ = std::fs::remove_dir_all(&d);
    let sub = d.join("noexec"); std::fs::create_dir_all(&sub).unwrap();
    for n in ["a", "b"] { std::fs::write(sub.join(n), vec![1u8; 5000]).unwrap(); }
    std::fs::write(d.join("visible"), vec![1u8; 5000]).unwrap();
    std::fs::set_permissions(&sub, std::fs::Permissions::from_mode(0o444)).unwrap();
    let probe = std::fs::symlink_metadata(sub.join("a")).is_err(); // precondition: lstat really fails for this user
    let d = d.canonicalize().unwrap();
    let t = scan(&d, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    std::fs::set_permissions(&sub, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(probe, "precondition: running as root or lstat succeeded, so this test proves nothing");
    let names: Vec<_> = t.skipped.iter().map(|s| (s.path.rsplit('/').next().unwrap().to_string(), s.reason as u8)).collect();
    assert_eq!(names, vec![("a".to_string(), 0), ("b".to_string(), 0)], "{:?}", t.skipped);
    assert_eq!((1..t.len() as u32).filter(|&i| t.name(i) == "a" || t.name(i) == "b").count(), 0);
    let _ = std::fs::remove_dir_all(&d);
}
