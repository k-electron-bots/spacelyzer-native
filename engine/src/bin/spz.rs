//! `spz scan <path>`   scan and print totals, timing, top-level breakdown
//! `spz verify <path>` scan with both backends, compare totals, print per-backend wall times (run this on a Mac)
//! `spz bench <path> [runs]`  repeated scans, wall times
use spacelyzer_engine::*;
use spacelyzer_engine::{category::Category, filter};
use std::path::PathBuf;
use std::time::Instant;

fn human(b: u64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1000.0 && i < 4 {
        v /= 1000.0;
        i += 1;
    }
    format!("{:.2} {}", v, u[i])
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (cmd, path) = match (a.get(1), a.get(2)) {
        (Some(c), Some(p)) => (c.as_str(), PathBuf::from(p)),
        _ => {
            eprintln!("usage: spz <scan|verify|bench> <path> [runs]");
            std::process::exit(2);
        }
    };
    match cmd {
        "scan" => {
            let p = ScanProgress::default();
            let t0 = Instant::now();
            let tree = scan(&path, &ScanOptions::default(), &p).expect("scan failed");
            let dt = t0.elapsed();
            println!("{} items, {} in {:.3}s ({} skipped)", tree.items, human(tree.size(0)), dt.as_secs_f64(), tree.skipped.len());
            for c in tree.children(0).take(10) {
                println!("  {:>10}  {}", human(tree.size(c)), tree.name(c));
            }
            let t1 = Instant::now();
            let rects = layout(&tree, 0, &LayoutOptions { width: 1600.0, height: 1000.0, ..Default::default() });
            println!("layout: {} rects in {:.3}ms", rects.len(), t1.elapsed().as_secs_f64() * 1000.0);
        }
        "verify" => {
            // Correctness compare uses the first pair (unchanged semantics). Each backend is then
            // scanned a second time so the printed times include a warm-cache run for both; the
            // ratio uses the warm runs because the first default scan is systematically colder.
            let t_fast = Instant::now();
            let fast = scan(&path, &ScanOptions::default(), &ScanProgress::default()).expect("scan failed");
            let dt_fast_cold = t_fast.elapsed();
            let t_slow = Instant::now();
            let slow = scan(&path, &ScanOptions { force_portable: true, ..Default::default() }, &ScanProgress::default()).expect("scan failed");
            let dt_slow_cold = t_slow.elapsed();
            let agree = fast.items == slow.items && fast.size(0) == slow.size(0);
            let t_fast2 = Instant::now();
            scan(&path, &ScanOptions::default(), &ScanProgress::default()).expect("scan failed");
            let dt_fast_warm = t_fast2.elapsed();
            let t_slow2 = Instant::now();
            scan(&path, &ScanOptions { force_portable: true, ..Default::default() }, &ScanProgress::default()).expect("scan failed");
            let dt_slow_warm = t_slow2.elapsed();
            println!("default : {} items {} bytes in {:.3}s (warm: {:.3}s)", fast.items, fast.size(0), dt_fast_cold.as_secs_f64(), dt_fast_warm.as_secs_f64());
            println!("portable: {} items {} bytes in {:.3}s (warm: {:.3}s)", slow.items, slow.size(0), dt_slow_cold.as_secs_f64(), dt_slow_warm.as_secs_f64());
            if agree {
                println!("OK backends agree");
                if dt_fast_warm.as_secs_f64() > 0.0 {
                    println!("portable/default warm-time ratio: {:.2}x", dt_slow_warm.as_secs_f64() / dt_fast_warm.as_secs_f64());
                }
            } else {
                println!("MISMATCH (live volume may have changed; rerun on a quiet folder)");
                std::process::exit(1);
            }
        }
        "bench" => {
            let runs: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(5);
            for i in 0..runs {
                let t0 = Instant::now();
                let tree = scan(&path, &ScanOptions::default(), &ScanProgress::default()).unwrap();
                println!("run {}: {} items {:.3}s", i + 1, tree.items, t0.elapsed().as_secs_f64());
            }
        }
        "filterbench" => {
            let tree = if path.to_string_lossy() == "synthetic" {
                let n: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(1_000_000);
                Tree::synthetic(n)
            } else {
                scan(&path, &ScanOptions::default(), &ScanProgress::default()).unwrap()
            };
            println!("{} nodes", tree.len());
            let cases: Vec<(&str, Filter)> = vec![
                ("text 'lib'", Filter { text: "lib".into(), ..Default::default() }),
                ("kind code", Filter { category_mask: filter::mask(&[Category::Code]), ..Default::default() }),
                ("ext .so", Filter { extension: "so".into(), ..Default::default() }),
                ("size >= 1MB", Filter { min_size: Some(1_000_000), ..Default::default() }),
                ("combined", Filter { text: "a".into(), category_mask: filter::mask(&[Category::Code, Category::Data]), min_size: Some(4096), ..Default::default() }),
            ];
            for (label, f) in cases {
                let t0 = Instant::now();
                let r = apply_filter(&tree, &f);
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                let t1 = Instant::now();
                let rects = layout_with(&tree, 0, &LayoutOptions { width: 1600.0, height: 1000.0, ..Default::default() }, Some(&r.sizes));
                println!("{label:<12} {:>8} files {:>10} filter {ms:.1} ms, relayout {} rects {:.1} ms", r.total_count, human(r.total_bytes), rects.len(), t1.elapsed().as_secs_f64() * 1000.0);
            }
        }
        _ => std::process::exit(2),
    }
}
