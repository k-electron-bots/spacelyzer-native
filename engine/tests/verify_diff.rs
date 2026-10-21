//! Unit coverage for the `spz verify` mismatch detail: pure map diffing, ancestor collapsing,
//! overlap counting, and the Tree-backed map on a real fixture that changes between scans.
mod common;

use spacelyzer_engine::verify_diff::*;
use spacelyzer_engine::{scan, ScanOptions, ScanProgress};
use std::collections::HashMap;

fn map(pairs: &[(&str, u64)]) -> HashMap<String, u64> {
    pairs.iter().map(|(p, b)| (p.to_string(), *b)).collect()
}

#[test]
fn empty_maps_diff_clean() {
    let d = diff_maps(&HashMap::new(), &HashMap::new());
    assert!(d.is_empty());
    assert_eq!(d.len(), 0);
    assert!(d.leaf_most().is_empty());
    assert_eq!(d.overlap(&d), 0);
}

#[test]
fn classifies_only_and_size_entries_sorted_by_path() {
    let a = map(&[("/r/a", 1), ("/r/b", 2), ("/r/c", 3)]);
    let b = map(&[("/r/a", 1), ("/r/b", 20), ("/r/d", 4)]);
    let d = diff_maps(&a, &b);
    assert_eq!(d.len(), 3);
    assert_eq!(
        d.entries,
        vec![
            DiffEntry::SizeDiffers { path: "/r/b".into(), a_bytes: 2, b_bytes: 20 },
            DiffEntry::OnlyInA { path: "/r/c".into(), bytes: 3 },
            DiffEntry::OnlyInB { path: "/r/d".into(), bytes: 4 },
        ],
        "entries must be classified and sorted by path: {:?}",
        d.entries
    );
}

#[test]
fn leaf_most_drops_paths_with_a_differing_ancestor() {
    let a = map(&[("/r", 10), ("/r/a", 4), ("/r/b", 6), ("/r/b/c", 6)]);
    let b = map(&[("/r", 99), ("/r/a", 5), ("/r/b", 7), ("/r/b/c", 7)]);
    let d = diff_maps(&a, &b);
    assert_eq!(d.len(), 4, "every path differs here");
    let leaf: Vec<&str> = d.leaf_most().iter().map(|e| e.path()).collect();
    assert_eq!(leaf, vec!["/r/a", "/r/b/c"], "root and /r/b collapse behind their differing descendants: {leaf:?}");
}

#[test]
fn leaf_most_keeps_a_path_whose_ancestor_is_not_in_the_diff() {
    // Only /r/a differs; /r agrees, so /r/a stays.
    let a = map(&[("/r", 4), ("/r/a", 4)]);
    let b = map(&[("/r", 4), ("/r/a", 9)]);
    let d = diff_maps(&a, &b);
    let leaf: Vec<&str> = d.leaf_most().iter().map(|e| e.path()).collect();
    assert_eq!(leaf, vec!["/r/a"]);
}

#[test]
fn overlap_counts_exact_paths_only() {
    let a = map(&[("/r/a", 1), ("/r/b", 2), ("/r/c", 3)]);
    let b = map(&[("/r/a", 9), ("/r/b", 9), ("/r/c", 3)]);
    let d1 = diff_maps(&a, &b); // /r/a, /r/b differ
    let c = map(&[("/r/a", 5), ("/r/b", 2), ("/r/c", 3)]);
    let d2 = diff_maps(&a, &c); // only /r/a differs
    assert_eq!(d1.overlap(&d2), 1);
    assert_eq!(d2.overlap(&d1), 1);
}

#[test]
fn tree_size_map_tracks_a_fixture_change_between_scans() {
    let dir = std::env::temp_dir().join(format!("spz-verify-diff-{}", std::process::id()));
    if dir.exists() {
        std::fs::remove_dir_all(&dir).unwrap();
    }
    common::made(std::fs::create_dir_all(dir.join("sub")));
    common::made(std::fs::write(dir.join("a.txt"), b"alpha"));
    common::made(std::fs::write(dir.join("sub/b.bin"), vec![0u8; 4096]));

    let first = scan(&dir, &ScanOptions::default(), &ScanProgress::default()).expect("scan 1");
    common::made(std::fs::write(dir.join("sub/new.md"), b"brand new\n"));
    let second = scan(&dir, &ScanOptions::default(), &ScanProgress::default()).expect("scan 2");

    let d = diff_maps(&tree_size_map(&first), &tree_size_map(&second));
    // The scanner records canonicalized paths; temp_dir() may itself be a symlink
    // (macOS: /var -> /private/var), so expectations must be canonicalized too.
    let cdir = dir.canonicalize().expect("canonicalize fixture dir");
    let root = cdir.to_string_lossy().to_string();
    let new_file = cdir.join("sub/new.md").to_string_lossy().to_string();
    let sub = cdir.join("sub").to_string_lossy().to_string();

    assert!(
        d.entries.iter().any(|e| matches!(e, DiffEntry::OnlyInB { path, .. } if *path == new_file)),
        "the added file must show as only-in-second: {:?}",
        d.entries
    );
    assert!(
        d.entries.iter().any(|e| matches!(e, DiffEntry::SizeDiffers { path, .. } if *path == root)),
        "the root cumulative size must differ: {:?}",
        d.entries
    );
    // The quiet fixture case: an unchanged tree maps to an empty diff.
    let third = scan(&dir, &ScanOptions::default(), &ScanProgress::default()).expect("scan 3");
    let quiet = diff_maps(&tree_size_map(&second), &tree_size_map(&third));
    assert!(quiet.is_empty(), "unchanged fixture must diff clean: {:?}", quiet.entries);

    // leaf-most collapses root and sub behind the added file.
    let leaf: Vec<&str> = d.leaf_most().iter().map(|e| e.path()).collect();
    assert_eq!(leaf, vec![new_file.as_str()], "only the added file remains: {leaf:?}");
    assert!(!leaf.contains(&sub.as_str()));

    std::fs::remove_dir_all(&dir).unwrap();
}
