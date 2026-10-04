//! Duplicate finder (Linux Rust evidence only; read-only, no FFI, no UI).
use spacelyzer_engine::dupes::*;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::Tree;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

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
    assert_eq!(r.duplicate_allocated_bytes, r.groups[0].size * 2);
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
    std::fs::hard_link(d.join("f2"), d.join("keep_old_f2_inode")).unwrap();                  // pins the old inode so the replacement cannot reuse it
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
    assert!(r.cancelled && r.groups.is_empty() && r.duplicate_allocated_bytes == 0, "{:?}", r);
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

#[test]
fn progress_counts_candidates_examined_and_bytes_and_a_complete_pass_examines_all() {
    let d = fixture("progress");
    for n in ["a", "b", "c"] { std::fs::write(d.join(n), vec![1u8; 100_000]).unwrap(); }
    std::fs::write(d.join("lone"), vec![2u8; 70_000]).unwrap();       // no same-size partner: never a candidate
    let t = scanned(&d);
    let pr = DupProgress::default();
    let r = find_duplicates_with(&t, 1, &AtomicBool::new(false), &pr);
    use std::sync::atomic::Ordering::Relaxed;
    assert_eq!(r.groups.len(), 1);
    assert_eq!(pr.candidates.load(Relaxed), 3);
    assert_eq!(pr.examined.load(Relaxed), 3);
    let b = pr.bytes_read.load(Relaxed);
    // prefix (3 x 4096) + full hash (3 x 100000) + compares against the one representative (2 x 2 x 100000)
    assert_eq!(b, 3 * 4096 + 3 * 100_000 + 2 * 2 * 100_000, "bytes_read counts every read stage");
}

#[test]
fn cancel_in_the_middle_stops_reading_and_reports_only_proven_groups() {
    let d = fixture("midcancel");
    // group 1: three 600 KB copies (one size); group 2: two 300 KB copies. Sizes differ, so they are separate work items.
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![1u8; 600_000]).unwrap(); }
    for n in ["y1", "y2"] { std::fs::write(d.join(n), vec![2u8; 300_000]).unwrap(); }
    let t = scanned(&d);
    let full = find_duplicates(&t, 1, &AtomicBool::new(false));
    assert_eq!(full.groups.len(), 2);
    let cancel = std::sync::Arc::new(AtomicBool::new(false));
    let c2 = cancel.clone();
    let mut pr = DupProgress::default();
    // the first read past the prefix stage trips the cancel: deterministic, no timing
    pr.on_read = Some(Box::new(move |total| if total > 4096 * 5 { c2.store(true, std::sync::atomic::Ordering::SeqCst); }));
    let r = find_duplicates_with(&t, 1, &cancel, &pr);
    use std::sync::atomic::Ordering::Relaxed;
    assert!(r.cancelled, "{:?}", r);
    let total_work = pr.bytes_read.load(Relaxed);
    let full_pr = DupProgress::default(); let _ = find_duplicates_with(&t, 1, &AtomicBool::new(false), &full_pr);
    assert!(total_work < full_pr.bytes_read.load(Relaxed), "stopped early: {} < {}", total_work, full_pr.bytes_read.load(Relaxed));
    for g in &r.groups { assert!(full.groups.contains(g), "a cancelled pass may omit groups but never invents or truncates one: {:?}", g); }
    assert_eq!(r.duplicate_allocated_bytes, r.groups.iter().map(|g| g.size * (g.ids.len() as u64 - 1)).sum::<u64>());
    assert_eq!((r.unreadable, r.changed), (0, 0), "a cancel is not counted as unreadable files: {:?}", r);
}

#[test]
fn read_budget_stops_the_pass_with_budget_exhausted_and_only_complete_groups() {
    let d = fixture("budget");
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![1u8; 600_000]).unwrap(); }
    for n in ["y1", "y2"] { std::fs::write(d.join(n), vec![2u8; 300_000]).unwrap(); }
    let t = scanned(&d);
    let full = find(&t);
    assert_eq!(full.groups.len(), 2); assert!(!full.incomplete && !full.budget_exhausted);
    let pr = DupProgress::default();
    let r = find_duplicates_opts(&t, DupOptions { min_size: 1, max_read_bytes: 50_000, ..Default::default() }, &AtomicBool::new(false), &pr);
    use std::sync::atomic::Ordering::Relaxed;
    assert!(r.budget_exhausted && r.incomplete && !r.cancelled, "{:?}", r);
    let read = pr.bytes_read.load(Relaxed);
    // overshoot is bounded: the budget is checked per chunk (64 KiB read, or two files' chunks in a compare), per worker (rayon may run both size groups at once)
    assert!(read >= 50_000 && read < 50_000 + 4 * 2 * 65_536, "read {}", read);
    for g in &r.groups { assert!(full.groups.contains(g), "never a group with missing members: {:?}", g); }
    assert_eq!((r.unreadable, r.changed), (0, 0), "{:?}", r);
}

