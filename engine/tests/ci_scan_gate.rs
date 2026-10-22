#![cfg(feature = "ci-checks")]
use spacelyzer_engine::ffi::*;
use std::ffi::CString;
use std::time::{Duration, Instant};

struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!("spz-ci-gate-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir(&p).unwrap();
        for d in ["a", "b"] {
            std::fs::create_dir(p.join(d)).unwrap();
            for i in 0..20 { std::fs::write(p.join(d).join(format!("f{i}")), b"data").unwrap(); }
        }
        Self(p)
    }
    unsafe fn start(&self, n: u64) -> *mut Scan {
        let p = CString::new(self.0.to_str().unwrap()).unwrap();
        let s = spz_ci_scan_start_parked(p.as_ptr(), std::ptr::null(), n);
        assert!(!s.is_null()); s
    }
}
impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
unsafe fn parked(s: *mut Scan) -> bool {
    let end = Instant::now() + Duration::from_secs(2);
    while Instant::now() < end {
        if spz_ci_scan_gate_state(s) == 1 { return true; }
        std::thread::sleep(Duration::from_millis(1));
    }
    false
}
unsafe fn finish(s: *mut Scan) -> *mut spacelyzer_engine::tree::Tree {
    let end = Instant::now() + Duration::from_secs(12);
    while spz_scan_progress(s).finished == 0 {
        assert!(Instant::now() < end, "worker did not finish");
        std::thread::sleep(Duration::from_millis(1));
    }
    spz_scan_take_tree(s)
}
#[test]
fn parked_real_cancel_is_partial_and_other_session_is_independent() {
    unsafe {
        let f = Fixture::new();
        let a = f.start(1); let b = f.start(1);
        assert!(parked(a) && parked(b), "per-session park never reached");
        spz_scan_cancel(a); spz_ci_scan_gate_release(a);
        let ta = finish(a); assert!(!ta.is_null());
        assert_eq!(spz_tree_cancelled(ta), 1);
        assert_eq!(spz_tree_node_count(ta), 1);
        assert_eq!(spz_ci_scan_gate_state(b), 1, "other session was released");
        spz_ci_scan_gate_release(b);
        let tb = finish(b); assert!(!tb.is_null());
        assert_eq!(spz_tree_cancelled(tb), 0);
        assert_eq!(spz_tree_node_count(tb), 43);
        spz_tree_free(ta); spz_tree_free(tb); spz_scan_free(a); spz_scan_free(b);
    }
}
#[test]
fn gate_auto_expires_and_never_counts_as_released() {
    unsafe {
        let f = Fixture::new(); let s = f.start(1);
        assert!(parked(s));
        let t = finish(s);
        assert_eq!(spz_ci_scan_gate_state(s), 3);
        spz_ci_scan_gate_release(s);
        assert_eq!(spz_ci_scan_gate_state(s), 3, "late release must preserve timeout evidence");
        assert!(!t.is_null()); assert_eq!(spz_tree_cancelled(t), 0);
        spz_tree_free(t); spz_scan_free(s);
    }
}
#[test]
fn release_before_arrival_does_not_repark() {
    unsafe {
        let f = Fixture::new(); let s = f.start(1);
        spz_ci_scan_gate_release(s);
        let t = finish(s); assert!(!t.is_null());
        assert_eq!(spz_ci_scan_gate_state(s), 2);
        assert_eq!(spz_tree_cancelled(t), 0);
        spz_tree_free(t); spz_scan_free(s);
    }
}

#[test]
fn real_cancel_after_two_completed_directory_enumerations_keeps_prior_entries() {
    unsafe {
        // One child at each level forces serial directory descent, so target3 is
        // reached only after root + child have each accounted1000 actual files.
        // No elapsed/progress-publication guess and no concurrent siblings can race.
        let f = Fixture::new();
        std::fs::remove_dir_all(&f.0).unwrap();
        std::fs::create_dir_all(f.0.join("chain/last")).unwrap();
        for d in [f.0.clone(), f.0.join("chain"), f.0.join("chain/last")] {
            for i in 0..1000 { std::fs::write(d.join(format!("file{i}")), b"real").unwrap(); }
        }
        let s = f.start(3);
        assert!(parked(s), "midscan per-session park never reached");
        assert_eq!(spz_scan_progress(s).items, 2002, "prior real entry accounting missing");
        let start = Instant::now();
        spz_scan_cancel(s); spz_ci_scan_gate_release(s);
        assert_eq!(spz_ci_scan_gate_state(s), 2, "expired gate cannot count as midscan cancellation");
        let t = finish(s);
        assert!(start.elapsed() < Duration::from_secs(5), "coarse completion exceeded5s");
        assert!(!t.is_null());
        assert_eq!(spz_tree_cancelled(t), 1);
        assert_eq!(spz_tree_node_count(t), 2003, "prior entries must survive, last directory files absent");
        spz_tree_free(t); spz_scan_free(s);
        let normal = f.start(0); // release immediately: full real scan independently succeeds.
        spz_ci_scan_gate_release(normal);
        let full = finish(normal); assert!(!full.is_null());
        assert_eq!(spz_tree_cancelled(full), 0); assert_eq!(spz_tree_node_count(full), 3003);
        spz_tree_free(full); spz_scan_free(normal);
    }
}
