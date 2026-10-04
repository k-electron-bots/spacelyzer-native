//! Read-only duplicate finder over a scanned tree. Reports groups of regular files with identical content; it never changes, moves
//! or deletes anything and offers no safety verdict about removing a member.
//!
//! Method (each stage only narrows, the last stage proves equality):
//! 1. Candidates: live regular files (not symlinks, packages or directories) whose scanned size is at least `min_size` (and > 0).
//!    Grouping is by the scanned ALLOCATED size, so equal content stored with different allocation (sparse, compressed, cloned) can be
//!    missed. That is a recall limit, never a false duplicate.
//! 2. Hard links to the same (dev, inode) share storage and are counted once (`hardlink_aliases`), so they are never reported as duplicates.
//! 3. Each candidate is opened with O_NOFOLLOW; it must still be a regular file, have the scanned identity (when one was recorded) and the
//!    same logical length as its group; otherwise it is counted in `changed` and left out.
//! 4. Prefix hash, then full-content hash (std SipHash, not cryptographic), then a byte-for-byte comparison against each class
//!    representative. Two files are in one group only after a byte-for-byte match, so hash collisions cannot create a false group.
//! A file that changes while being read can only drop out or land in a group by the bytes this pass read; the result is a point-in-time
//! observation, not a guarantee about the file's current content.
use crate::tree::{Kind, NodeId, Tree};
use rayon::prelude::*;
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::hash::Hasher;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DupGroup {
    /// Scanned (allocated) size of one member.
    pub size: u64,
    /// Members, ascending NodeId, at least 2.
    pub ids: Vec<NodeId>,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DupReport {
    /// Largest `wasted` first, ties by first member id.
    pub groups: Vec<DupGroup>,
    /// Sum over groups of size * (members - 1): space held by the extra copies (allocated size, an estimate of what removing all but one frees).
    pub wasted: u64,
    pub unreadable: u32,
    pub changed: u32,
    pub hardlink_aliases: u32,
    pub cancelled: bool,
    /// Table version the candidate set was captured at.
    pub version: u64,
}

const PREFIX: usize = 4096;
const CHUNK: usize = 64 * 1024;

struct Opened { f: File, len: u64 }

fn open_checked(tree: &Tree, id: NodeId) -> Result<Opened, bool> {
    // Err(true) = unreadable, Err(false) = changed.
    let path = tree.path(id);
    let f = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&path).map_err(|_| true)?;
    let m = f.metadata().map_err(|_| true)?;
    if !m.file_type().is_file() { return Err(false); }
    if let Some((dev, ino)) = tree.scanned_identity(id) { if m.dev() != dev || m.ino() != ino { return Err(false); } }
    Ok(Opened { f, len: m.len() })
}

fn hash_prefix(o: &mut Opened) -> Option<u64> {
    let mut buf = vec![0u8; PREFIX.min(o.len as usize)];
    o.f.read_exact(&mut buf).ok()?;
    let mut h = std::collections::hash_map::DefaultHasher::new();
    h.write(&buf);
    Some(h.finish())
}

fn hash_full(tree: &Tree, id: NodeId, len: u64, cancel: &AtomicBool) -> Option<u64> {
    let mut o = open_checked(tree, id).ok()?;
    if o.len != len { return None; }
    let mut h = std::collections::hash_map::DefaultHasher::new();
    let mut buf = vec![0u8; CHUNK];
    let mut left = len;
    while left > 0 {
        if cancel.load(Ordering::Relaxed) { return None; }
        let n = (left as usize).min(CHUNK);
        o.f.read_exact(&mut buf[..n]).ok()?;
        h.write(&buf[..n]);
        left -= n as u64;
    }
    Some(h.finish())
}

/// Byte-for-byte equality of two files of the same logical length. None on any read problem or cancel.
fn same_bytes(tree: &Tree, a: NodeId, b: NodeId, len: u64, cancel: &AtomicBool) -> Option<bool> {
    let (mut fa, mut fb) = (open_checked(tree, a).ok()?, open_checked(tree, b).ok()?);
    if fa.len != len || fb.len != len { return None; }
    let (mut ba, mut bb) = (vec![0u8; CHUNK], vec![0u8; CHUNK]);
    let mut left = len;
    while left > 0 {
        if cancel.load(Ordering::Relaxed) { return None; }
        let n = (left as usize).min(CHUNK);
        fa.f.read_exact(&mut ba[..n]).ok()?; fb.f.read_exact(&mut bb[..n]).ok()?;
        if ba[..n] != bb[..n] { return Some(false); }
        left -= n as u64;
    }
    Some(true)
}

