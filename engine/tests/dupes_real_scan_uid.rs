// Retained from an independent verifier: uses the production scan ABI (not hand-built trees) to check uids are nonzero, distinct, and cross-tree/rescan reports are INVALID.
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::tree::Tree;
fn mk(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("vfy-uid-{}-{}", std::process::id(), tag)); let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap();
    for n in ["a","b","c"] { std::fs::write(d.join(n), vec![7u8; 30_000]).unwrap(); } d.canonicalize().unwrap()
}
unsafe fn via_abi(d: &std::path::Path) -> *mut Tree {
    let root = std::ffi::CString::new(d.to_str().unwrap()).unwrap();
    let sc = spz_scan_start(root.as_ptr(), std::ptr::null());
    loop { let p = spz_scan_progress(sc); if p.finished == 1 { break; } std::thread::sleep(std::time::Duration::from_millis(5)); }
    let t = spz_scan_take_tree(sc); spz_scan_free(sc); t
}
#[test]
fn production_uids_are_nonzero_distinct_and_cross_tree_report_is_invalid() {
    unsafe {
        let (d1, d2) = (mk("1"), mk("2"));
        let (t1, t2, t3) = (via_abi(&d1), via_abi(&d2), via_abi(&d1));
        assert!(!t1.is_null() && !t2.is_null() && !t3.is_null());
        let (u1, u2, u3) = ((*t1).uid, (*t2).uid, (*t3).uid);
        assert!(u1 != 0 && u2 != 0 && u3 != 0 && u1 != u2 && u2 != u3 && u1 != u3);
        let mut st = -1;
        let r = spz_dup_find_status(t1, 1, 0, 0, 0, std::ptr::null(), u64::MAX, &mut st);
        assert_eq!(st, 0); assert!(!r.is_null());
        assert_eq!(spz_dup_report_status(t1, r), 0);
        assert_eq!(spz_dup_report_status(t2, r), 3, "other tree, same shape");
        assert_eq!(spz_dup_report_status(t3, r), 3, "rescan of the same directory is a different tree");
        let mut g = SpzDupGroup::default(); let mut s2 = -1; spz_dup_report_group(r, 0, &mut g, &mut s2);
        let mut ids = vec![0u32; g.ids_listed as usize]; spz_dup_report_ids(r, 0, ids.as_mut_ptr(), g.ids_listed, &mut s2);
        assert_eq!(spz_tree_forget(t1, ids[0]), 0);
        assert_eq!(spz_dup_report_status(t1, r), 1, "removal makes it stale");
        spz_dup_report_free(r); spz_tree_free(t1); spz_tree_free(t2); spz_tree_free(t3);
    }
}
