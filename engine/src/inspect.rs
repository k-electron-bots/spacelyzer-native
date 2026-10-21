//! Live item inspection for the review-before-Trash flow. This reads the filesystem NOW (lstat, never following a
//! symlink), so the answer describes what is on disk at this moment and can differ from the scanned tree. Callers
//! compare `dev`/`ino`/`kind` against the scanned identity before acting on an item.
//!
//! LIMITS (do not read this as a safety guarantee): only the FINAL path component is not followed. Every ancestor directory
//! is resolved by the OS at call time, so a symlinked or swapped ancestor makes the answer describe a different file than
//! the scanned one (see `ancestor_symlink_is_followed`). The result is also a point-in-time reading: the path can change
//! between this call and any later Trash call (TOCTOU). A pre-check narrows that window but does not close it.
use std::os::unix::fs::MetadataExt;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum InspectKind { File = 0, Dir = 1, Symlink = 2, Other = 3 }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Inspect {
    /// Allocated bytes (st_blocks * 512), the same measure the scanner uses. For a directory this is the directory entry itself, not its contents.
    pub allocated: u64,
    /// Logical length in bytes (st_size).
    pub logical: u64,
    pub mtime: i64,
    pub dev: u64,
    pub ino: u64,
    pub nlink: u32,
    pub kind: u8,
    pub _pad: [u8; 3],
}

