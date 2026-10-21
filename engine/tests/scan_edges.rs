//! Engine-only unit coverage for scan() edge contracts: pre-cancelled scans,
//! unreadable directories, and canonical root paths. Real tempdir fixtures,
//! no FFI, engine-only.

use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::{SkipReason, Tree};
use std::fs;
use std::path::{Path, PathBuf};

fn root_of(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("spz-scan-edges-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn pre_cancelled_scan_returns_an_empty_cancelled_tree() {
    let root = root_of("cancel");
    fs::write(root.join("a.bin"), vec![1u8; 4096]).unwrap();
    fs::create_dir_all(root.join("sub")).unwrap();
    fs::write(root.join("sub/b.bin"), vec![1u8; 4096]).unwrap();
    let progress = ScanProgress::default();
    progress.cancel();
    let t = scan(&root, &ScanOptions::default(), &progress).expect("cancelled scan still returns a tree");
    assert!(t.cancelled, "the tree records the cancellation");
    assert_eq!(t.items, 0, "a pre-cancelled walk enumerates nothing");
    assert_eq!(t.size(t.root()), 0);
    assert_eq!(t.len(), 1, "only the root node exists");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn unreadable_dir_is_recorded_and_the_scan_continues() {
    let root = root_of("denied");
    fs::create_dir_all(root.join("open")).unwrap();
    fs::write(root.join("open/ok.txt"), vec![1u8; 4096]).unwrap();
    let shut = root.join("shut");
    fs::create_dir_all(&shut).unwrap();
    fs::write(shut.join("secret.txt"), vec![1u8; 4096]).unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&shut, fs::Permissions::from_mode(0o000)).unwrap();
    // Self-calibrating: as root (or with CAP_DAC_OVERRIDE) the directory is
    // still readable and this contract cannot be exercised - skip cleanly.
    if fs::read_dir(&shut).is_ok() {
        let _ = fs::set_permissions(&shut, fs::Permissions::from_mode(0o755));
        let _ = fs::remove_dir_all(&root);
        return;
    }
    let (t, _progress) = {
        let progress = ScanProgress::default();
        let t = scan(&root, &ScanOptions::default(), &progress).expect("scan survives an unreadable dir");
        (t, progress)
    };
    let denied: Vec<_> = t.skipped.iter().filter(|s| s.reason == SkipReason::PermissionDenied).collect();
    assert_eq!(denied.len(), 1, "the unreadable dir is recorded once");
    assert!(denied[0].path.ends_with("/shut"), "recorded path is the unreadable dir: {}", denied[0].path);
    assert!(t.find(&format!("{}/shut", t.root_path())).is_some(), "the dir node itself still exists");
    assert!(t.find(&format!("{}/shut/secret.txt", t.root_path())).is_none(), "its contents are absent");
    assert!(t.find(&format!("{}/open/ok.txt", t.root_path())).is_some(), "sibling subtrees scan normally");
    assert_eq!(t.size(t.root()), t.own_bytes(t.find(&format!("{}/open/ok.txt", t.root_path())).unwrap()), "denied bytes are not counted");
    let _ = fs::set_permissions(&shut, fs::Permissions::from_mode(0o755));
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn scan_root_is_canonicalized() {
    let root = root_of("canonical");
    fs::write(root.join("f.txt"), vec![1u8; 4096]).unwrap();
    let link = std::env::temp_dir().join(format!("spz-scan-edges-canonical-link-{}", std::process::id()));
    let _ = fs::remove_file(&link);
    std::os::unix::fs::symlink(&root, &link).unwrap();
    let progress = ScanProgress::default();
    let t: Tree = scan(&link, &ScanOptions::default(), &progress).expect("scan through a symlinked root");
    let canonical = root.canonicalize().unwrap();
    assert_eq!(Path::new(t.root_path()), canonical.as_path(), "root_path is the canonical target, not the symlink");
    assert!(t.find(&format!("{}/f.txt", t.root_path())).is_some());
    let _ = fs::remove_file(&link);
    let _ = fs::remove_dir_all(&root);
}
