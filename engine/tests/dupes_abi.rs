//! C ABI of the duplicate finder (Linux Rust evidence only; no Swift consumer, no UI). Exercises status codes, version/tree stamping, bounds,
//! report-only caps crossing the boundary, cancellation and control lifetime.
use spacelyzer_engine::dupes::find_duplicates;
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::Tree;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

#[cfg(feature = "failpoints")]
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
/// Under failpoints one armed panic is global to the process, so every test here is serialized.
#[cfg(feature = "failpoints")]
fn lock() -> std::sync::MutexGuard<'static, ()> { SERIAL.lock().unwrap_or_else(|e| e.into_inner()) }
#[cfg(not(feature = "failpoints"))]
fn lock() {}

fn fixture(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("spz-dabi-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d); std::fs::create_dir_all(&d).unwrap(); d.canonicalize().unwrap()
}
fn scanned(d: &Path) -> Tree { scan(d, &ScanOptions::default(), &ScanProgress::default()).unwrap() }
fn node(t: &Tree, p: &Path) -> u32 { t.find(p.to_str().unwrap()).expect("node") }
fn run(t: &Tree, max_groups: u32, max_members: u32, budget: u64, ctl: *const DupControl, expected: u64) -> (*mut DupReportHandle, i32) {
    let mut st = -1i32;
    let r = unsafe { spz_dup_find_status(t as *const Tree, 1, max_groups, max_members, budget, ctl, expected, &mut st) };
    (r, st)
}
fn summary(r: *const DupReportHandle) -> SpzDupSummary { let mut s = SpzDupSummary::default(); let mut st = -1; unsafe { spz_dup_report_summary(r, &mut s, &mut st) }; assert_eq!(st, 0); s }
fn group(r: *const DupReportHandle, i: u32) -> (SpzDupGroup, Vec<u32>) {
    let (mut g, mut st) = (SpzDupGroup::default(), -1);
    unsafe { spz_dup_report_group(r, i, &mut g, &mut st) }; assert_eq!(st, 0);
    let mut ids = vec![0u32; g.ids_listed as usize]; let mut st2 = -1;
    let n = unsafe { spz_dup_report_ids(r, i, ids.as_mut_ptr(), g.ids_listed, &mut st2) }; assert_eq!(st2, 0); assert_eq!(n, g.ids_listed);
    (g, ids)
}

fn three_groups(tag: &str) -> (PathBuf, Tree) {
    let d = fixture(tag);
    for i in 0..4 { std::fs::write(d.join(format!("big{i}")), vec![1u8; 90_000]).unwrap(); }
    for i in 0..3 { std::fs::write(d.join(format!("mid{i}")), vec![2u8; 50_000]).unwrap(); }
    for i in 0..2 { std::fs::write(d.join(format!("sm{i}")), vec![3u8; 20_000]).unwrap(); }
    let t = scanned(&d); (d, t)
}

#[test]
fn abi_report_equals_the_rust_report_and_is_stamped_with_tree_and_version() {
    let _g = lock();
    let (_d, mut t) = three_groups("basic");
    t.uid = 11;                                   // trees from scan() carry uid 0; the ABI hands out unique uids, so set distinct ones here
    let want = find_duplicates(&t, 1, &AtomicBool::new(false));
    let (r, st) = run(&t, 0, 0, 0, std::ptr::null(), u64::MAX);
    assert_eq!(st, 0); assert!(!r.is_null());
    let s = summary(r);
    assert_eq!((s.groups_total, s.groups_listed, s.flags), (3, 3, 0));
    assert_eq!(s.version, t.table().version); assert_eq!(s.duplicate_allocated_bytes, want.duplicate_allocated_bytes);
    assert_eq!((s.unreadable, s.changed, s.hardlink_aliases), (0, 0, 0));
    for (i, w) in want.groups.iter().enumerate() {
        let (g, ids) = group(r, i as u32);
        assert_eq!((g.size, g.member_count, g.linked), (w.size, w.member_count, w.linked)); assert_eq!(ids, w.ids);
    }
    assert_eq!(unsafe { spz_dup_report_status(&t, r) }, 0);
    // another tree: INVALID; the same tree after a removal: STALE
    let mut other = scanned(&_d); other.uid = 12;
    assert_eq!(unsafe { spz_dup_report_status(&other, r) }, 3);
    t.forget(want.groups[0].ids[0]).unwrap();
    assert_eq!(unsafe { spz_dup_report_status(&t, r) }, 1);
    assert_eq!(unsafe { spz_dup_report_status(std::ptr::null(), r) }, 3);
    unsafe { spz_dup_report_free(r); spz_dup_report_free(std::ptr::null_mut()); }
}

#[test]
fn expected_version_mismatch_and_null_tree_return_null_with_the_right_status_before_any_read() {
    let _g = lock();
    let (_d, t) = three_groups("expected");
    let v = t.table().version;
    let (r, st) = run(&t, 0, 0, 0, std::ptr::null(), v + 1);
    assert!(r.is_null()); assert_eq!(st, 1);
    let (r, st) = run(&t, 0, 0, 0, std::ptr::null(), v);
    assert!(!r.is_null()); assert_eq!(st, 0); unsafe { spz_dup_report_free(r) };
    let mut st = -1;
    let r = unsafe { spz_dup_find_status(std::ptr::null(), 1, 0, 0, 0, std::ptr::null(), u64::MAX, &mut st) };
    assert!(r.is_null()); assert_eq!(st, 3);
    // a stale expected version reads nothing: with a control, bytes_read stays 0
    let c = unsafe { spz_dup_control_new() };
    let (r, st) = run(&t, 0, 0, 0, c, v + 1);
    assert!(r.is_null() && st == 1);
    assert_eq!(unsafe { spz_dup_control_progress(c) }.bytes_read, 0);
    unsafe { spz_dup_control_free(c) };
}

#[test]
fn bounds_and_invalid_arguments_never_write_past_the_buffer_or_report_success() {
    let _g = lock();
    let (_d, t) = three_groups("bounds");
    let (r, _) = run(&t, 0, 0, 0, std::ptr::null(), u64::MAX);
    let mut st = -1;
    // out of range group: INVALID, output untouched
    let mut g = SpzDupGroup { size: 7, member_count: 7, ids_listed: 7, linked: 7 };
    unsafe { spz_dup_report_group(r, 3, &mut g, &mut st) }; assert_eq!(st, 3); assert_eq!((g.size, g.member_count), (7, 7));
    // cap smaller than the listed ids: only cap written, the sentinel after it survives
    let mut buf = [0xDEAD_BEEFu32; 8];
    let n = unsafe { spz_dup_report_ids(r, 0, buf.as_mut_ptr(), 2, &mut st) }; assert_eq!((n, st), (2, 0));
    assert!(buf[2..].iter().all(|&x| x == 0xDEAD_BEEF) && buf[0] != 0xDEAD_BEEF && buf[1] != 0xDEAD_BEEF);
    // cap larger than the ids: only ids_listed written
    let mut buf = [0xDEAD_BEEFu32; 8];
    let n = unsafe { spz_dup_report_ids(r, 0, buf.as_mut_ptr(), 8, &mut st) }; assert_eq!((n, st), (4, 0));
    assert!(buf[4..].iter().all(|&x| x == 0xDEAD_BEEF));
    // null out with cap > 0, bad index, null report
    assert_eq!(unsafe { spz_dup_report_ids(r, 0, std::ptr::null_mut(), 2, &mut st) }, 0); assert_eq!(st, 3);
    st = -1; assert_eq!(unsafe { spz_dup_report_ids(r, 9, buf.as_mut_ptr(), 2, &mut st) }, 0); assert_eq!(st, 3);
    st = -1; unsafe { spz_dup_report_summary(std::ptr::null(), std::ptr::null_mut(), &mut st) }; assert_eq!(st, 3);
    st = -1; assert_eq!(unsafe { spz_dup_report_ids(std::ptr::null(), 0, buf.as_mut_ptr(), 2, &mut st) }, 0); assert_eq!(st, 3);
    unsafe { spz_dup_report_free(r) };
}

#[test]
fn caps_cross_the_boundary_as_report_only_truncation_not_incompleteness() {
    let _g = lock();
    let (_d, t) = three_groups("caps");
    let (r, st) = run(&t, 2, 2, 0, std::ptr::null(), u64::MAX);
    assert_eq!(st, 0);
    let s = summary(r);
    assert_eq!((s.groups_total, s.groups_listed), (3, 2));
    assert_eq!(s.flags & (1 << 3), 1 << 3, "groups_truncated set");
    assert_eq!(s.flags & 0b111, 0, "not cancelled, not incomplete, no budget");
    let full = find_duplicates(&t, 1, &AtomicBool::new(false));
    assert_eq!(s.duplicate_allocated_bytes, full.duplicate_allocated_bytes, "total covers every group found");
    let (g0, ids0) = group(r, 0);
    assert_eq!((g0.member_count, g0.ids_listed), (4, 2));
    assert_eq!(ids0, full.groups[0].ids[..2].to_vec());
    unsafe { spz_dup_report_free(r) };
}

#[test]
fn a_cancelled_control_yields_an_incomplete_report_and_a_consumed_budget_is_flagged() {
    let _g = lock();
    let (_d, t) = three_groups("cancel");
    let c = unsafe { spz_dup_control_new() };
    unsafe { spz_dup_control_cancel(c) };
    assert_eq!(unsafe { spz_dup_control_progress(c) }.cancelled, 1);
    let (r, st) = run(&t, 0, 0, 0, c, u64::MAX); assert_eq!(st, 0);
    let s = summary(r);
    assert_eq!((s.flags & 0b11, s.groups_listed, s.duplicate_allocated_bytes), (0b11, 0, 0), "cancelled + incomplete, no groups");
    unsafe { spz_dup_report_free(r); spz_dup_control_free(c) };
    let c = unsafe { spz_dup_control_new() };
    let (r, st) = run(&t, 0, 0, 30_000, c, u64::MAX); assert_eq!(st, 0);
    let s = summary(r);
    assert_eq!(s.flags & 0b110, 0b110, "incomplete + budget_exhausted");
    let p = unsafe { spz_dup_control_progress(c) };
    assert_eq!(p.budget_hit, 1); assert!(p.bytes_read >= 30_000);
    unsafe { spz_dup_report_free(r); spz_dup_control_free(c) };
}

#[test]
fn a_table_change_during_the_pass_drops_the_report_as_stale() {
    let _g = lock();
    let (d, t) = three_groups("moved");
    let first = find_duplicates(&t, 1, &AtomicBool::new(false)).groups[0].ids[0];
    // a mutation lands while the pass runs: deterministic via a thread that removes the file as soon as the control shows bytes read
    let c = unsafe { spz_dup_control_new() };
    let tp = &t as *const Tree as usize; let cp = c as usize;
    let big = fixture("moved-big");
    for i in 0..4 { std::fs::write(big.join(format!("b{i}")), vec![9u8; 6_000_000]).unwrap(); }
    let tb = scanned(&big); let tbp = &tb as *const Tree as usize;
    let h = std::thread::spawn(move || {
        let c = cp as *const DupControl;
        while unsafe { spz_dup_control_progress(c) }.bytes_read == 0 { std::thread::yield_now(); }
        let tb = unsafe { &*(tbp as *const Tree) };
        let id = tb.find(big.join("b0").to_str().unwrap()).unwrap();
        tb.forget(id).unwrap();
    });
    let _ = tp; let _ = (&d, first);
    let mut st = -1;
    let r = unsafe { spz_dup_find_status(&tb, 1, 0, 0, 0, c, u64::MAX, &mut st) };
    h.join().unwrap();
    // the removal either landed during the pass (STALE, no report) or the whole pass finished before the thread ran (then it must be a clean OK report)
    if st == 1 { assert!(r.is_null()); } else { assert_eq!(st, 0); assert!(!r.is_null()); assert_eq!(unsafe { spz_dup_report_status(&tb, r) }, 1, "the removal already happened, so the report is stale afterward"); unsafe { spz_dup_report_free(r) }; }
    unsafe { spz_dup_control_free(c) };
}

#[test]
fn progress_is_readable_from_another_thread_and_the_control_may_be_freed_mid_pass() {
    let _g = lock();
    let d = fixture("live");
    for i in 0..4 { std::fs::write(d.join(format!("p{i}")), vec![5u8; 8_000_000]).unwrap(); }
    let t = scanned(&d);
    let c = unsafe { spz_dup_control_new() }; let cp = c as usize;
    let tp = &t as *const Tree as usize;
    let h = std::thread::spawn(move || {
        let mut st = -1;
        let r = unsafe { spz_dup_find_status(tp as *const Tree, 1, 0, 0, 0, cp as *const DupControl, u64::MAX, &mut st) };
        (r as usize, st)
    });
    let mut saw = 0u64; let mut last = 0u64;
    for _ in 0..2000 {
        let p = unsafe { spz_dup_control_progress(c) };
        assert!(p.bytes_read >= last, "bytes_read never goes backwards while a pass runs");
        last = p.bytes_read; if p.bytes_read > 0 { saw = p.bytes_read; break; }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    // free our handle while the pass may still be running: the pass holds its own reference (weak evidence: a use-after-free would not necessarily crash here)
    unsafe { spz_dup_control_free(c) };
    let (r, st) = h.join().unwrap();
    let r = r as *mut DupReportHandle;
    assert_eq!(st, 0); assert!(saw > 0 || !r.is_null());
    let s = summary(r); assert_eq!((s.groups_listed, s.flags), (1, 0));
    unsafe { spz_dup_report_free(r) };
}

#[cfg(feature = "failpoints")]
#[test]
fn a_panic_inside_the_entry_comes_back_as_internal_status_and_null_never_across_the_boundary() {
    let _g = lock();
    let (_d, t) = three_groups("panic");
    let before = spz_engine_panic_count();
    spacelyzer_engine::tree::set_failpoint(9);
    let (r, st) = run(&t, 0, 0, 0, std::ptr::null(), u64::MAX);
    assert!(r.is_null()); assert_eq!(st, 5);
    assert_eq!(spz_engine_panic_count(), before + 1);
    let (r, st) = run(&t, 0, 0, 0, std::ptr::null(), u64::MAX);          // the next call is healthy
    assert_eq!(st, 0); assert!(!r.is_null()); unsafe { spz_dup_report_free(r) };
}