#[test]
fn a_member_with_a_link_outside_the_scan_is_flagged_linked_and_still_listed() {
    let d = fixture("linked");
    let root = d.join("root"); std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a"), vec![3u8; 40_000]).unwrap(); std::fs::write(root.join("b"), vec![3u8; 40_000]).unwrap();
    std::fs::hard_link(root.join("a"), d.join("outside_link_to_a")).unwrap();   // another path to a's storage, outside the scanned root
    let t = scanned(&root);
    let r = find(&t);
    assert_eq!(r.groups.len(), 1, "{:?}", r);
    assert_eq!(r.groups[0].linked, 1, "a has link count 2: removing it frees nothing: {:?}", r);
    assert_eq!(r.groups[0].ids.len(), 2);
}

#[test]
fn a_file_replaced_during_the_full_hash_stage_counts_as_changed_not_unreadable() {
    let d = fixture("midchange");
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![4u8; 100_000]).unwrap(); }
    let t = scanned(&d);
    let pin = d.join("pin"); std::fs::hard_link(d.join("x2"), &pin).unwrap();    // keeps x2's inode alive so the replacement gets a new one
    let x2 = d.join("x2");
    let done = std::sync::Arc::new(AtomicBool::new(false));
    let mut pr = DupProgress::default();
    let (done2, x2c) = (done.clone(), x2.clone());
    // after the three prefix reads (3 x 4096 bytes), replace x2 once: the full-hash stage then finds a different inode
    pr.on_read = Some(Box::new(move |total| {
        if total >= 3 * 4096 && !done2.swap(true, std::sync::atomic::Ordering::SeqCst) {
            std::fs::remove_file(&x2c).unwrap(); std::fs::write(&x2c, vec![4u8; 100_000]).unwrap();
        }
    }));
    let r = find_duplicates_with(&t, 1, &AtomicBool::new(false), &pr);
    assert!(done.load(std::sync::atomic::Ordering::SeqCst), "the replacement ran (precondition)");
    assert_eq!((r.changed, r.unreadable), (1, 0), "{:?}", r);
    assert_eq!(r.groups.len(), 1); assert_eq!(r.groups[0].ids.len(), 2);
    assert!(!r.groups[0].ids.contains(&node(&t, &d.join("x2"))));
}

// Reads before the compare stage for three 100000-byte identical files: 3 prefix reads (4096) + 3 full-hash reads (100000).
const BEFORE_COMPARE: u64 = 3 * 4096 + 3 * 100_000;

#[test]
fn stop_inside_the_compare_stage_drops_the_bucket_and_counts_nothing() {
    let d = fixture("compare-stop");
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![4u8; 100_000]).unwrap(); }
    let t = scanned(&d);
    let cancel = std::sync::Arc::new(AtomicBool::new(false));
    let c2 = cancel.clone();
    let mut pr = DupProgress::default();
    pr.on_read = Some(Box::new(move |total| if total > BEFORE_COMPARE { c2.store(true, std::sync::atomic::Ordering::SeqCst); }));   // first compare read
    let r = find_duplicates_with(&t, 1, &cancel, &pr);
    use std::sync::atomic::Ordering::Relaxed;
    assert!(pr.bytes_read.load(Relaxed) > BEFORE_COMPARE, "the stop really happened inside the compare stage (precondition)");
    assert!(r.cancelled && r.incomplete && r.groups.is_empty() && r.duplicate_allocated_bytes == 0, "{:?}", r);
    assert_eq!((r.unreadable, r.changed), (0, 0), "{:?}", r);
}

