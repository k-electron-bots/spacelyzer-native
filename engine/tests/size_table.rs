use spacelyzer_engine::tree::{admission_cap, live_tables, MutationError, Tree};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(()); // failpoint and counters are process-global

/// Exact check against the version-0 own bytes: a node is either forgotten (size 0 and all children 0) or equals
/// its original own bytes plus the sum of its children in this same snapshot.
fn exact_ok(t: &Tree, own0: &[u64], sizes: &[u64]) -> bool {
    (0..t.len() as u32).all(|i| {
        let kids: u64 = t.children(i).map(|c| sizes[c as usize]).sum();
        let s = sizes[i as usize];
        if s == 0 && (kids == 0) { return true; } // forgotten subtree, or empty
        s == own0[i as usize] + kids
    })
}
fn own_v0(t: &Tree) -> Vec<u64> { let tab = t.table(); (0..t.len() as u32).map(|i| t.own_bytes_in(&tab.sizes, i)).collect() }

fn dir_sum_ok(t: &Tree, sizes: &[u64]) -> bool {
    (0..t.len() as u32).all(|i| {
        let r = t.children(i);
        r.is_empty() || sizes[i as usize] >= r.map(|c| sizes[c as usize]).sum::<u64>()
    })
}
/// Directories with pairwise disjoint subtrees (none inside another), so every forget is a real commit.
fn disjoint_dirs(t: &Tree, k: usize) -> Vec<u32> {
    let tab = t.table();
    let mut out: Vec<u32> = Vec::new();
    for i in (1..t.len() as u32).rev() {
        if t.children(i).is_empty() || tab.sizes[i as usize] == 0 { continue; }
        let mut a = t.parent(i); let mut inside = false;
        while let Some(p) = a { if out.contains(&p) { inside = true; break; } a = t.parent(p); }
        if !inside && !out.iter().any(|&d| { let mut x = t.parent(d); while let Some(p) = x { if p == i { return true; } x = t.parent(p); } false }) { out.push(i); if out.len() == k { break; } }
    }
    assert_eq!(out.len(), k);
    out
}
fn some_dirs(t: &Tree, k: usize) -> Vec<u32> {
    (1..t.len() as u32).filter(|&i| !t.children(i).is_empty()).take(k).collect()
}

#[test]
fn two_writers_do_not_lose_updates() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let t = Arc::new(Tree::synthetic(200_000));
    let ids = disjoint_dirs(&t, 40);
    let before = t.table().sizes.clone();
    // sequential reference on a twin tree
    let r = Tree::synthetic(200_000);
    for &i in &ids { r.forget(i).unwrap(); }
    let (a, b) = (ids[..20].to_vec(), ids[20..].to_vec());
    let (t1, t2) = (t.clone(), t.clone());
    let h1 = std::thread::spawn(move || for i in a { t1.forget(i).unwrap(); });
    let h2 = std::thread::spawn(move || for i in b { t2.forget(i).unwrap(); });
    h1.join().unwrap(); h2.join().unwrap();
    assert_eq!(t.table().sizes, r.table().sizes, "final table must equal the sequential reference exactly");
    assert_eq!(t.table().version, ids.len() as u64, "version == number of distinct committed ids");
    assert!(t.table().sizes[0] < before[0]);
}

#[test]
fn no_alloc_walk_matches_a_naive_reference_for_every_node() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let n = 3000;
    let base = Tree::synthetic(n);
    let v0 = base.table().sizes.clone();
    for id in 0..n as u32 {
        let t = Tree::synthetic(n);
        // naive: collect subtree recursively
        fn walk(t: &Tree, i: u32, out: &mut Vec<u32>) { out.push(i); for c in t.children(i) { walk(t, c, out); } }
        let mut sub = Vec::new(); walk(&t, id, &mut sub);
        let removed = v0[id as usize];
        let mut want = v0.clone();
        for &x in &sub { want[x as usize] = 0; }
        let mut a = t.parent(id);
        while let Some(p) = a { want[p as usize] = want[p as usize].saturating_sub(removed); a = t.parent(p); }
        assert!(t.forget(id).is_ok());
        assert_eq!(t.table().sizes, want, "node {id} (root/file/dir/last child all covered)");
    }
}