#[derive(Default)]
struct Part { groups: Vec<DupGroup>, unreadable: u32, changed: u32, aliases: u32 }

fn process_size_group(tree: &Tree, size: u64, ids: Vec<NodeId>, cancel: &AtomicBool) -> Part {
    let mut part = Part::default();
    // 2. collapse hard-link aliases (same dev+ino) to the lowest id.
    let mut seen: HashMap<(u64, u64), NodeId> = HashMap::new();
    let mut ids: Vec<NodeId> = ids.into_iter().filter(|&i| match tree.scanned_identity(i) {
        Some(k) => if seen.contains_key(&k) { part.aliases += 1; false } else { seen.insert(k, i); true },
        None => true,
    }).collect();
    ids.sort_unstable();
    if ids.len() < 2 { return part; }
    // 3 + 4a. open, check, group by (logical length, prefix hash).
    let mut by_prefix: BTreeMap<(u64, u64), Vec<NodeId>> = BTreeMap::new();
    for id in ids {
        if cancel.load(Ordering::Relaxed) { return part; }
        match open_checked(tree, id) {
            Ok(mut o) => match hash_prefix(&mut o) { Some(h) => by_prefix.entry((o.len, h)).or_default().push(id), None => part.unreadable += 1 },
            Err(true) => part.unreadable += 1,
            Err(false) => part.changed += 1,
        }
    }
    for ((len, _), cand) in by_prefix {
        if cand.len() < 2 { continue; }
        // 4b. full hash.
        let mut by_full: BTreeMap<u64, Vec<NodeId>> = BTreeMap::new();
        for id in cand {
            if cancel.load(Ordering::Relaxed) { return part; }
            match hash_full(tree, id, len, cancel) { Some(h) => by_full.entry(h).or_default().push(id), None => part.unreadable += 1 }
        }
        for (_, same_hash) in by_full {
            if same_hash.len() < 2 { continue; }
            // 4c. byte-for-byte against class representatives.
            let mut classes: Vec<Vec<NodeId>> = Vec::new();
            for id in same_hash {
                let mut placed = false;
                for c in classes.iter_mut() {
                    match same_bytes(tree, c[0], id, len, cancel) {
                        Some(true) => { c.push(id); placed = true; break; }
                        Some(false) => {}
                        None => { part.unreadable += 1; placed = true; break; }
                    }
                }
                if !placed { classes.push(vec![id]); }
            }
            for mut c in classes { if c.len() >= 2 { c.sort_unstable(); part.groups.push(DupGroup { size, ids: c }); } }
        }
    }
    part
}

/// Find duplicate regular files. `min_size` is in scanned (allocated) bytes; zero-size files are never candidates. Cooperative `cancel`.
pub fn find_duplicates(tree: &Tree, min_size: u64, cancel: &AtomicBool) -> DupReport {
    let tab = tree.table();
    let dead = tab.dead_mask(tree);
    let mut by_size: BTreeMap<u64, Vec<NodeId>> = BTreeMap::new();
    for i in 0..tree.len() as NodeId {
        if tree.kind(i) != Kind::File { continue; }
        if dead.as_ref().map_or(false, |d| d[i as usize]) { continue; }
        let s = tab.sizes[i as usize];
        if s == 0 || s < min_size { continue; }
        by_size.entry(s).or_default().push(i);
    }
    let work: Vec<(u64, Vec<NodeId>)> = by_size.into_iter().filter(|(_, v)| v.len() >= 2).collect();
    let parts: Vec<Part> = work.into_par_iter().map(|(s, v)| process_size_group(tree, s, v, cancel)).collect();
    let mut r = DupReport { version: tab.version, cancelled: cancel.load(Ordering::Relaxed), ..Default::default() };
    for p in parts { r.groups.extend(p.groups); r.unreadable += p.unreadable; r.changed += p.changed; r.hardlink_aliases += p.aliases; }
    r.wasted = r.groups.iter().map(|g| g.size * (g.ids.len() as u64 - 1)).sum();
    r.groups.sort_by(|a, b| (b.size * (b.ids.len() as u64 - 1)).cmp(&(a.size * (a.ids.len() as u64 - 1))).then(a.ids[0].cmp(&b.ids[0])));
    r
}