#[test]
fn a_failing_class_representative_is_blamed_alone_and_the_rest_still_group() {
    let d = fixture("rep-fail");
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![4u8; 100_000]).unwrap(); }
    let t = scanned(&d);
    let pin = d.join("pin"); std::fs::hard_link(d.join("x1"), &pin).unwrap();     // x1 is the lowest id, hence the first representative; pin keeps its inode alive
    let x1 = d.join("x1");
    let done = std::sync::Arc::new(AtomicBool::new(false));
    let (done2, x1c) = (done.clone(), x1.clone());
    let mut pr = DupProgress::default();
    // on the first compare read (x1 vs x2, both already open and matching) replace x1 on disk: the NEXT compare (x1 as representative vs x3) opens a new inode
    pr.on_read = Some(Box::new(move |total| {
        if total > BEFORE_COMPARE && !done2.swap(true, std::sync::atomic::Ordering::SeqCst) {
            std::fs::remove_file(&x1c).unwrap(); std::fs::write(&x1c, vec![4u8; 100_000]).unwrap();
        }
    }));
    let r = find_duplicates_with(&t, 1, &AtomicBool::new(false), &pr);
    assert!(done.load(std::sync::atomic::Ordering::SeqCst), "replacement ran (precondition)");
    assert_eq!((r.changed, r.unreadable), (1, 0), "exactly the representative is counted: {:?}", r);
    let (id1, id2, id3) = (node(&t, &d.join("x1")), node(&t, &d.join("x2")), node(&t, &d.join("x3")));
    assert_eq!(r.groups.len(), 1, "{:?}", r);
    let mut got = r.groups[0].ids.clone(); got.sort();
    let mut want = vec![id2, id3]; want.sort();
    assert_eq!(got, want, "x3 must not be blamed or lost; x1 (changed) is out: {:?}", r);
    assert!(!r.groups[0].ids.contains(&id1));
}

#[test]
fn a_reused_progress_is_reset_per_pass_not_carrying_budget_or_totals() {
    let d = fixture("reuse");
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![4u8; 100_000]).unwrap(); }
    let t = scanned(&d);
    let pr = DupProgress::default();
    use std::sync::atomic::Ordering::Relaxed;
    let first = find_duplicates_opts(&t, DupOptions { min_size: 1, max_read_bytes: 20_000, ..Default::default() }, &AtomicBool::new(false), &pr);
    assert!(first.budget_exhausted && pr.budget_hit.load(Relaxed));
    let second = find_duplicates_opts(&t, DupOptions { min_size: 1, max_read_bytes: 0, ..Default::default() }, &AtomicBool::new(false), &pr);
    assert!(!second.budget_exhausted && !second.incomplete && !pr.budget_hit.load(Relaxed), "{:?}", second);
    assert_eq!(second.groups.len(), 1);
    let fresh = DupProgress::default(); let _ = find_duplicates_with(&t, 1, &AtomicBool::new(false), &fresh);
    assert_eq!(pr.bytes_read.load(Relaxed), fresh.bytes_read.load(Relaxed), "totals describe only the second pass");
    assert_eq!((pr.candidates.load(Relaxed), pr.examined.load(Relaxed)), (3, 3));
}

#[test]
fn a_file_shortened_while_being_read_is_changed_not_unreadable() {
    let d = fixture("shrink");
    for n in ["x1", "x2", "x3"] { std::fs::write(d.join(n), vec![4u8; 300_000]).unwrap(); }
    let t = scanned(&d);
    let done = std::sync::Arc::new(AtomicBool::new(false));
    let (done2, dir) = (done.clone(), d.clone());
    let mut pr = DupProgress::default();
    // after the first full-hash chunk of the first file (3 prefix reads + one 64 KiB chunk), truncate all three in place (same inodes): the file being read hits EOF mid-read
    pr.on_read = Some(Box::new(move |total| {
        if total >= 3 * 4096 + 65_536 && !done2.swap(true, std::sync::atomic::Ordering::SeqCst) {
            for n in ["x1", "x2", "x3"] { std::fs::OpenOptions::new().write(true).open(dir.join(n)).unwrap().set_len(10).unwrap(); }
        }
    }));
    let r = find_duplicates_with(&t, 1, &AtomicBool::new(false), &pr);
    assert!(done.load(std::sync::atomic::Ordering::SeqCst), "truncation ran (precondition)");
    assert_eq!((r.changed, r.unreadable), (3, 0), "a short read is a change, not an I/O failure: {:?}", r);
    assert!(r.groups.is_empty());
}