#[test]
fn invalid_id_leaves_table_unchanged() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let t = Tree::synthetic(1000);
    let v = t.table().version;
    assert_eq!(t.forget(u32::MAX), Err(MutationError::Invalid));
    assert_eq!(t.table().version, v);
}

#[cfg(feature = "failpoints")]
#[test]
fn panic_at_each_failpoint_leaves_table_unchanged_and_later_commits_work() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let t = Tree::synthetic(50_000);
    let id = some_dirs(&t, 1)[0];
    for fp in 1..=3u8 {
        let before = t.table();
        spacelyzer_engine::tree::set_failpoint(fp);
        assert_eq!(t.forget(id), Err(MutationError::Panicked), "failpoint {fp}");
        let after = t.table();
        assert_eq!(before.version, after.version);
        assert_eq!(before.sizes, after.sizes);
    }
    // writer mutex was poisoned? it is released before unwind escapes, but recovery is also exercised via into_inner
    assert!(t.forget(id).is_ok());
    assert_eq!(t.table().version, 1);
    assert_eq!(t.table().sizes[id as usize], 0);
}

#[test]
fn readers_see_consistent_snapshots_during_commits() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let t = Arc::new(Tree::synthetic(100_000));
    let own0 = Arc::new(own_v0(&t));
    let stop = Arc::new(AtomicBool::new(false));
    let readers: Vec<_> = (0..3).map(|_| {
        let (t, stop, own0) = (t.clone(), stop.clone(), own0.clone());
        std::thread::spawn(move || {
            let mut n = 0u64;
            while !stop.load(Ordering::Relaxed) {
                let c = t.capture().expect("admission");
                assert!(dir_sum_ok(&t, &c.table.sizes) && exact_ok(&t, &own0, &c.table.sizes), "inconsistent snapshot at version {}", c.table.version);
                n += 1;
            }
            n
        })
    }).collect();
    for i in disjoint_dirs(&t, 30) { t.forget(i).unwrap(); }
    stop.store(true, Ordering::Relaxed);
    let checks: u64 = readers.into_iter().map(|h| h.join().unwrap()).sum();
    assert!(checks > 0);
    assert_eq!(t.running(), 0);
}

#[test]
fn parked_readers_pinning_different_versions_stay_inside_the_memory_budget() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let t = Tree::synthetic(20_000);
    let cap = admission_cap(t.len());
    assert_eq!(cap, 64);
    let base = live_tables();
    let dirs = disjoint_dirs(&t, 200);
    // each parked reader pins a DIFFERENT version: capture, commit, capture, commit...
    let mut held = Vec::new();
    for k in 0..cap {
        held.push(t.capture().expect("under cap"));
        t.forget(dirs[k]).unwrap();
    }
    let versions: std::collections::HashSet<u64> = held.iter().map(|c| c.table.version).collect();
    assert_eq!(versions.len(), cap, "readers must pin distinct versions");
    assert!(t.capture().is_none(), "over the cap is refused (Busy), not queued");
    for i in 64..130 { t.forget(dirs[i]).unwrap(); }
    // pinned distinct versions + current: nothing else survives
    assert_eq!(live_tables(), base + cap, "live {} base {} cap {}", live_tables(), base, cap);
    let bytes = live_tables() * t.len() * 8;
    eprintln!("live tables {} = {} KiB for {} nodes", live_tables(), bytes / 1024, t.len());
    drop(held);
    assert_eq!(live_tables(), base);
    assert_eq!(t.running(), 0);
}

#[test]
fn cap_scales_down_with_tree_size_to_hold_the_memory_budget() {
    assert_eq!(admission_cap(5_000_000), 6);
    assert_eq!(admission_cap(1_000_000), 33);
    assert_eq!(admission_cap(100), 64);
    // worst case (cap pinned + current + one under construction) at 5M nodes stays near the budget
    let worst = (admission_cap(5_000_000) + 2) * 5_000_000 * 8; // status-API readers only
    assert!(worst < 400 << 20, "{worst}");
    // oversize: a table bigger than the budget is still admitted once per tree (floor 1), refused beyond that
    assert_eq!(admission_cap(40_000_000), 1);
}

