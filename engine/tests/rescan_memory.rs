//! Memory plateau across repeated rescans through the production C ABI (Linux, VmRSS).
//! Scope: engine-side tree/layout/filter handles on this fixture, on the host that runs it. This is not
//! a macOS, Swift-side, long-session or release-build result, and it does not prove the absence of leaks:
//! it bounds resident growth over many rescans and shows the detector can see a deliberate leak.
#![cfg(target_os = "linux")]
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::tree::Tree;
use std::ffi::CString;
use std::time::Duration;

fn rss_kb() -> u64 {
    let s = std::fs::read_to_string("/proc/self/status").unwrap();
    let l = s.lines().find(|l| l.starts_with("VmRSS:")).expect("VmRSS line");
    l.split_whitespace().nth(1).unwrap().parse().unwrap()
}

fn fixture() -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("spz-rescan-mem-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    for a in 0..40 {
        let dir = d.join(format!("d{a}/sub"));
        std::fs::create_dir_all(&dir).unwrap();
        for f in 0..25 {
            std::fs::write(dir.join(format!("file-{f}.txt")), vec![1u8; 100 + a * 10 + f]).unwrap();
        }
    }
    d.canonicalize().unwrap()
}

unsafe fn start(root: &CString) -> *mut Scan {
    let s = spz_scan_start(root.as_ptr(), std::ptr::null());
    assert!(!s.is_null());
    s
}

unsafe fn wait(s: *mut Scan) {
    while spz_scan_progress(s).finished == 0 {
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// One full user-visible cycle: scan, take, query, layout, filter, free everything.
unsafe fn cycle(root: &CString, expect_nodes: Option<u64>, keep: bool) -> u64 {
    let s = start(root);
    wait(s);
    let t: *mut Tree = spz_scan_take_tree(s);
    spz_scan_free(s);
    assert!(!t.is_null());
    let n = spz_tree_node_count(t);
    if let Some(e) = expect_nodes {
        assert_eq!(n, e, "every rescan of the unchanged fixture sees the same tree");
    }
    let mut ids = vec![0u32; 50];
    assert!(spz_tree_largest_files(t, 50, ids.as_mut_ptr()) > 0);
    let l = spz_layout_new(t, 0, 800.0, 600.0);
    assert!(!l.is_null());
    spz_layout_free(l);
    let f = SpzFilter { category_mask: u32::MAX, has_min: 0, has_max: 0, has_from: 0, has_to: 0, min_size: 0, max_size: 0, modified_from: 0, modified_to: 0 };
    let h = spz_filter_apply(t, std::ptr::null(), std::ptr::null(), f);
    if !h.is_null() {
        spz_filter_free(h);
    }
    if keep {
        std::hint::black_box(t); // negative control only: the tree is deliberately never freed
    } else {
        spz_tree_free(t);
    }
    n
}

/// Cancelled and never-taken scans must release their work as well.
unsafe fn abandoned(root: &CString) {
    let s = start(root);
    spz_scan_cancel(s);
    spz_scan_free(s);
    let s = start(root);
    wait(s);
    spz_scan_free(s); // finished, tree never taken
}

#[test]
fn resident_memory_plateaus_across_rescans_and_the_detector_sees_a_leak() {
    let root = CString::new(fixture().to_str().unwrap()).unwrap();
    unsafe {
        let nodes = cycle(&root, None, false);
        for _ in 0..10 {
            cycle(&root, Some(nodes), false);
            abandoned(&root);
        }
        let warm = rss_kb();
        for _ in 0..80 {
            cycle(&root, Some(nodes), false);
            abandoned(&root);
        }
        let end = rss_kb();
        let growth = end.saturating_sub(warm);
        eprintln!("rescan plateau: nodes {nodes}, warm {warm} kB, after 80 more rescans {end} kB, growth {growth} kB");
        assert!(growth < 2_000, "resident growth over 80 rescans was {growth} kB (warm {warm} kB, end {end} kB)");

        // negative control: leaking the same number of trees must be visible to the same measurement
        let before = rss_kb();
        for _ in 0..80 {
            cycle(&root, Some(nodes), true);
        }
        let leaked = rss_kb().saturating_sub(before);
        eprintln!("negative control: 80 deliberately leaked trees grew resident memory by {leaked} kB");
        assert!(leaked > growth.saturating_mul(3).max(3_000), "detector did not see the deliberate leak: {leaked} kB vs plateau {growth} kB");
    }
    let _ = std::fs::remove_dir_all(std::env::temp_dir().join(format!("spz-rescan-mem-{}", std::process::id())));
}