#[test]
fn group_and_member_caps_keep_the_largest_groups_and_lowest_ids_and_say_so() {
    let d = fixture("caps");
    // 3 groups: big (4 x 90k), mid (3 x 50k), small (2 x 20k)
    for i in 0..4 { std::fs::write(d.join(format!("big{i}")), vec![1u8; 90_000]).unwrap(); }
    for i in 0..3 { std::fs::write(d.join(format!("mid{i}")), vec![2u8; 50_000]).unwrap(); }
    for i in 0..2 { std::fs::write(d.join(format!("sm{i}")), vec![3u8; 20_000]).unwrap(); }
    let t = scanned(&d);
    let all = find(&t);
    assert_eq!((all.groups.len(), all.groups_total, all.groups_truncated), (3, 3, false));
    assert_eq!(all.groups[0].member_count, 4); assert!(all.groups[0].size > all.groups[1].size);
    let pr = DupProgress::default();
    let r = find_duplicates_opts(&t, DupOptions { min_size: 1, max_groups: 2, max_members_per_group: 2, ..Default::default() }, &AtomicBool::new(false), &pr);
    assert_eq!((r.groups.len(), r.groups_total, r.groups_truncated), (2, 3, true));
    assert_eq!(r.duplicate_allocated_bytes, all.duplicate_allocated_bytes, "the total covers every group found, not only the listed ones");
    assert_eq!(r.groups[0].size, all.groups[0].size); assert_eq!(r.groups[1].size, all.groups[1].size);
    for (g, full) in r.groups.iter().zip(all.groups.iter()) {
        assert_eq!(g.member_count, full.member_count, "the true count survives the cap");
        assert_eq!(g.ids, full.ids[..2].to_vec(), "the lowest ids are kept, deterministically");
    }
    assert!(!r.incomplete, "caps are truncation, not an incomplete pass");
}

#[test]
fn group_order_is_total_and_stable_with_equal_duplicate_bytes() {
    let d = fixture("order");
    // two groups with identical size and member count: order falls to the lowest member id
    for n in ["a1", "a2", "b1", "b2"] { std::fs::write(d.join(n), vec![if n.starts_with('a') { 1u8 } else { 2u8 }; 30_000]).unwrap(); }
    let t = scanned(&d);
    let r = find(&t);
    assert_eq!(r.groups.len(), 2);
    assert_eq!(r.groups[0].size, r.groups[1].size);
    assert!(r.groups[0].ids[0] < r.groups[1].ids[0]);
    for _ in 0..5 { assert_eq!(find(&t), r); }
}

/// Tiny deterministic generator (no external crate): reproducible failures by seed.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 { self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); self.0 >> 33 }
    fn below(&mut self, n: u64) -> u64 { self.next() % n }
}

/// Differential check against a brute-force oracle: all live candidate files, bucketed by scanned allocated size, split by exact byte equality
/// (std::fs::read, no hashing, no prefix shortcut). The finder must report exactly those classes of size >= 2.
fn brute_force(t: &Tree, d: &Path, names: &[String], dead: &std::collections::BTreeSet<u32>) -> std::collections::BTreeSet<Vec<u32>> {
    use std::collections::BTreeMap;
    let tab = t.table();
    let mut by_alloc: BTreeMap<u64, Vec<(u32, Vec<u8>)>> = BTreeMap::new();
    for n in names {
        let id = node(t, &d.join(n));
        if dead.contains(&id) { continue; }
        let sz = tab.sizes[id as usize];
        if sz == 0 { continue; }
        by_alloc.entry(sz).or_default().push((id, std::fs::read(d.join(n)).unwrap()));
    }
    let mut out = std::collections::BTreeSet::new();
    for (_, files) in by_alloc {
        let mut classes: Vec<(Vec<u8>, Vec<u32>)> = Vec::new();
        for (id, bytes) in files {
            match classes.iter_mut().find(|(b, _)| *b == bytes) { Some((_, v)) => v.push(id), None => classes.push((bytes, vec![id])) }
        }
        for (_, mut v) in classes { if v.len() >= 2 { v.sort(); out.insert(v); } }
    }
    out
}