#[test]
fn ffi_filter_and_layout_become_stale_after_forget_and_busy_is_not_empty() {
    use spacelyzer_engine::ffi::*;
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut t0 = Tree::synthetic(30_000); t0.uid = 1;
    let tp = Box::into_raw(Box::new(t0));
    unsafe {
        let mk = || -> SpzFilter { std::mem::zeroed() };
        let mut st = -1i32;
        let h = spz_filter_apply_status(tp, std::ptr::null(), std::ptr::null(), mk(), &mut st);
        assert!(!h.is_null() && st == 0);
        assert_eq!(spz_filter_status(tp, h), 0);
        let mut lst = -1;
        let l = spz_layout_new_status(tp, 0, 800.0, 600.0, h, &mut lst);
        assert!(!l.is_null() && lst == 0 && spz_layout_status(tp, l) == 0);
        let id = some_dirs(&*tp, 1)[0];
        assert_eq!(spz_tree_forget(tp, id), 0);
        assert_eq!(spz_filter_status(tp, h), 1, "same tree, newer table: STALE");
        assert_eq!(spz_layout_status(tp, l), 1);
        let mut s2 = -1;
        assert!(spz_layout_new_status(tp, 0, 800.0, 600.0, h, &mut s2).is_null());
        assert_eq!(s2, 1, "stale handle is refused, not an empty layout");
        // another tree: INVALID
        let mut t1 = Tree::synthetic(30_000); t1.uid = 99;
        let other = Box::into_raw(Box::new(t1));
        assert_eq!(spz_filter_status(other, h), 3);
        // BUSY: park the cap, then every capture-based call reports 4 with a null handle
        let held: Vec<_> = (0..admission_cap((*tp).len())).map(|_| (*tp).capture().unwrap()).collect();
        let mut s3 = -1;
        assert!(spz_filter_apply_status(tp, std::ptr::null(), std::ptr::null(), mk(), &mut s3).is_null());
        assert_eq!(s3, 4);
        drop(held);
        spz_filter_free(h); spz_layout_free(l);
        drop(Box::from_raw(other)); drop(Box::from_raw(tp));
    }
}

#[test]
fn outline_sort_uses_one_captured_table_across_all_expanded_dirs() {
    use spacelyzer_engine::outline::{visible_rows_sorted_in, SortMode};
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let t = Tree::synthetic(50_000);
    let old = t.table();
    // commit removes big dirs AFTER the table was captured; the call must still order by the captured one
    for d in disjoint_dirs(&t, 20) { t.forget(d).unwrap(); }
    let expanded: std::collections::HashSet<u32> = (0..t.len() as u32).filter(|&i| !t.children(i).is_empty()).take(300).collect();
    let rows = visible_rows_sorted_in(&t, &old, 0, &expanded, None, SortMode::SizeAsc);
    let mut by_depth_parent: std::collections::HashMap<u32, Vec<u64>> = Default::default();
    for r in &rows { by_depth_parent.entry(t.parent(r.node).unwrap_or(u32::MAX)).or_default().push(old.sizes[r.node as usize]); }
    assert!(by_depth_parent.values().all(|v| v.windows(2).all(|w| w[0] <= w[1])), "siblings must be sorted by the captured (old) sizes");
}

#[test]
fn global_budget_is_shared_across_trees_and_first_capture_is_always_admitted() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    // two 3M-node trees: 24 MB tables, cap 11 each (256 MiB / 24 MB)
    let (a, b) = (Tree::synthetic(3_000_000), Tree::synthetic(3_000_000));
    let mut held = vec![];
    while let Some(c) = a.capture() { held.push(c); }
    let on_a = held.len();
    let first_b = b.capture();
    assert!(first_b.is_some(), "a tree's first capture is admitted even when the global budget is spent");
    assert!(b.capture().is_none(), "second capture on b is refused: the process-wide budget is spent");
    assert_eq!(on_a, 11);
    drop(held);
    assert_eq!(a.running(), 0);
}

#[test]
fn legacy_filter_stamp_matches_the_table_it_was_computed_on() {
    use spacelyzer_engine::ffi::*;
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut t0 = Tree::synthetic(20_000); t0.uid = 5;
    let tp = &t0 as *const Tree;
    unsafe {
        let h = spz_filter_apply(tp, std::ptr::null(), std::ptr::null(), std::mem::zeroed());
        assert_eq!(spz_filter_status(tp, h), 0);
        let before = spz_tree_version(tp);
        t0.forget(some_dirs(&t0, 1)[0]).unwrap();
        assert_eq!(spz_tree_version(tp), before + 1);
        assert_eq!(spz_filter_status(tp, h), 1, "result computed on the old table is stamped old and reports STALE");
        spz_filter_free(h);
    }
}

