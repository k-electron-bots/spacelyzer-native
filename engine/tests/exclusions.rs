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
    assert_eq!(t.unmatched_exclusions, want);
    assert_eq!(t.skipped_counts()[3], 2, "exactly the two matched requests are UserExcluded");
}

#[test]
fn no_unmatched_when_everything_matched_and_a_non_utf8_request_is_reported() {
    use std::os::unix::ffi::OsStrExt;
    let d = fixture("b");
    let t = scan_ex(&d, vec![d.join("keep")]);
    assert!(t.unmatched_exclusions.is_empty());
    let bad = d.join(std::ffi::OsStr::from_bytes(b"x\xff"));
    let t = scan_ex(&d, vec![bad]);
    assert_eq!(t.unmatched_exclusions.len(), 1, "a non-UTF-8 request can never match and is reported, not silently dropped");
}

#[test]
fn a_cancelled_scan_reports_no_unmatched_and_the_abi_roundtrips_with_bounds() {
    let d = fixture("c");
    let p = ScanProgress::default(); p.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
    let t = scan(&d, &ScanOptions { exclude: vec![d.join("typo")], ..Default::default() }, &p).unwrap();
    assert!(t.cancelled && t.unmatched_exclusions.is_empty(), "a walk that did not finish cannot say what was unmatched");
    let t = scan_ex(&d, vec![d.join("typo"), d.join("keep")]);
    unsafe {
        let mut st = -1;
        assert_eq!(spz_tree_unmatched_exclusion_count_status(&t, &mut st), 1); assert_eq!(st, 0);
        let s = spz_tree_unmatched_exclusion_status(&t, 0, &mut st); assert_eq!(st, 0);
        assert_eq!(CStr::from_ptr(s).to_str().unwrap(), d.join("typo").to_str().unwrap()); spz_string_free(s);
        assert!(spz_tree_unmatched_exclusion_status(&t, 1, &mut st).is_null()); assert_eq!(st, 3);
        assert!(spz_tree_unmatched_exclusion_status(std::ptr::null(), 0, &mut st).is_null()); assert_eq!(st, 3);
        assert_eq!(spz_tree_unmatched_exclusion_count_status(std::ptr::null(), &mut st), 0); assert_eq!(st, 3);
    }
}
