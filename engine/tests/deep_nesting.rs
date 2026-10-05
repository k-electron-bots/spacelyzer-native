//! Regression: `walk` recurses once per directory level. On a path deeper than a 2 MiB thread stack allows, the process died with a stack overflow
//! (SIGABRT) instead of returning a tree. Linux allows ~2000 levels of one-letter names (PATH_MAX 4096), enough to hit it.
//! One test per binary: it changes the process working directory to build the fixture past PATH_MAX.
use spacelyzer_engine::scan::{new_progress, scan, ScanOptions};

fn build(depth: usize) -> (std::path::PathBuf, usize) {
    let d = std::env::temp_dir().join(format!("spz-deep-{}", std::process::id()));
    let _ = std::process::Command::new("rm").arg("-rf").arg(&d).status();
    std::fs::create_dir_all(&d).unwrap();
    let orig = std::env::current_dir().unwrap();
    std::env::set_current_dir(&d).unwrap();
    let mut made = 0;
    for _ in 0..depth {
        if std::fs::create_dir("d").is_err() || std::env::set_current_dir("d").is_err() { break; }
        made += 1;
    }
    let _ = std::fs::write("leaf", vec![1u8; 8192]);
    std::env::set_current_dir(&orig).unwrap();
    (d, made)
}

#[test]
fn nesting_past_the_stack_budget_returns_a_tree_and_reports_what_it_could_not_read() {
    let (d, made) = build(6000);
    assert!(made >= 1500, "fixture only reached depth {made}; this filesystem cannot exercise the case");
    // The caller's stack is not ours to size: run the scan from a deliberately small (1 MiB) caller thread, with the default and an explicit worker count.
    // Without the fix the default-count walk runs on this thread and aborts the whole test process (SIGABRT), which is the failure being guarded.
    for threads in [0usize, 2] {
        let dd = d.clone();
        let t = std::thread::Builder::new().stack_size(1 << 20).spawn(move || {
            let opts = ScanOptions { threads, ..Default::default() };
            scan(&dd, &opts, &new_progress()).expect("scan must return, not abort")
        }).unwrap().join().unwrap();
        assert!(t.len() > 1000, "threads={threads}: tree has {} nodes", t.len());
        // Past PATH_MAX the kernel refuses the open; that has to be listed, never silently absent.
        let sk: u32 = t.skipped_counts().iter().sum();
        assert!(sk >= 1, "threads={threads}: nothing reported as unreadable at the PATH_MAX boundary");
    }
    let _ = std::process::Command::new("rm").arg("-rf").arg(&d).status();
}
