//! Randomized differential test of the scanner against an independent walk written here with std only. Linux, portable backend only
//! (the macOS bulk backend is not exercised). Compares per-node allocated sizes, kinds and item counts; hard links across directories are compared at the
//! root total only, because which directory a shared inode is attributed to depends on walk order.
use spacelyzer_engine::*;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

struct Rng(u64);
impl Rng { fn next(&mut self) -> u64 { self.0 ^= self.0 << 13; self.0 ^= self.0 >> 7; self.0 ^= self.0 << 17; self.0 } fn below(&mut self, n: u64) -> u64 { self.next() % n } }

/// path -> (allocated bytes below, is_dir). Counts a multiply-linked inode once (first seen); the caller only compares per-node when none exist.
fn oracle(dir: &Path, seen: &mut HashSet<(u64, u64)>, out: &mut BTreeMap<String, (u64, bool)>, items: &mut u64) -> u64 {
    let mut total = 0;
    let mut names: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    names.sort();
    for p in names {
        *items += 1;
        let md = fs::symlink_metadata(&p).unwrap();
        if md.is_dir() {
            let s = oracle(&p, seen, out, items);
            out.insert(p.to_str().unwrap().to_string(), (s, true));
            total += s;
        } else {
            let s = if md.nlink() > 1 && !seen.insert((md.dev(), md.ino())) { 0 } else { md.blocks() * 512 };
            out.insert(p.to_str().unwrap().to_string(), (s, false));
            total += s;
        }
    }
    total
}

fn build(root: &Path, r: &mut Rng, depth: u32, links: bool, files: &mut Vec<PathBuf>) {
    for i in 0..r.below(9) {
        let p = root.join(format!("n{depth}_{i}{}", ["", ".TXT", ".rs", ".tar.gz"][r.below(4) as usize]));
        match r.below(5) {
            0 if depth < 4 => { fs::create_dir_all(&p).unwrap(); build(&p, r, depth + 1, links, files); }
            1 => { fs::write(&p, b"").unwrap(); }
            2 => { let _ = std::os::unix::fs::symlink(["/", "..", "n0_0", "missing"][r.below(4) as usize], &p); }
            3 if links && !files.is_empty() => { let t = files[r.below(files.len() as u64) as usize].clone(); fs::hard_link(t, &p).expect("hard_link must succeed in the fixture"); }
            _ => { fs::write(&p, vec![1u8; (r.below(20_000) + 1) as usize]).unwrap(); files.push(p); }
        }
    }
}

/// Returns (items in the fixture, entries that are extra hard links) for this one fixture.
fn run(seed: u64, links: bool) -> (u64, u64) {
    let root = std::env::temp_dir().join(format!("scanor-{}-{seed}-{links}", std::process::id()));
    let _ = fs::remove_dir_all(&root); fs::create_dir_all(&root).unwrap();
    let root = root.canonicalize().unwrap();
    let mut r = Rng(seed.wrapping_mul(0x9E3779B97F4A7C15) | 1);
    let mut files = vec![];
    build(&root, &mut r, 0, links, &mut files);
    if links {
        // Guarantee every hardlink seed really has a cross-directory hard link: a file plus a link to it in a new subdirectory, created with errors NOT swallowed.
        fs::write(root.join("hl_src"), vec![3u8; 9000]).unwrap(); fs::create_dir_all(root.join("hl_dir")).unwrap();
        fs::hard_link(root.join("hl_src"), root.join("hl_dir").join("hl_dst")).expect("hard_link must succeed in the fixture");
    }
    let (mut out, mut items, mut seen) = (BTreeMap::new(), 0u64, HashSet::new());
    let total = oracle(&root, &mut seen, &mut out, &mut items);
    let mut linked = 0u64;
    if links {
        // Non-vacuity: count entries that really are extra hard links of an inode (nlink > 1) in this fixture.
        let mut n = 0; let mut stack = vec![root.clone()];
        while let Some(d) = stack.pop() { for e in fs::read_dir(&d).unwrap() { let p = e.unwrap().path(); let md = fs::symlink_metadata(&p).unwrap(); if md.is_dir() { stack.push(p) } else if md.nlink() > 1 { n += 1 } } }
        linked = n;
        assert!(n >= 2, "seed {seed}: the fixture must contain a real hard-linked pair, found {n}");
    }
    for (threads, portable) in [(1usize, true), (4, true), (0, false)] {
        let t = scan(&root, &ScanOptions { threads, force_portable: portable, ..Default::default() }, &ScanProgress::default()).unwrap();
        assert_eq!(t.size(0), total, "seed {seed} links {links} threads {threads}: root total");
        assert_eq!(t.items, items, "seed {seed} threads {threads}: items");
        assert!(t.skipped.is_empty(), "seed {seed}: {:?}", t.skipped);
        if !links {
            let mut got = 0;
            for id in 1..t.len() as u32 {
                let (s, d) = out[&t.path(id)];
                assert_eq!(t.size(id), s, "seed {seed} threads {threads}: {}", t.path(id));
                assert_eq!(matches!(t.kind(id), Kind::Directory | Kind::Package), d, "kind of {}", t.path(id));
                got += 1;
            }
            assert_eq!(got, out.len(), "node count");
        }
    }
    let _ = fs::remove_dir_all(&root);
    (items, linked)
}

#[test] fn random_trees_without_hardlinks_match_the_oracle_per_node() {
    let items: u64 = (1..=40).map(|s| run(s, false).0).sum();
    assert!(items > 200, "precondition: the generator produced real trees ({items} items)");
}
#[test] fn random_trees_with_hardlinks_match_the_oracle_total() {
    let (mut items, mut linked) = (0, 0);
    for s in 101..=140 { let (i, l) = run(s, true); items += i; linked += l; }
    assert!(linked >= 80 && items > 200, "precondition: every seed has a hard-linked pair (items {items}, linked entries {linked})");
}
