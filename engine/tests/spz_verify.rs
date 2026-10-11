//! Output contract for the `spz verify` CLI on an agree path: both backend lines carry
//! totals and cold+warm wall times, the agree line prints, and the warm-time-ratio line follows.
//! The mismatch path is not constructed here: it needs a tree that changes mid-scan,
//! which a fixture cannot do deterministically.
mod common;

use std::process::Command;

fn line_items(line: &str) -> u64 {
    let toks: Vec<&str> = line.split_whitespace().collect();
    let i = toks.iter().position(|t| *t == "items").unwrap_or_else(|| panic!("no items word in line: {line}"));
    toks[i - 1].parse().unwrap_or_else(|_| panic!("no item count in line: {line}"))
}

#[test]
fn agree_path_prints_totals_times_and_ratio() {
    let dir = std::env::temp_dir().join(format!("spz-verify-cli-{}", std::process::id()));
    if dir.exists() {
        std::fs::remove_dir_all(&dir).unwrap();
    }
    common::made(std::fs::create_dir_all(dir.join("sub/deep")));
    common::made(std::fs::write(dir.join("a.txt"), b"alpha"));
    common::made(std::fs::write(dir.join("sub/b.bin"), vec![0u8; 4096]));
    common::made(std::fs::write(dir.join("sub/deep/c.md"), b"gamma\n"));

    let out = Command::new(env!("CARGO_BIN_EXE_spz"))
        .arg("verify")
        .arg(&dir)
        .output()
        .expect("spz verify runs");
    let stdout = String::from_utf8(out.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();

    assert!(out.status.success(), "exit {:?}: {stdout}", out.status);
    assert!(lines.len() == 4, "expected 4 lines, got {}: {stdout}", lines.len());
    assert!(lines[0].starts_with("default : "), "{}", lines[0]);
    assert!(lines[1].starts_with("portable: "), "{}", lines[1]);
    for l in &lines[0..2] {
        assert!(l.contains(" items ") && l.contains(" bytes in ") && l.contains("(warm: ") && l.ends_with("s)"), "totals+time shape: {l}");
    }
    assert_eq!(line_items(lines[0]), line_items(lines[1]), "backend totals disagree on a quiet fixture: {stdout}");
    assert_eq!(lines[2], "OK backends agree");
    assert!(lines[3].starts_with("portable/default warm-time ratio: ") && lines[3].ends_with('x'), "{}", lines[3]);

    std::fs::remove_dir_all(&dir).unwrap();
}
