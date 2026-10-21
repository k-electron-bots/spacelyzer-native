//! Cancelled (partial) scans on a disposable fixture, Linux Rust evidence only. A cancelled tree must say so, must only
//! contain entries a complete scan also contains (never an invented or oversized one), must not report unobserved
//! exclusions (the walk may simply not have reached them), and must stay safe to inspect and forget from.
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::Tree;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Removes the fixture directory when the test ends, pass or fail.
struct Cleanup(PathBuf);
impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("spz-partial-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d);
    for a in 0..30 {
        for b in 0..4 {
            let dir = d.join(format!("a{a}/b{b}"));
            std::fs::create_dir_all(&dir).unwrap();
            for f in 0..12 {
                std::fs::write(dir.join(format!("f{f}.dat")), vec![3u8; 500 + a * 20 + b * 7 + f]).unwrap();
            }
        }
    }
    d.canonicalize().unwrap()
}

fn by_path(t: &Tree) -> HashMap<String, u64> {
    (0..t.len() as u32).map(|i| (t.path(i), t.size(i))).collect()
}

fn run(d: &Path, excl: Vec<PathBuf>, cancel_first: bool) -> Tree {
    let p = ScanProgress::default();
    if cancel_first {
        p.cancel();
    }
    scan(d, &ScanOptions { exclude: excl, ..Default::default() }, &p).unwrap()
}

fn assert_subset_of(partial: &Tree, full: &Tree) {
    let f = by_path(full);
    for (path, size) in by_path(partial) {
        let want = f.get(&path).unwrap_or_else(|| panic!("partial scan invented {path}"));
        assert!(size <= *want, "{path}: partial {size} exceeds complete {want}");
    }
}

#[test]
fn a_complete_scan_is_not_flagged_and_a_cancelled_one_is_flagged_through_the_abi() {
    let d = fixture("flag");
    let _cleanup = Cleanup(d.clone());
    let full = run(&d, vec![], false);
    let part = run(&d, vec![], true);
    unsafe {
        assert_eq!(spz_tree_cancelled(&full), 0);
        assert_eq!(spz_tree_cancelled(&part), 1);
    }
    assert!(part.len() <= full.len());
    assert!(part.size(part.root()) <= full.size(full.root()));
    assert_subset_of(&part, &full);
}

#[test]
fn a_scan_cancelled_mid_walk_never_invents_or_inflates_an_entry_and_keeps_parent_totals_consistent() {
    let d = fixture("mid");
    let _cleanup = Cleanup(d.clone());
    let full = run(&d, vec![], false);
    let mut saw_partial = false;
    for delay_us in [0u64, 50, 200, 800, 3000] {
        let p = std::sync::Arc::new(ScanProgress::default());
        let p2 = p.clone();
        let canceller = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_micros(delay_us));
            p2.cancel();
        });
        let t = scan(&d, &ScanOptions::default(), &p).unwrap();
        canceller.join().unwrap();
        assert_subset_of(&t, &full);
        // totals stay consistent: a node is never smaller than the sum of its observed children
        let tab = t.table();
        for id in 0..t.len() as u32 {
            let kids: u64 = t.children(id).map(|c| tab.sizes[c as usize]).sum();
            assert!(tab.sizes[id as usize] >= kids, "{}: {} < children {}", t.path(id), tab.sizes[id as usize], kids);
        }
        if t.cancelled && t.len() < full.len() {
            saw_partial = true;
        }
    }
    // The pre-cancelled test above covers the flag deterministically; this loop only needs to run without violating the invariants.
    eprintln!("mid-walk cancel produced a strictly smaller tree in at least one run: {saw_partial}");
}

#[test]
fn a_cancelled_scan_reports_no_unobserved_exclusions_even_when_the_excluded_path_exists() {
    let d = fixture("excl");
    let _cleanup = Cleanup(d.clone());
    let target = d.join("a3/b1");
    let full = run(&d, vec![target.clone()], false);
    let part = run(&d, vec![target.clone()], true);
    unsafe {
        let mut st = -1;
        assert_eq!(spz_tree_unobserved_exclusion_count_status(&part, &mut st), 0);
        assert_eq!(st, 0);
        let mut st2 = -1;
        assert_eq!(spz_tree_unobserved_exclusion_count_status(&full, &mut st2), 0, "the excluded path was observed in the complete scan");
    }
    // a never-existing exclusion is reported by the complete scan only
    let ghost = d.join("nope/missing");
    let full2 = run(&d, vec![ghost.clone()], false);
    let part2 = run(&d, vec![ghost], true);
    unsafe {
        let mut st = -1;
        assert_eq!(spz_tree_unobserved_exclusion_count_status(&full2, &mut st), 1);
        assert_eq!(spz_tree_unobserved_exclusion_count_status(&part2, &mut st), 0);
    }
}

#[test]
fn forgetting_from_a_cancelled_tree_subtracts_exactly_the_observed_bytes_from_every_ancestor() {
    let d = fixture("forget");
    let _cleanup = Cleanup(d.clone());
    // cancel after some entries were observed; retry until the cancel landed mid-walk with a non-trivial tree
    let full = run(&d, vec![], false);
    let mut found = None;
    for _ in 0..50 {
        let p = std::sync::Arc::new(ScanProgress::default());
        let p2 = p.clone();
        let h = std::thread::spawn(move || {
            while p2.items.load(std::sync::atomic::Ordering::Relaxed) < 40 { std::thread::yield_now(); }
            p2.cancel();
        });
        let t = scan(&d, &ScanOptions::default(), &p).unwrap();
        h.join().unwrap();
        if t.cancelled && t.len() > 3 && t.len() < full.len() { found = Some(t); break; }
    }
    let tree = found.expect("no mid-walk cancelled tree in 50 attempts");
    let victim = (1..tree.len() as u32).filter(|i| tree.size(*i) > 0).max_by_key(|i| tree.size(*i));
    let v = victim.expect("a cancelled tree with content has a non-empty node");
    let before: Vec<u64> = (0..tree.len() as u32).map(|i| tree.size(i)).collect();
    let removed = tree.size(v);
    tree.forget(v).unwrap();
    let mut anc = Some(v);
    while let Some(a) = anc {
        let want = if a == v { 0 } else { before[a as usize] - removed };
        assert_eq!(tree.size(a), want, "{}", tree.path(a));
        anc = tree.parent(a);
    }
    assert_eq!(tree.size(v), 0);
}
