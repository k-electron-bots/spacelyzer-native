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

/// Inspect `path` without following a final symlink. `Err` carries the OS error code (ENOENT = 2 when it is gone).
pub fn inspect(path: &Path) -> Result<Inspect, i32> {
    let m = std::fs::symlink_metadata(path).map_err(|e| e.raw_os_error().unwrap_or(-1))?;
    let ft = m.file_type();
    let kind = if ft.is_symlink() { InspectKind::Symlink } else if ft.is_dir() { InspectKind::Dir } else if ft.is_file() { InspectKind::File } else { InspectKind::Other };
    Ok(Inspect { allocated: m.blocks() * 512, logical: m.len(), mtime: m.mtime(), dev: m.dev(), ino: m.ino(), nlink: m.nlink() as u32, kind: kind as u8, _pad: [0; 3] })
}

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
        let p = tmp("gone"); assert_eq!(inspect(&p), Err(2));
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
