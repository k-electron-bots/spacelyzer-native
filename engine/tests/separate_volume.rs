//! Linux-only end-to-end for the "needs a second filesystem" known gap: a subdirectory on a genuinely different
//! filesystem (a real tmpfs mounted in a private user+mount namespace) is recorded SeparateVolume and never
//! descended; cross_devices=true descends it. No system directories are scanned - the fixture is hermetic.
#![cfg(target_os = "linux")]
use spacelyzer_engine::*;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::process::Command;

const SELF_NAME: &str = "a_subdirectory_on_a_separate_filesystem_is_recorded_separate_volume_and_not_descended";

#[test]
fn a_subdirectory_on_a_separate_filesystem_is_recorded_separate_volume_and_not_descended() {
    if std::env::var("SPZ_TEST_IN_USERNS").is_err() {
        // Re-run ONLY this test inside a private user+mount namespace so the fixture can hold a real second filesystem.
        let exe = std::env::current_exe().unwrap();
        let st = Command::new("unshare").args(["-rm", "--"]).arg(&exe)
            .args([SELF_NAME, "--exact", "--nocapture", "--test-threads=1"])
            .env("SPZ_TEST_IN_USERNS", "1")
            .status().expect("spawn unshare (this test needs user+mount namespaces)");
        assert!(st.success(), "inner namespaced run failed (needs unshare -rm and tmpfs mount support)");
        return;
    }
    let root = std::env::temp_dir().join(format!("sepv-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("vol")).unwrap();
    fs::write(root.join("keep"), vec![1u8; 6000]).unwrap();
    // Negative control, same fixture BEFORE the mount: an ordinary same-filesystem subdirectory records nothing.
    let t = scan(&root.canonicalize().unwrap(), &ScanOptions::default(), &ScanProgress::default()).unwrap();
    assert_eq!(t.skipped_counts()[SkipReason::SeparateVolume as usize], 0, "pre-mount control: no SeparateVolume without a second filesystem");

    let st = Command::new("mount").args(["-t", "tmpfs", "tmpfs"]).arg(root.join("vol")).status().unwrap();
    assert!(st.success(), "tmpfs mount failed inside the private namespace");
    fs::write(root.join("vol/hidden"), vec![1u8; 9000]).unwrap();
    let root = root.canonicalize().unwrap();
    let vol = root.join("vol").to_str().unwrap().to_string();
    assert_ne!(fs::metadata(&root).unwrap().dev(), fs::metadata(root.join("vol")).unwrap().dev(), "precondition: the mount is a different filesystem");

    let t = scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    assert!(t.find(root.join("keep").to_str().unwrap()).is_some(), "same-volume content is scanned");
    assert!(t.find(root.join("vol/hidden").to_str().unwrap()).is_none(), "the other filesystem is never descended");
    let vols: Vec<_> = t.skipped.iter().filter(|s| s.path == vol).collect();
    assert_eq!(vols.len(), 1, "the mount point itself is recorded exactly once, skipped: {:?}", t.skipped.iter().map(|s| (&s.path, s.reason)).collect::<Vec<_>>());
    assert_eq!(vols[0].reason, SkipReason::SeparateVolume);
    assert_eq!(t.skipped_counts()[SkipReason::SeparateVolume as usize], 1);

    let t = scan(&root, &ScanOptions { cross_devices: true, ..Default::default() }, &ScanProgress::default()).unwrap();
    assert!(t.find(root.join("vol/hidden").to_str().unwrap()).is_some(), "cross_devices=true descends the other filesystem");
    assert_eq!(t.skipped_counts()[SkipReason::SeparateVolume as usize], 0);
}
