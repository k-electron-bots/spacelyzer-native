//! Engine-only unit coverage for the filter application engine (filter::apply,
//! filter::largest_files, filter::category_totals, filter::mask) and its
//! contract with the outline projection. Existing filter tests pin only the
//! contains_ci substring parity; the rollup, bounds, masks, and the
//! zero-byte-match visibility rule had no direct tests. Fixtures are real
//! tempdir scans (no FFI, deterministic contents, engine-only).

use spacelyzer_engine::filter::{self, Filter};
use spacelyzer_engine::outline;
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::{Kind, Tree};
use spacelyzer_engine::Category;
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

/// Build a tempdir fixture: (relative path, content byte length) pairs. Directories
/// are created implicitly. Contents are REALLY WRITTEN (not sparse): the engine
/// measures allocated bytes (st_blocks * 512), so a sparse file would measure 0.
/// Byte expectations below are always derived from the scanned tree's own
/// own_bytes values, never hardcoded, because allocation rounds up to the
/// filesystem block size. Zero-length files allocate 0 and stay own_bytes == 0.
fn fixture(name: &str, files: &[(&str, u64)]) -> PathBuf {
    let root = std::env::temp_dir().join(format!("spz-filter-apply-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    for (rel, len) in files {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, vec![1u8; *len as usize]).unwrap();
    }
    root
}

fn scan_fixture(root: &std::path::Path) -> Tree {
    scan(root, &ScanOptions::default(), &ScanProgress::default()).expect("fixture scans cleanly")
}

fn id(t: &Tree, rel: &str) -> u32 {
    t.find(&format!("{}/{rel}", t.root_path())).unwrap_or_else(|| panic!("missing fixture node {rel}"))
}

fn files_under(t: &Tree) -> Vec<u32> {
    (0..t.len() as u32).filter(|&i| t.kind(i) != Kind::Directory).collect()
}

#[test]
fn empty_filter_is_identity_and_matches_unfiltered_views() {
    let root = fixture("identity", &[("a/one.txt", 100), ("a/two.txt", 200), ("b/three.txt", 300), ("top.bin", 50)]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter::default());
    assert_eq!(r.total_bytes, t.size(t.root()), "empty filter keeps every byte");
    // tree.items counts every node except the root (directories included); the
    // filter counts matching FILES only - directories contribute through descendants.
    assert_eq!(r.total_count, files_under(&t).len() as u64, "empty filter keeps every file");
    for i in files_under(&t) {
        assert_eq!(r.counts[i as usize], 1, "every file matches an empty filter");
        assert_eq!(r.sizes[i as usize], t.own_bytes(i));
    }
    // Every directory's rolled values equal the plain subtree sums.
    for i in 0..t.len() as u32 {
        if t.kind(i) == Kind::Directory {
            let want_bytes: u64 = files_under(&t).iter().filter(|&&f| is_descendant(&t, f, i)).map(|&f| t.own_bytes(f)).sum();
            let want_count = files_under(&t).iter().filter(|&&f| is_descendant(&t, f, i)).count() as u32;
            assert_eq!(r.sizes[i as usize], want_bytes, "dir {i} rolled bytes");
            assert_eq!(r.counts[i as usize], want_count, "dir {i} rolled count");
        }
    }
    // Filtered views coincide with the unfiltered ones.
    assert_eq!(filter::largest_files(&t, &r, 3), t.largest_files(3));
    assert_eq!(filter::category_totals(&t, &r), t.category_totals());
    let _ = fs::remove_dir_all(&root);
}

fn is_descendant(t: &Tree, node: u32, ancestor: u32) -> bool {
    let mut cur = t.parent(node);
    while let Some(p) = cur {
        if p == ancestor { return true; }
        cur = t.parent(p);
    }
    false
}

#[test]
fn text_filter_is_case_insensitive_and_dirs_match_only_through_descendants() {
    let root = fixture("text", &[
        ("docs/report-final.pdf", 100),
        ("docs/REPORT-old.txt", 250),
        ("docs/notes.txt", 40),
        ("report-dir/unrelated.bin", 90), // the DIRECTORY name matches the query; only files match
    ]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { text: "RePoRt".into(), ..Default::default() });
    assert_eq!(r.counts[id(&t, "docs/report-final.pdf") as usize], 1);
    assert_eq!(r.counts[id(&t, "docs/REPORT-old.txt") as usize], 1, "case-insensitive on both sides");
    assert_eq!(r.counts[id(&t, "docs/notes.txt") as usize], 0);
    assert_eq!(r.counts[id(&t, "report-dir/unrelated.bin") as usize], 0, "directory names are not matched");
    assert_eq!(r.counts[id(&t, "report-dir") as usize], 0, "a dir whose files do not match stays empty");
    assert_eq!(r.total_bytes, t.own_bytes(id(&t, "docs/report-final.pdf")) + t.own_bytes(id(&t, "docs/REPORT-old.txt")));
    assert_eq!(r.total_count, 2);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn extension_filter_trims_dot_is_case_insensitive_and_ignores_dotfiles() {
    let root = fixture("ext", &[
        ("a.PNG", 10),
        ("b.png", 20),
        ("c.png.bak", 30),
        ("noext", 40),
        (".png", 50), // dot at index 0: no extension by the classify rule
        ("e.tar.gz", 60),
    ]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { extension: ".PNG".into(), ..Default::default() });
    assert_eq!(r.counts[id(&t, "a.PNG") as usize], 1);
    assert_eq!(r.counts[id(&t, "b.png") as usize], 1);
    assert_eq!(r.counts[id(&t, "c.png.bak") as usize], 0, "last extension wins");
    assert_eq!(r.counts[id(&t, "noext") as usize], 0);
    assert_eq!(r.counts[id(&t, ".png") as usize], 0, "a leading dot is not an extension separator");
    assert_eq!(r.total_bytes, t.own_bytes(id(&t, "a.PNG")) + t.own_bytes(id(&t, "b.png")));
    assert_eq!(r.total_count, 2);
    let r2 = filter::apply(&t, &Filter { extension: "gz".into(), ..Default::default() });
    assert_eq!(r2.counts[id(&t, "e.tar.gz") as usize], 1);
    assert_eq!(r2.total_count, 1);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn size_and_mtime_bounds_are_inclusive() {
    let root = fixture("bounds", &[("s100.bin", 4096), ("s200.bin", 8192), ("s300.bin", 16384)]);
    let t = scan_fixture(&root);
    let (f100, f200, f300) = (id(&t, "s100.bin"), id(&t, "s200.bin"), id(&t, "s300.bin"));
    // Bounds apply to ALLOCATED bytes; derive the three fixture sizes from the tree.
    let (a, b, c) = (t.own_bytes(f100), t.own_bytes(f200), t.own_bytes(f300));
    assert!(a < b && b < c, "fixture sizes are distinct and ordered: {a} {b} {c}");
    let r = filter::apply(&t, &Filter { min_size: Some(a), max_size: Some(c), ..Default::default() });
    assert_eq!((r.counts[f100 as usize], r.counts[f200 as usize], r.counts[f300 as usize]), (1, 1, 1), "bounds include both ends");
    let r = filter::apply(&t, &Filter { min_size: Some(a + 1), max_size: Some(c - 1), ..Default::default() });
    assert_eq!((r.counts[f100 as usize], r.counts[f200 as usize], r.counts[f300 as usize]), (0, 1, 0), "just inside the bounds keeps only the middle");
    let r = filter::apply(&t, &Filter { min_size: Some(b + 1), max_size: Some(c - 1), ..Default::default() });
    assert_eq!(r.total_count, 0, "a window between fixtures matches nothing");
    let m = t.mtime(f200);
    let r = filter::apply(&t, &Filter { modified_from: Some(m), modified_to: Some(m), ..Default::default() });
    assert_eq!(r.counts[f200 as usize], 1, "mtime bounds include the exact instant");
    let r = filter::apply(&t, &Filter { modified_from: Some(m + 1), ..Default::default() });
    assert_eq!(r.counts[f200 as usize], 0);
    let r = filter::apply(&t, &Filter { modified_to: Some(m - 1), ..Default::default() });
    assert_eq!(r.counts[f200 as usize], 0);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn category_mask_selects_masked_categories_only() {
    let root = fixture("mask", &[("pic.png", 10), ("code.rs", 20), ("song.mp3", 30), ("doc.pdf", 40)]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { category_mask: filter::mask(&[Category::Image, Category::Code]), ..Default::default() });
    // Independent predicate: membership by the tree's own category assignment.
    let want: Vec<u32> = files_under(&t).into_iter().filter(|&i| matches!(t.category(i), Category::Image | Category::Code)).collect();
    let got: Vec<u32> = files_under(&t).into_iter().filter(|&i| r.counts[i as usize] == 1).collect();
    assert_eq!(got, want);
    assert_eq!(r.total_count, 2);
    assert_eq!(r.total_bytes, t.own_bytes(id(&t, "pic.png")) + t.own_bytes(id(&t, "code.rs")));
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn zero_byte_match_stays_visible_and_rolls_count_without_bytes() {
    let root = fixture("zerobyte", &[
        ("sub1/empty.txt", 0),
        ("sub1/full.txt", 100),
        ("sub2/other.log", 70),
    ]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { text: "empty".into(), ..Default::default() });
    let (sub1, sub2, empty, full) = (id(&t, "sub1"), id(&t, "sub2"), id(&t, "sub1/empty.txt"), id(&t, "sub1/full.txt"));
    assert_eq!((r.counts[empty as usize], r.sizes[empty as usize]), (1, 0), "a zero-byte match counts one item, zero bytes");
    assert_eq!((r.counts[sub1 as usize], r.sizes[sub1 as usize]), (1, 0), "count rolls up, bytes stay zero");
    assert_eq!(r.counts[sub2 as usize], 0);
    assert_eq!((r.total_count, r.total_bytes), (1, 0));
    // The documented outline contract: hidden by match COUNT, so zero-byte matches stay visible.
    let mut expanded: HashSet<u32> = [t.root(), sub1].into_iter().collect();
    let rows = outline::visible_rows(&t, t.root(), &expanded, Some(&r));
    let nodes: Vec<u32> = rows.iter().map(|row| row.node).collect();
    assert!(nodes.contains(&sub1), "dir with a zero-byte match stays visible");
    assert!(nodes.contains(&empty), "the zero-byte match itself stays visible");
    assert!(!nodes.contains(&sub2), "dirs with no matching files are hidden");
    assert!(!nodes.contains(&full), "non-matching sibling files are hidden");
    expanded.insert(sub2);
    let rows = outline::visible_rows(&t, t.root(), &expanded, Some(&r));
    assert!(!rows.iter().any(|row| row.node == sub2), "expanding does not resurrect a zero-match dir");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn filter_hides_zero_match_subtrees_from_the_outline() {
    let root = fixture("outline", &[
        ("has/deep/keep.png", 10),
        ("has/skip.txt", 20),
        ("none/only.txt", 30),
    ]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { extension: "png".into(), ..Default::default() });
    let (has, deep, none) = (id(&t, "has"), id(&t, "has/deep"), id(&t, "none"));
    let expanded: HashSet<u32> = [t.root(), has, deep, none].into_iter().collect();
    let rows = outline::visible_rows(&t, t.root(), &expanded, Some(&r));
    let nodes: Vec<u32> = rows.iter().map(|row| row.node).collect();
    assert_eq!(nodes, vec![has, deep, id(&t, "has/deep/keep.png")], "only the matching chain remains, in display order");
    let depths: Vec<u32> = rows.iter().map(|row| row.depth).collect();
    assert_eq!(depths, vec![0, 1, 2]);
    // Same contract through the sorted variant.
    let rows = outline::visible_rows_sorted(&t, t.root(), &expanded, Some(&r), outline::SortMode::NameAsc);
    assert_eq!(rows.len(), 3);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn filtered_largest_files_orders_caps_and_excludes_non_matches() {
    // Sizes are distinct multiples of the 4096 block so allocated bytes stay distinct
    // (a 2048-byte write and a 4096-byte write both allocate one 4096 block).
    let root = fixture("largest", &[("big.png", 12288), ("mid.png", 8192), ("small.png", 4096), ("huge.txt", 32768)]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { extension: "png".into(), ..Default::default() });
    // Fixture intent: distinct allocated sizes, big > mid > small.
    let (sb, sm, ss) = (t.own_bytes(id(&t, "big.png")), t.own_bytes(id(&t, "mid.png")), t.own_bytes(id(&t, "small.png")));
    assert!(sb > sm && sm > ss, "allocated sizes are distinct and ordered: {sb} {sm} {ss}");
    let got = filter::largest_files(&t, &r, 2);
    assert_eq!(got, vec![id(&t, "big.png"), id(&t, "mid.png")], "largest first among matches only");
    assert_eq!(filter::largest_files(&t, &r, 50).len(), 3, "cap above the match count returns every match");
    assert!(filter::largest_files(&t, &r, 0).is_empty());
    let none = filter::apply(&t, &Filter { extension: "xyz".into(), ..Default::default() });
    assert!(filter::largest_files(&t, &none, 5).is_empty(), "no matches, no rows");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn filtered_category_totals_parity_with_independent_recompute() {
    let root = fixture("cattotals", &[("pic.png", 10), ("photo.jpg", 15), ("code.rs", 20), ("song.mp3", 30), ("doc.pdf", 40)]);
    let t = scan_fixture(&root);
    let r = filter::apply(&t, &Filter { category_mask: filter::mask(&[Category::Image, Category::Code, Category::Audio]), ..Default::default() });
    let got = filter::category_totals(&t, &r);
    let mut want = [(0u64, u64::MAX); spacelyzer_engine::category::CATEGORY_COUNT];
    let mut want = [(0u64, 0u64); spacelyzer_engine::category::CATEGORY_COUNT];
    for i in files_under(&t) {
        if r.counts[i as usize] == 1 {
            let c = t.category(i) as usize;
            want[c].0 += r.sizes[i as usize];
            want[c].1 += 1;
        }
    }
    assert_eq!(got, want);
    assert_eq!(got[Category::Image as usize], (t.own_bytes(id(&t, "pic.png")) + t.own_bytes(id(&t, "photo.jpg")), 2));
    assert_eq!(got[Category::Code as usize], (t.own_bytes(id(&t, "code.rs")), 1));
    assert_eq!(got[Category::Audio as usize], (t.own_bytes(id(&t, "song.mp3")), 1));
    assert_eq!(got[Category::Document as usize], (0, 0), "excluded by the mask");
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn mask_helper_sets_one_bit_per_category() {
    assert_eq!(filter::mask(&[]), 0);
    assert_eq!(filter::mask(&[Category::Folder]), 1 << (Category::Folder as u8));
    assert_eq!(filter::mask(&[Category::Image, Category::Other]), (1 << (Category::Image as u8)) | (1 << (Category::Other as u8)));
    // Duplicate categories collapse to one bit.
    assert_eq!(filter::mask(&[Category::Code, Category::Code]), 1 << (Category::Code as u8));
}