#[test]
fn legacy_filtered_layout_is_stamped_with_the_handles_version() {
    use spacelyzer_engine::ffi::*;
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut t0 = Tree::synthetic(20_000); t0.uid = 6;
    let tp = &t0 as *const Tree;
    unsafe {
        let h = spz_filter_apply(tp, std::ptr::null(), std::ptr::null(), std::mem::zeroed());
        // commit lands between the filter and the layout: the handle is old, so the layout must be stamped old
        t0.forget(some_dirs(&t0, 1)[0]).unwrap();
        let l = spz_layout_new_filtered(tp, 0, 800.0, 600.0, h);
        assert_eq!(spz_layout_status(tp, l), 1, "old handle sizes must not carry the new version stamp");
        spz_layout_free(l); spz_filter_free(h);
    }
}

#[test]
fn concurrent_captures_never_exceed_the_shared_budget_by_more_than_first_captures() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let trees: Vec<Arc<Tree>> = (0..4).map(|_| Arc::new(Tree::synthetic(3_000_000))).collect();
    let peak = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let hs: Vec<_> = trees.iter().cloned().map(|t| { let peak = peak.clone(); std::thread::spawn(move || {
        let mut held = vec![];
        for _ in 0..40 { if let Some(c) = t.capture() { held.push(c); } peak.fetch_max(spacelyzer_engine::tree::reserved_bytes(), Ordering::Relaxed); }
    }) }).collect();
    for h in hs { h.join().unwrap(); }
    // budget + one exempt first capture per tree
    assert!(peak.load(Ordering::Relaxed) <= (256 << 20) + 4 * 3_000_000 * 8, "peak {}", peak.load(Ordering::Relaxed));
    assert_eq!(spacelyzer_engine::tree::reserved_bytes(), 0);
}

#[test]
fn snapshot_reads_carry_version_and_reject_stale_between_count_and_fill() {
    use spacelyzer_engine::ffi::*;
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let mut t0 = Tree::synthetic(20_000); t0.uid = 8;
    let tp = &t0 as *const Tree;
    unsafe {
        let (mut v, mut st) = (0u64, -1i32);
        let n = spz_outline_rows_status(tp, 0, std::ptr::null(), 0, std::ptr::null(), 0, std::ptr::null_mut(), 0, u64::MAX, &mut v, &mut st);
        assert!(st == 0 && n > 0 && v == 0);
        // a commit lands between the count call and the fill call
        t0.forget(some_dirs(&t0, 1)[0]).unwrap();
        let mut rows = vec![std::mem::zeroed::<spacelyzer_engine::outline::Row>(); n as usize];
        let (mut v2, mut st2) = (0u64, -1i32);
        let n2 = spz_outline_rows_status(tp, 0, std::ptr::null(), 0, std::ptr::null(), 0, rows.as_mut_ptr(), n, v, &mut v2, &mut st2);
        assert_eq!((n2, st2), (0, 1), "fill with the old expected version must be STALE and write nothing");
        // node status: same rule
        let mut node: SpzNode = std::mem::zeroed();
        let mut st3 = -1;
        spz_tree_node_status(tp, 1, &mut node, v, &mut v2, &mut st3);
        assert_eq!(st3, 1);
        spz_tree_node_status(tp, 1, &mut node, u64::MAX, &mut v2, &mut st3);
        assert!(st3 == 0 && v2 == 1);
        // largest and categories with a stale filter handle
        let h = spz_filter_apply(tp, std::ptr::null(), std::ptr::null(), std::mem::zeroed());
        t0.forget(disjoint_dirs(&t0, 1)[0]).unwrap();
        let mut ids = [0u32; 10]; let mut st4 = -1;
        let c = spz_largest_status(tp, h, 10, ids.as_mut_ptr(), u64::MAX, &mut v2, &mut st4);
        assert!(c == 0 && st4 == 1, "stale filter must be STALE, not an empty OK: status {st4}");
        spz_filter_free(h);
    }
}