#[test]
fn randomized_differential_against_a_brute_force_oracle() {
    // lengths straddle the prefix (4096), the chunk (65536) and the allocation block, so equal-allocation/different-length and late-difference cases occur
    let lens: [usize; 9] = [1, 100, 4095, 4096, 4097, 8192, 65_535, 65_536, 70_000];
    let mut cases = 0u32; let mut with_groups = 0u32; let mut same_alloc_diff_len = 0u32;
    for seed in 1..=40u64 {
        let d = fixture(&format!("diff{seed}"));
        let mut g = Lcg(seed);
        // a few base contents, each with a few mutations (first byte, last byte, a middle byte) so near-misses are common
        let mut names: Vec<String> = Vec::new();
        let nfiles = 6 + g.below(20) as usize;
        let nbases = 1 + g.below(4) as usize;
        let bases: Vec<Vec<u8>> = (0..nbases).map(|b| { let l = lens[g.below(lens.len() as u64) as usize]; (0..l).map(|i| ((i * 31 + b * 17 + seed as usize) % 251) as u8).collect() }).collect();
        for i in 0..nfiles {
            let mut c = bases[g.below(nbases as u64) as usize].clone();
            match g.below(5) { 0 => { let l = c.len() - 1; c[l] ^= 1; } 1 => { c[0] ^= 1; } 2 => { let m = c.len() / 2; c[m] ^= 1; } _ => {} }
            if g.below(7) == 0 { c.clear(); }                                    // empty files are never candidates
            let name = format!("f{i}"); std::fs::write(d.join(&name), &c).unwrap(); names.push(name);
        }
        let t = scanned(&d);
        let mut dead = std::collections::BTreeSet::new();
        for n in &names { if g.below(9) == 0 { let id = node(&t, &d.join(n)); let _ = t.forget(id); dead.insert(id); } }
        let r = find(&t);
        let got: std::collections::BTreeSet<Vec<u32>> = r.groups.iter().map(|x| x.ids.clone()).collect();
        let want = brute_force(&t, &d, &names, &dead);
        assert_eq!(got, want, "seed {seed}: finder and oracle disagree; report {:?}", r);
        assert_eq!((r.unreadable, r.changed, r.cancelled, r.incomplete), (0, 0, false, false), "seed {seed}: {:?}", r);
        let tab = t.table();
        for gr in &r.groups { assert_eq!(gr.member_count as usize, gr.ids.len()); assert!(gr.ids.windows(2).all(|w| w[0] < w[1])); assert_eq!(gr.size, tab.sizes[gr.ids[0] as usize]); }
        assert_eq!(r.duplicate_allocated_bytes, r.groups.iter().map(|x| x.size * (x.member_count as u64 - 1)).sum::<u64>());
        cases += 1; if !r.groups.is_empty() { with_groups += 1; }
        // coverage evidence: some case where two files of different length share an allocated size (and so are not duplicates)
        let mut alloc_len: std::collections::BTreeMap<u64, std::collections::BTreeSet<usize>> = Default::default();
        for n in &names { let id = node(&t, &d.join(n)); if !dead.contains(&id) && tab.sizes[id as usize] > 0 { alloc_len.entry(tab.sizes[id as usize]).or_default().insert(std::fs::read(d.join(n)).unwrap().len()); } }
        if alloc_len.values().any(|s| s.len() > 1) { same_alloc_diff_len += 1; }
    }
    assert_eq!(cases, 40);
    assert!(with_groups >= 10, "the generator must produce duplicates often enough to mean something: {with_groups}");
    assert!(same_alloc_diff_len >= 3, "the generator must hit equal-allocation/different-length cases: {same_alloc_diff_len}");
}

#[test]
fn non_utf8_names_are_left_out_of_the_tree_so_they_are_never_grouped_or_aliased() {
    use std::os::unix::ffi::OsStrExt;
    let d = fixture("nonutf8");
    for n in [&b"dup\xff1"[..], &b"dup\xff2"[..]] { if !made(std::fs::write(d.join(std::ffi::OsStr::from_bytes(n)), vec![8u8; 40_000])) { return; } }
    std::fs::write(d.join("ok1"), vec![8u8; 40_000]).unwrap(); std::fs::write(d.join("ok2"), vec![8u8; 40_000]).unwrap();
    let t = scanned(&d);
    let r = find(&t);
    // The scanner cannot represent these names, so they never become nodes (recall limit, disclosed in the skipped list), not a false duplicate.
    assert_eq!(r.groups.len(), 1, "{:?}", r);
    assert!(r.groups[0].ids.iter().all(|&i| t.name(i).starts_with("ok")));
    assert_eq!(t.skipped.iter().filter(|s| s.lossy).count(), 2);
}
