//! Output contract for `spz bench <path> 1`: one run line with items, wall time and peak RSS.
//! RSS values themselves are machine-dependent and only shape-checked here.
mod common;

use std::process::Command;

#[test]
fn bench_prints_wall_time_and_peak_rss() {
    let dir = std::env::temp_dir().join(format!("spz-bench-cli-{}", std::process::id()));
    if dir.exists() {
        std::fs::remove_dir_all(&dir).unwrap();
    }
    common::made(std::fs::create_dir_all(dir.join("sub")));
    common::made(std::fs::write(dir.join("a.txt"), b"alpha"));
    common::made(std::fs::write(dir.join("sub/b.bin"), vec![0u8; 2048]));

    let out = Command::new(env!("CARGO_BIN_EXE_spz"))
        .arg("bench")
        .arg(&dir)
        .arg("1")
        .output()
        .expect("spz bench runs");
    let stdout = String::from_utf8(out.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();

    assert!(out.status.success(), "exit {:?}: {stdout}", out.status);
    assert_eq!(lines.len(), 1, "{stdout}");
    let l = lines[0];
    assert!(l.starts_with("run 1: "), "{l}");
    assert!(l.contains(" items "), "{l}");
    assert!(l.contains("(peak rss ") && l.ends_with(" MB)"), "{l}");
    let rss = l
        .rsplit("(peak rss ")
        .nth(0)
        .and_then(|t| t.strip_suffix(" MB)"))
        .and_then(|t| t.parse::<f64>().ok())
        .unwrap_or_else(|| panic!("no rss number in line: {l}"));
    assert!(rss > 0.0, "peak rss must be positive: {l}");

    std::fs::remove_dir_all(&dir).unwrap();
}
