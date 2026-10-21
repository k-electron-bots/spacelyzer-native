//! Engine-only unit coverage for public scan() contracts the module header
//! promises but no public-API test pinned: hard-linked files counted once,
//! user-excluded subtrees skipped AND recorded, symlinks classified but never
//! followed, and the progress counters agreeing with the produced tree.
//! Fixtures are real tempdir scans (no FFI, engine-only).

use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::{Kind, SkipReason, Tree};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

fn root_of(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("spz-scan-behaviors-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    root
}

fn scan_with(root: &Path, opts: &ScanOptions) -> (Tree, ScanProgress) {
    let progress = ScanProgress::default();
    let t = scan(root, opts, &progress).expect("fixture scans cleanly");
    (t, progress)
}

fn id(t: &Tree, rel: &str) -> u32 {
    t.find(&format!("{}/{rel}", t.root_path())).unwrap_or_else(|| panic!("missing fixture node {rel}"))
}

#[test]
fn hard_linked_file_is_counted_once() {
    let root = root_of("hardlink");
    fs::create_dir_all(root.join("a")).unwrap();
    fs::create_dir_all(root.join("b")).unwrap();
    fs::write(root.join("a/real.bin"), vec![1u8; 4096]).unwrap();
    fs::hard_link(root.join("a/real.bin"), root.join("b/alias.bin")).unwrap();
    let (t, _progress) = scan_with(&root, &ScanOptions::default());
    let (real, alias) = (id(&t, "a/real.bin"), id(&t, "b/alias.bin"));
    let (sa, sb) = (t.own_bytes(real), t.own_bytes(alias));
    // Parallel walk: WHICH link keeps the bytes is not deterministic. The
    // contract is that exactly one does (the header: "counted once").
    assert!(sa != sb, "exactly one link keeps the bytes: {sa} vs {sb}");
    assert_eq!(sa.min(sb), 0, "the duplicate contributes zero bytes");
    assert!(sa.max(sb) > 0);
    // Both paths still exist as nodes.
    assert_eq!(t.kind(real), Kind::File);
    assert_eq!(t.kind(alias), Kind::File);
    // Root total counts the file's bytes exactly once.
    assert_eq!(t.size(t.root()), sa.max(sb), "the file's bytes appear once in the root total");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn user_excluded_subtree_is_skipped_and_recorded() {
    let root = root_of("exclude");
    fs::create_dir_all(root.join("keep")).unwrap();
    fs::create_dir_all(root.join("drop")).unwrap();
    fs::write(root.join("keep/x.txt"), vec![1u8; 4096]).unwrap();
    fs::write(root.join("drop/y.txt"), vec![1u8; 8192]).unwrap();
    let excluded = root.join("drop");
    let opts = ScanOptions { exclude: vec![excluded.clone()], ..Default::default() };
    let (t, _progress) = scan_with(&root, &opts);
    assert!(t.find(&format!("{}/drop", t.root_path())).is_none(), "excluded subtree absent from the tree");
    assert!(t.find(&format!("{}/keep/x.txt", t.root_path())).is_some());
    assert_eq!(t.items, 2, "only keep/ and x.txt remain besides the root");
    let hits: Vec<_> = t.skipped.iter().filter(|s| s.reason == SkipReason::UserExcluded).collect();
    assert_eq!(hits.len(), 1, "the exclusion is recorded exactly once");
    // The recorded path is the exact string the walk compared against. The walk runs from the CANONICAL root
    // (scan canonicalizes it; macOS temp_dir is a /var -> /private/var symlink), so the record carries the
    // canonical spelling even when the request was spelled through the symlink - what lets it still match is
    // the rebase contract pinned by exclusion_spelled_through_a_symlinked_ancestor_is_honored below.
    let canonical_excluded = excluded.canonicalize().unwrap();
    assert_eq!(hits[0].path, canonical_excluded.to_string_lossy().as_ref());
    assert_eq!(t.size(t.root()), t.own_bytes(id(&t, "keep/x.txt")), "excluded bytes never enter the totals");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn exclusion_spelled_through_a_symlinked_ancestor_is_honored() {
    // The walk starts from the canonical root (scan canonicalizes it) and matches exclusions textually. A caller
    // that learned the root through a symlink - macOS /var -> /private/var is the standing case, reproduced here
    // with an explicit alias so Linux exercises the same shape - spells every exclusion through that symlink.
    // Without the rebase contract such a request matches nothing and the subtree the user asked to skip stays
    // in the tree. (Run 39653416924 failed exactly this way before the contract existed.)
    let real = root_of("excl-real");
    fs::create_dir_all(real.join("keep")).unwrap();
    fs::create_dir_all(real.join("drop")).unwrap();
    fs::write(real.join("keep/x.txt"), vec![1u8; 4096]).unwrap();
    fs::write(real.join("drop/y.txt"), vec![1u8; 8192]).unwrap();
    let alias = std::env::temp_dir().join(format!("spz-scan-behaviors-excl-alias-{}", std::process::id()));
    let _ = fs::remove_file(&alias);
    std::os::unix::fs::symlink(&real, &alias).unwrap();
    // Scan AND exclude through the alias spelling, exactly like a caller holding only the alias path.
    let (t, _progress) = scan_with(&alias, &ScanOptions { exclude: vec![alias.join("drop")], ..Default::default() });
    let root_text = t.root_path();
    assert!(t.find(&format!("{root_text}/drop")).is_none(), "an exclusion spelled through the symlink must still exclude");
    assert!(t.find(&format!("{root_text}/keep/x.txt")).is_some());
    let hits: Vec<_> = t.skipped.iter().filter(|s| s.reason == SkipReason::UserExcluded).collect();
    assert_eq!(hits.len(), 1, "the exclusion is recorded exactly once");
    assert!(t.unobserved_exclusions.is_empty(), "a matched exclusion is not reported unobserved: {:?}", t.unobserved_exclusions);
    let _ = fs::remove_file(&alias);
    let _ = fs::remove_dir_all(&real);
}

#[test]
fn exclusion_spelled_through_a_symlink_entry_inside_the_tree_excludes_nothing() {
    // No silent broadening: `alias` below is a scanned symlink ENTRY (classified, never followed), so a request
    // naming a path through it names no scanned entry. Excluding the target instead would hide a subtree the
    // user never asked to skip. The rebase resolves only prefixes that name the scan root itself, never
    // components below it.
    let root = root_of("excl-inner");
    fs::create_dir_all(root.join("real")).unwrap();
    fs::write(root.join("real/f.txt"), vec![1u8; 4096]).unwrap();
    std::os::unix::fs::symlink(root.join("real"), root.join("alias")).unwrap();
    let excluded = root.join("alias/f.txt");
    let (t, _progress) = scan_with(&root, &ScanOptions { exclude: vec![excluded], ..Default::default() });
    let root_text = t.root_path();
    assert!(t.find(&format!("{root_text}/real/f.txt")).is_some(), "the target must stay: no broadening through an in-tree symlink");
    assert!(t.find(&format!("{root_text}/alias")).is_some(), "the symlink entry itself is classified, not excluded");
    assert!(t.skipped.iter().all(|s| s.reason != SkipReason::UserExcluded), "nothing was excluded");
    assert_eq!(t.unobserved_exclusions.len(), 1, "the unmatchable request is reported, not silently dropped");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn symlinks_are_classified_and_never_followed() {
    let root = root_of("symlink");
    fs::create_dir_all(root.join("real")).unwrap();
    fs::write(root.join("real/inside.txt"), vec![1u8; 4096]).unwrap();
    // A target OUTSIDE the scanned root with bytes that must not be counted.
    let outside = root_of("symlink-target");
    fs::write(outside.join("outside.bin"), vec![1u8; 32768]).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("link-out")).unwrap();
    std::os::unix::fs::symlink(root.join("real"), root.join("link-in")).unwrap();
    std::os::unix::fs::symlink(root.join("no-such-target"), root.join("broken")).unwrap();
    let (t, _progress) = scan_with(&root, &ScanOptions::default());
    for name in ["link-out", "link-in", "broken"] {
        assert_eq!(t.kind(id(&t, name)), Kind::Symlink, "{name} is a Symlink node");
    }
    assert!(t.find(&format!("{}/outside.bin", t.root_path())).is_none(), "no traversal through the outbound symlink");
    assert!(t.find(&format!("{}/link-in/inside.txt", t.root_path())).is_none(), "no traversal through the inbound symlink");
    assert!(t.find(&format!("{}/no-such-target", t.root_path())).is_none(), "the dangling target does not exist as a node");
    // Only real/ and inside.txt carry bytes; the tree has exactly 5 nodes + root.
    assert_eq!(t.items, 5);
    assert_eq!(t.size(t.root()), t.own_bytes(id(&t, "real/inside.txt")) + symlink_bytes(&t));
    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&outside);
}

/// Symlink nodes carry their own lstat allocation (normally zero).
fn symlink_bytes(t: &Tree) -> u64 {
    ["link-out", "link-in", "broken"].iter().map(|n| t.own_bytes(id(t, n))).sum()
}

#[test]
fn progress_counters_agree_with_the_tree() {
    let root = root_of("progress");
    fs::create_dir_all(root.join("d1/d2")).unwrap();
    fs::write(root.join("d1/one.bin"), vec![1u8; 4096]).unwrap();
    fs::write(root.join("d1/d2/two.bin"), vec![1u8; 8192]).unwrap();
    fs::write(root.join("top.bin"), vec![1u8; 2048]).unwrap();
    let (t, progress) = scan_with(&root, &ScanOptions::default());
    assert_eq!(progress.items.load(Ordering::Relaxed), t.items, "every enumerated entry became a node");
    // progress.bytes sums per-directory local (file) allocations; the root total
    // is the same rollup. Directory self-allocations are not counted anywhere.
    assert_eq!(progress.bytes.load(Ordering::Relaxed), t.size(t.root()));
    assert!(!t.cancelled);
    let _ = fs::remove_dir_all(&root);
}
