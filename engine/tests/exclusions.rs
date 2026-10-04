use spacelyzer_engine::ffi::*;
use spacelyzer_engine::*;
use std::ffi::CStr;
use std::fs;
use std::path::PathBuf;

fn fixture(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("excl-{}-{tag}", std::process::id())); let _ = fs::remove_dir_all(&d); fs::create_dir_all(d.join("sub")).unwrap();
    fs::write(d.join("keep"), vec![1u8; 5000]).unwrap(); fs::write(d.join("drop.bin"), vec![1u8; 5000]).unwrap(); fs::write(d.join("sub/inner"), vec![1u8; 5000]).unwrap();
    fs::create_dir_all(d.join("real")).unwrap(); fs::write(d.join("real/f"), vec![1u8; 5000]).unwrap(); std::os::unix::fs::symlink(d.join("real"), d.join("alias")).unwrap();
    d.canonicalize().unwrap()
}
fn scan_ex(d: &PathBuf, ex: Vec<PathBuf>) -> Tree { scan(d, &ScanOptions { exclude: ex, ..Default::default() }, &ScanProgress::default()).unwrap() }

#[test]
fn files_and_directories_are_excluded_and_every_unmatched_request_is_reported() {
    let d = fixture("a");
    let t = scan_ex(&d, vec![
        d.join("drop.bin"), d.join("sub/"),            // a FILE and a directory with a trailing slash: both match
        d.join("alias/f"),                              // through a symlink spelling: no scanned entry has that path
        PathBuf::from("relative/path"), d.clone(),      // relative, and the scan root itself
        d.join("typo"), d.join("typo"),                 // not there (duplicate request)
    ]);
    assert!(t.find(d.join("drop.bin").to_str().unwrap()).is_none(), "file exclusion applies");
    assert!(t.find(d.join("sub").to_str().unwrap()).is_none() && t.find(d.join("sub/inner").to_str().unwrap()).is_none());
    assert!(t.find(d.join("keep").to_str().unwrap()).is_some());
    let mut want = vec![d.join("alias/f").to_string_lossy().into_owned(), "relative/path".into(), d.to_string_lossy().into_owned(), d.join("typo").to_string_lossy().into_owned()];
    want.sort();
    let got: Vec<String> = t.unobserved_exclusions.iter().map(|(p, r)| { assert_eq!(*r, 0, "{p}: nothing skipped contains these, so NotSeen"); p.clone() }).collect();
    assert_eq!(got, want);
    assert_eq!(t.skipped_counts()[3], 2, "exactly the two matched requests are UserExcluded");
}

#[test]
fn no_unmatched_when_everything_matched_and_a_non_utf8_request_is_reported() {
    use std::os::unix::ffi::OsStrExt;
    let d = fixture("b");
    let t = scan_ex(&d, vec![d.join("keep")]);
    assert!(t.unobserved_exclusions.is_empty());
    let bad = d.join(std::ffi::OsStr::from_bytes(b"x\xff"));
    let t = scan_ex(&d, vec![bad]);
    assert_eq!(t.unobserved_exclusions.iter().map(|x| x.1).collect::<Vec<_>>(), vec![2], "a non-UTF-8 request can never match and is reported (NotMatchable), not silently dropped");
}

#[test]
fn a_cancelled_scan_reports_no_unmatched_and_the_abi_roundtrips_with_bounds() {
    let d = fixture("c");
    let p = ScanProgress::default(); p.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
    let t = scan(&d, &ScanOptions { exclude: vec![d.join("typo")], ..Default::default() }, &p).unwrap();
    assert!(t.cancelled && t.unobserved_exclusions.is_empty(), "a walk that did not finish cannot say what was unmatched");
    let t = scan_ex(&d, vec![d.join("typo"), d.join("keep")]);
    unsafe {
        let mut st = -1;
        assert_eq!(spz_tree_unobserved_exclusion_count_status(&t, &mut st), 1); assert_eq!(st, 0);
        let mut reason = 9u8; let s = spz_tree_unobserved_exclusion_status(&t, 0, &mut reason, &mut st); assert_eq!((st, reason), (0, 0));
        assert_eq!(CStr::from_ptr(s).to_str().unwrap(), d.join("typo").to_str().unwrap()); spz_string_free(s);
        reason = 9; assert!(spz_tree_unobserved_exclusion_status(&t, 1, &mut reason, &mut st).is_null()); assert_eq!((st, reason), (3, 9));
        assert!(spz_tree_unobserved_exclusion_status(std::ptr::null(), 0, &mut reason, &mut st).is_null()); assert_eq!(st, 3);
        assert_eq!(spz_tree_unobserved_exclusion_count_status(std::ptr::null(), &mut st), 0); assert_eq!(st, 3);
    }
}

/// Verifier repro: requests under an excluded or unreadable subtree were never visited, so they must not read as "not seen / nothing there".
#[test]
fn requests_under_skipped_subtrees_are_inside_skipped_not_not_seen() {
    use std::os::unix::fs::PermissionsExt;
    let d = fixture("d");
    fs::create_dir_all(d.join("sub/deep")).unwrap(); fs::write(d.join("sub/deep/f"), b"y").unwrap();
    fs::create_dir_all(d.join("locked/x")).unwrap(); fs::write(d.join("locked/x/g"), b"y").unwrap();
    let t = scan_ex(&d, vec![d.join("sub"), d.join("sub/deep"), d.join("sub/inner")]);
    let by: Vec<(String, u8)> = t.unobserved_exclusions.iter().map(|(p, r)| (p.rsplit('/').next().unwrap().to_string(), *r)).collect();
    assert_eq!(by, vec![("deep".to_string(), 1), ("inner".to_string(), 1)], "{:?}", t.unobserved_exclusions);
    assert_eq!(t.skipped_counts()[3], 1);
    fs::set_permissions(d.join("locked"), fs::Permissions::from_mode(0o000)).unwrap();
    let probe = fs::read_dir(d.join("locked")).is_err(); // precondition: really unreadable for this user (not root)
    let t = scan_ex(&d, vec![d.join("locked/x"), d.join("locked/x/g")]);
    fs::set_permissions(d.join("locked"), fs::Permissions::from_mode(0o755)).unwrap();
    assert!(probe, "precondition: running as root, so this test proves nothing");
    assert!(t.unobserved_exclusions.iter().all(|x| x.1 == 1) && t.unobserved_exclusions.len() == 2, "{:?}", t.unobserved_exclusions);
    assert_eq!(t.skipped_counts()[0], 1, "the locked directory itself is PermissionDenied");
}

/// Scope note, asserted: excluding ONE hard link does not remove the inode's bytes while another link is still scanned.
#[test]
fn excluding_one_hard_link_keeps_the_inode_counted_through_the_other() {
    let d = std::env::temp_dir().join(format!("excl-{}-h", std::process::id())); let _ = fs::remove_dir_all(&d); fs::create_dir_all(&d).unwrap();
    fs::write(d.join("a"), vec![1u8; 8000]).unwrap(); fs::hard_link(d.join("a"), d.join("b")).unwrap();
    let d = d.canonicalize().unwrap();
    let full = scan_ex(&d, vec![]).size(0);
    assert!(full > 0);
    assert_eq!(scan_ex(&d, vec![d.join("a")]).size(0), full, "bytes still counted via b");
    assert_eq!(scan_ex(&d, vec![d.join("a"), d.join("b")]).size(0), 0, "both links excluded");
}
