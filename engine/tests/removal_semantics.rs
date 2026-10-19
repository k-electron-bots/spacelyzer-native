//! Removal ("forget") semantics on a disposable fixture, Linux Rust evidence only. Covers the tree result after a
//! reviewed removal: repeat removal, ancestor and descendant in either order, the root, bad ids, and that removed
//! subtrees leave the largest-files list. It does not exercise Trash, undo or identity revalidation (Swift side).
use spacelyzer_engine::scan::{scan, ScanOptions, ScanProgress};
use spacelyzer_engine::tree::{MutationError, Tree};
use std::path::PathBuf;

struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn build(name: &str) -> (Fixture, Tree) {
    let d = std::env::temp_dir().join(format!("spz-removal-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&d);
    let guard = Fixture(d.clone());
    for (dir, n) in [("a", 4), ("a/inner", 3), ("b", 5), ("c", 0)] {
        std::fs::create_dir_all(d.join(dir)).unwrap();
        for i in 0..n {
            std::fs::write(d.join(dir).join(format!("f{i}.bin")), vec![9u8; 5_000 * (i + 1) + dir.len() * 1_000]).unwrap();
        }
    }
    std::fs::write(d.join("zero.txt"), b"").unwrap();
    let d = d.canonicalize().unwrap();
    let t = scan(&d, &ScanOptions::default(), &ScanProgress::default()).unwrap();
    (guard, t)
}

fn node(t: &Tree, rel: &str) -> u32 {
    t.find(&format!("{}/{}", t.root_path(), rel)).unwrap_or_else(|| panic!("no {rel}"))
}

#[test]
fn removing_twice_changes_nothing_the_second_time() {
    let (_g, t) = build("twice");
    let a = node(&t, "a");
    let v1 = t.forget(a).unwrap();
    let sizes: Vec<u64> = (0..t.len() as u32).map(|i| t.size(i)).collect();
    let v2 = t.forget(a).unwrap();
    assert_eq!(v1, v2, "a repeat removal must not publish a new version");
    assert_eq!(sizes, (0..t.len() as u32).map(|i| t.size(i)).collect::<Vec<_>>());
}

#[test]
fn ancestor_and_descendant_removal_end_in_the_same_state_in_either_order() {
    let (_g1, x) = build("order-x");
    let (_g2, y) = build("order-y");
    let before = x.size(x.root());
    let (ax, dx) = (node(&x, "a"), node(&x, "a/inner"));
    let (ay, dy) = (node(&y, "a"), node(&y, "a/inner"));
    let a_size = x.size(ax);
    x.forget(ax).unwrap();
    x.forget(dx).unwrap(); // descendant of an already removed ancestor
    y.forget(dy).unwrap();
    y.forget(ay).unwrap(); // ancestor after its descendant
    for t in [&x, &y] {
        assert_eq!(t.size(t.root()), before - a_size, "no byte is subtracted twice");
        assert_eq!(t.size(node(t, "a")), 0);
        assert_eq!(t.size(node(t, "a/inner")), 0);
    }
    let all = |t: &Tree| (0..t.len() as u32).map(|i| t.size(i)).collect::<Vec<_>>();
    assert_eq!(all(&x), all(&y));
}

#[test]
fn removing_the_root_zeroes_every_size_and_removed_files_leave_the_largest_list() {
    let (_g, t) = build("root");
    let a = node(&t, "a");
    let before = t.largest_files(50);
    assert!(before.iter().any(|id| t.path(*id).contains("/a/")));
    t.forget(a).unwrap();
    let after = t.largest_files(50);
    assert!(!after.is_empty());
    assert!(after.iter().all(|id| !t.path(*id).contains("/a/")), "removed subtree still listed");
    t.forget(t.root()).unwrap();
    assert!((0..t.len() as u32).all(|i| t.size(i) == 0));
    assert!(t.largest_files(50).is_empty());
}

#[test]
fn bad_ids_are_refused_and_change_nothing() {
    let (_g, t) = build("bad");
    let before: Vec<u64> = (0..t.len() as u32).map(|i| t.size(i)).collect();
    let v = t.table().version;
    assert!(matches!(t.forget(t.len() as u32), Err(MutationError::Invalid)));
    assert!(matches!(t.forget(u32::MAX), Err(MutationError::Invalid)));
    assert_eq!(t.table().version, v);
    assert_eq!(before, (0..t.len() as u32).map(|i| t.size(i)).collect::<Vec<_>>());
}

#[test]
fn removing_an_empty_directory_and_a_zero_byte_file_leaves_other_sizes_alone() {
    let (_g, t) = build("zero");
    let total = t.size(t.root());
    let (c, z) = (node(&t, "c"), node(&t, "zero.txt"));
    t.forget(c).unwrap();
    t.forget(z).unwrap();
    assert_eq!(t.size(t.root()), total);
    assert!(t.table().forgotten.contains(&c) && t.table().forgotten.contains(&z), "marked removed even though their size was zero");
}
