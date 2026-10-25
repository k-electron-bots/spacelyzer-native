//! Environment-driven check against a REAL mounted volume, a permission-denied directory and a volume that is detached while the scan
//! runs. It does nothing unless the driver (scripts/ship-volumes.py) sets SPZ_RV_ROOT; an unset run prints `REAL-VOLUME not-run` and
//! the driver treats that as a failure, never a pass. Each executed case prints one `REAL-VOLUME case <name> <PASS|FAIL> ...` line.
//! Env: SPZ_RV_ROOT scan root; SPZ_RV_VOL mountpoint inside it; SPZ_RV_DENIED mode-000 directory inside it; SPZ_RV_DETACH shell command
//! that detaches the volume; SPZ_RV_HIDDEN absolute path of a file that exists on the mounted volume; SPZ_RV_HIDDEN_BYTES its size.
#![cfg(unix)]
use spacelyzer_engine::*;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn env(k: &str) -> Option<String> { std::env::var(k).ok().filter(|v| !v.is_empty()) }

fn line(name: &str, ok: bool, detail: &str) -> bool {
    println!("REAL-VOLUME case {} {} {}", name, if ok { "PASS" } else { "FAIL" }, detail);
    ok
}

#[test]
fn real_volume_cases() {
    println!();
    let Some(root) = env("SPZ_RV_ROOT") else { println!("REAL-VOLUME not-run (SPZ_RV_ROOT unset)"); return };
    let vol = env("SPZ_RV_VOL").expect("SPZ_RV_VOL");
    let denied = env("SPZ_RV_DENIED").expect("SPZ_RV_DENIED");
    let hidden = env("SPZ_RV_HIDDEN").expect("SPZ_RV_HIDDEN");
    let hidden_bytes: u64 = env("SPZ_RV_HIDDEN_BYTES").expect("SPZ_RV_HIDDEN_BYTES").parse().unwrap();
    let detach = env("SPZ_RV_DETACH").expect("SPZ_RV_DETACH");
    let root = PathBuf::from(root).canonicalize().expect("root");
    let canon = |p: &str| -> String {
        // The mountpoint and fixture paths are compared in the scan's canonical spelling (macOS /var -> /private/var).
        let pb = PathBuf::from(p);
        let (dir, name) = (pb.parent().unwrap().canonicalize().unwrap(), pb.file_name().unwrap().to_owned());
        dir.join(name).to_str().unwrap().to_string()
    };
    let (vol, denied, hidden) = (canon(&vol), canon(&denied), canon(&hidden));
    let mut all = true;
    let skipped_desc = |t: &Tree| t.skipped.iter().map(|s| format!("{}:{:?}", s.path, s.reason)).collect::<Vec<_>>().join(",");

    // 1. default scan: the mounted volume is recorded SeparateVolume exactly once and never descended.
    let t = scan(&root, &ScanOptions::default(), &ScanProgress::default()).expect("default scan");
    let vols = t.skipped.iter().filter(|s| s.path == vol && s.reason == SkipReason::SeparateVolume).count();
    all &= line("separate-volume-recorded", vols == 1 && t.find(&hidden).is_none(), &format!("recorded={} descended={} skipped=[{}]", vols, t.find(&hidden).is_some(), skipped_desc(&t)));

    // 2. permission-denied: recorded PermissionDenied once. A root user bypasses mode 000, so that case is reported NOT-RUN, never PASS.
    let euid = unsafe { libc_geteuid() };
    if euid == 0 {
        println!("REAL-VOLUME case permission-denied NOT-RUN running-as-root");
    } else {
        let pd = t.skipped.iter().filter(|s| s.path == denied && s.reason == SkipReason::PermissionDenied).count();
        all &= line("permission-denied-recorded", pd == 1, &format!("recorded={} skipped=[{}]", pd, skipped_desc(&t)));
    }

    // 3. cross_devices=true descends the real volume and sees the file with its size.
    let t = scan(&root, &ScanOptions { cross_devices: true, ..Default::default() }, &ScanProgress::default()).expect("cross scan");
    let node = t.find(&hidden);
    let sz = node.map(|n| t.size(n)).unwrap_or(0);
    all &= line("cross-devices-descends", node.is_some() && sz >= hidden_bytes && t.skipped_counts()[SkipReason::SeparateVolume as usize] == 0,
        &format!("found={} bytes={} want>={}", node.is_some(), sz, hidden_bytes));

    // 4. detach while scanning: the scan must come back (Ok or Err) within the budget, without a panic or hang.
    let progress = Arc::new(ScanProgress::default());
    let (tx, rx) = mpsc::channel();
    let (r2, p2) = (root.clone(), progress.clone());
    let started = Instant::now();
    std::thread::spawn(move || {
        let res = std::panic::catch_unwind(|| scan(&r2, &ScanOptions { cross_devices: true, ..Default::default() }, &p2));
        let _ = tx.send(match res { Ok(Ok(t)) => Ok(Ok((t.skipped.len(), t.skipped_counts()))), Ok(Err(e)) => Ok(Err(e.to_string())), Err(_) => Err(()) });
    });
    // Wait until the walk has visited something, then detach, whatever the scan is doing.
    while progress.items.load(Ordering::Relaxed) == 0 && started.elapsed() < Duration::from_secs(20) { std::thread::sleep(Duration::from_millis(2)); }
    let items_at_detach = progress.items.load(Ordering::Relaxed);
    let st = Command::new("sh").arg("-c").arg(&detach).status().expect("detach cmd");
    let finished_before_detach = rx.try_recv().ok();
    let outcome = match finished_before_detach { Some(o) => Some(o), None => rx.recv_timeout(Duration::from_secs(90)).ok() };
    let timing = if items_at_detach > 0 { "after-first-items" } else { "before-first-items" };
    match outcome {
        Some(Ok(Ok((n, counts)))) => { all &= line("detach-during-scan-returns", true, &format!("scan=Ok skipped={} counts={:?} detachStatus={} timing={}", n, counts, st.success(), timing)); }
        Some(Ok(Err(e))) => { all &= line("detach-during-scan-returns", true, &format!("scan=Err({}) detachStatus={} timing={}", e, st.success(), timing)); }
        Some(Err(())) => { all &= line("detach-during-scan-returns", false, "scan panicked"); }
        None => { all &= line("detach-during-scan-returns", false, "scan did not return within 90s of the detach"); }
    }
    println!("REAL-VOLUME summary {}", if all { "PASS" } else { "FAIL" });
    assert!(all, "one or more REAL-VOLUME cases failed");
}

extern "C" { #[link_name = "geteuid"] fn libc_geteuid() -> u32; }