/// Inspect `path` without following a final symlink. `Err(Some(errno))` is the OS error (ENOENT = 2 when it is gone);
/// `Err(None)` is a failure that carries no errno.
pub fn inspect(path: &Path) -> Result<Inspect, Option<i32>> {
    let m = std::fs::symlink_metadata(path).map_err(|e| e.raw_os_error())?;
    let ft = m.file_type();
    let kind = if ft.is_symlink() { InspectKind::Symlink } else if ft.is_dir() { InspectKind::Dir } else if ft.is_file() { InspectKind::File } else { InspectKind::Other };
    Ok(Inspect { allocated: m.blocks() * 512, logical: m.len(), mtime: m.mtime(), dev: m.dev(), ino: m.ino(), nlink: m.nlink() as u32, kind: kind as u8, _pad: [0; 3] })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum IdentityCheck {
    /// Live (dev, ino) and kind class equal the scanned ones.
    Same = 0,
    /// Live item exists but its (dev, ino) or kind class differs from the scanned one: replaced. Refuse.
    Different = 1,
    /// The tree holds no scanned identity for this node (synthetic tree, or more than 255 devices). Refuse: nothing to compare.
    NoScannedIdentity = 2,
    /// The scanned name had non-UTF-8 bytes that the scanner replaced with U+FFFD, so the stored path cannot address the real item. Refuse.
    Unaddressable = 3,
    /// A directory between the scan root and the item is now a symlink. Refuse.
    AncestorSymlink = 4,
    /// The path no longer exists (ENOENT).
    Gone = 5,
}

/// Device ids compare on the low 32 bits on macOS, where the bulk scanner reads a 32-bit dev_t and lstat sign-extends one.
/// That widening agreement is argued from the code, NOT measured on a Mac.
fn dev_eq(a: u64, b: u64) -> bool { if cfg!(target_os = "macos") { a as u32 == b as u32 } else { a == b } }

/// Compare the live item behind `id` to the identity the scan recorded. Compares only (dev, ino) and a kind class: never
/// size or mtime (hard-link dedup makes scanned bytes differ from live allocation, and size/mtime narrowing is not identity).
/// Not atomic: the path can change right after this returns. Ancestors BELOW the scan root are checked for symlinks; the scan root
/// itself and its own ancestors are taken as given.
/// `live_state` values. Live metadata is carried ONLY when the leaf was observed: for Same it describes the scanned item, for Different
/// it describes the DIFFERENT item now at the path and must be labelled that way. For every other verdict there is no live metadata.
pub const LIVE_NONE: u8 = 0;
pub const LIVE_SAME_ITEM: u8 = 1;
pub const LIVE_DIFFERENT_ITEM: u8 = 2;

pub struct Review { pub check: IdentityCheck, pub live: Option<Inspect>, pub live_state: u8 }
impl Review { fn bare(check: IdentityCheck) -> Review { Review { check, live: None, live_state: LIVE_NONE } } }

/// C layout written by `spz_tree_review`: the live metadata (zeroed when `live_state` is 0) plus its state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct SpzReview { pub live: Inspect, pub live_state: u8, pub _pad: [u8; 7] }

/// Compare the live item behind `id` to the identity the scan recorded and return the verdict together with the metadata of the SAME lstat.
pub fn review_scanned(tree: &crate::tree::Tree, id: crate::tree::NodeId) -> Result<Review, Option<i32>> {
    use crate::tree::Kind;
    if id as usize >= tree.len() { return Err(None); }
    let Some((dev, ino)) = tree.scanned_identity(id) else { return Ok(Review::bare(IdentityCheck::NoScannedIdentity)) };
    let path = tree.path(id);
    if path.contains('\u{FFFD}') { return Ok(Review::bare(IdentityCheck::Unaddressable)); }
    let root = tree.root_path.trim_end_matches('/');
    if let Some(rel) = path.strip_prefix(root).filter(|_| id != 0) {
        let mut cur = std::path::PathBuf::from(if root.is_empty() { "/" } else { root });
        let comps: Vec<&str> = rel.split('/').filter(|c| !c.is_empty()).collect();
        for c in &comps[..comps.len().saturating_sub(1)] {
            cur.push(c);
            match inspect(&cur) {
                Ok(i) if i.kind == InspectKind::Symlink as u8 => return Ok(Review::bare(IdentityCheck::AncestorSymlink)),
                Ok(_) => {}
                Err(Some(2)) => return Ok(Review::bare(IdentityCheck::Gone)),
                Err(e) => return Err(e),
            }
        }
    }
    let live = match inspect(Path::new(&path)) { Ok(i) => i, Err(Some(2)) => return Ok(Review::bare(IdentityCheck::Gone)), Err(e) => return Err(e) };
    let kind_ok = match tree.kind(id) {
        Kind::File => live.kind == InspectKind::File as u8 || live.kind == InspectKind::Other as u8,
        Kind::Directory | Kind::Package => live.kind == InspectKind::Dir as u8,
        Kind::Symlink => live.kind == InspectKind::Symlink as u8,
    };
    // The verdict and the live metadata come from the SAME lstat observation, so a different file's metadata can never be labelled Same.
    let same = kind_ok && dev_eq(dev, live.dev) && ino == live.ino;
    Ok(Review { check: if same { IdentityCheck::Same } else { IdentityCheck::Different }, live: Some(live), live_state: if same { LIVE_SAME_ITEM } else { LIVE_DIFFERENT_ITEM } })
}

/// Existing wrapper: the verdict only.
pub fn check_scanned(tree: &crate::tree::Tree, id: crate::tree::NodeId) -> Result<IdentityCheck, Option<i32>> { review_scanned(tree, id).map(|r| r.check) }

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    fn tmp(name: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("spz-inspect-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p); let _ = std::fs::remove_file(&p); p
    }
    #[test]
    fn file_reports_logical_and_allocated_sizes() {
        let p = tmp("file"); let mut f = std::fs::File::create(&p).unwrap(); f.write_all(&[7u8; 5000]).unwrap(); f.sync_all().unwrap();
        let i = inspect(&p).unwrap();
        assert_eq!(i.kind, InspectKind::File as u8); assert_eq!(i.logical, 5000); assert!(i.allocated >= 5000 && i.allocated % 512 == 0); assert_eq!(i.nlink, 1);
        std::fs::remove_file(&p).unwrap();
    }
    #[test]
    fn symlink_is_not_followed_and_dir_is_dir() {
        let d = tmp("dir"); std::fs::create_dir(&d).unwrap(); let t = d.join("t"); std::fs::write(&t, b"x").unwrap();
        let l = d.join("l"); std::os::unix::fs::symlink(&t, &l).unwrap();
        assert_eq!(inspect(&l).unwrap().kind, InspectKind::Symlink as u8);
        assert_eq!(inspect(&d).unwrap().kind, InspectKind::Dir as u8);
        assert_ne!(inspect(&l).unwrap().ino, inspect(&t).unwrap().ino);
        std::fs::remove_dir_all(&d).unwrap();
    }
    #[test]
    fn hard_links_share_identity_and_report_nlink() {
        let d = tmp("hl"); std::fs::create_dir(&d).unwrap(); let a = d.join("a"); std::fs::write(&a, b"hello").unwrap(); let b = d.join("b"); std::fs::hard_link(&a, &b).unwrap();
        let (x, y) = (inspect(&a).unwrap(), inspect(&b).unwrap());
        assert_eq!((x.dev, x.ino), (y.dev, y.ino)); assert_eq!(x.nlink, 2);
        std::fs::remove_dir_all(&d).unwrap();
    }
    #[test]
    fn ancestor_symlink_is_followed() {
        // Documents a limit: lstat does not protect against a symlinked ancestor. The inspected file is the other directory's file.
        let d = tmp("anc"); std::fs::create_dir_all(d.join("real")).unwrap(); std::fs::write(d.join("real/f"), b"abc").unwrap();
        std::os::unix::fs::symlink(d.join("real"), d.join("link")).unwrap();
        let (via, direct) = (inspect(&d.join("link/f")).unwrap(), inspect(&d.join("real/f")).unwrap());
        assert_eq!((via.dev, via.ino, via.kind), (direct.dev, direct.ino, InspectKind::File as u8));
        std::fs::remove_dir_all(&d).unwrap();
    }
    #[test]
    fn missing_path_reports_enoent_and_replacement_changes_identity() {
        let p = tmp("gone"); assert_eq!(inspect(&p), Err(Some(2)));
        std::fs::write(&p, b"1").unwrap(); let first = inspect(&p).unwrap();
        std::fs::remove_file(&p).unwrap(); std::fs::create_dir(&p).unwrap();
        let second = inspect(&p).unwrap(); assert_ne!(first.kind, second.kind);
        std::fs::remove_dir(&p).unwrap();
    }
}

#[cfg(test)]
mod layout_test {
    use super::*;
    use std::mem::{offset_of, size_of};
    /// Must equal the C struct SpzInspect in Sources/CSpacelyzer/include/spacelyzer.h: 48 bytes, offsets mtime 16, dev 24, ino 32, nlink 40, kind 44.
    #[test]
    fn layout_matches_header() {
        assert_eq!((size_of::<Inspect>(), offset_of!(Inspect, mtime), offset_of!(Inspect, dev), offset_of!(Inspect, ino), offset_of!(Inspect, nlink), offset_of!(Inspect, kind)), (48, 16, 24, 32, 40, 44));
    }
}
