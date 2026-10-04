//! Read-only duplicate finder over a scanned tree. Reports groups of regular files with identical content as observed by this pass; it never
//! changes, moves or deletes anything and makes no statement about whether removing a member is safe or frees space.
//!
//! Method (each stage only narrows, the last stage proves equality):
//! 1. Candidates: live regular files (not symlinks, packages or directories) whose scanned size is > 0 and at least `min_size`.
//!    Grouping is by the scanned ALLOCATED size. Equal content stored with different allocation (sparse, compressed, some clones) can be
//!    MISSED: a recall limit, never a false duplicate. The reverse also holds: equal allocation says nothing about shared storage.
//! 2. Hard links to the same (dev, inode) that the scan kept as separate nodes are counted once (`hardlink_aliases`).
//! 3. Each candidate is opened with O_NOFOLLOW; it must still be a regular file with its scanned identity (when one was recorded).
//!    Otherwise it is counted `changed` (identity or type differs) or `unreadable` (open/read failed) and left out.
//! 4. Prefix hash, full-content hash (std SipHash, not cryptographic), then byte-for-byte comparison against class representatives. Members
//!    of a group matched byte-for-byte in this pass, so hash collisions cannot create a false group. Files can change after being read.
//! Limits: `cancel` stops cooperatively; `max_read_bytes` bounds disk reads. When either stops the pass, groups from a bucket that was not
//! fully processed are dropped (never a group with missing members), counters are lower bounds, and `cancelled` / `budget_exhausted` say why.
use crate::tree::{Kind, NodeId, Tree};
use rayon::prelude::*;
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::hash::Hasher;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DupGroup {
    /// Scanned (allocated) size of one member.
    pub size: u64,
    /// Members, ascending NodeId, at least 2.
    pub ids: Vec<NodeId>,
    /// How many members had a link count above 1 when opened (another path to the same storage may exist outside the scan, so removing
    /// that member would not free its bytes). 0 means none was seen, not that sharing is impossible (clones are invisible here).
    pub linked: u32,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DupReport {
    /// Largest duplicate_allocated_bytes (size * (members - 1)) first, ties by first member id.
    pub groups: Vec<DupGroup>,
    /// Sum over groups of size * (members - 1): the allocated size of the extra copies as scanned. NOT a reclaimable-space figure: identical
    /// content does not mean removing a copy frees these bytes. APFS clones can share storage, files can have other hard links outside the scan
    /// (see `DupGroup::linked`), compression changes allocation, and this pass checks none of that except the link count it saw.
    pub duplicate_allocated_bytes: u64,
    /// Candidates the pass did not finish: set when `cancelled` or `budget_exhausted`.
    pub incomplete: bool,
    pub budget_exhausted: bool,
    pub unreadable: u32,
    pub changed: u32,
    pub hardlink_aliases: u32,
    pub cancelled: bool,
    /// Table version the candidate set was captured at.
    pub version: u64,
}

/// Live counters, readable from another thread while a pass runs. All Relaxed: a progress display, never a result.
#[derive(Default)]
pub struct DupProgress {
    /// Candidate files after the size grouping (set once, before any file is read).
    pub candidates: AtomicU64,
    /// Candidates whose prefix stage has finished (opened and hashed, or counted unreadable/changed, or skipped as an alias).
    pub examined: AtomicU64,
    /// Bytes read from disk so far, all stages (prefix, full hash and compare reads), so it can exceed the sum of file sizes.
    pub bytes_read: AtomicU64,
    /// Set by the pass when `max_read_bytes` was reached.
    pub budget_hit: AtomicBool,
    max_read: AtomicU64,
    /// Test hook: called after every read with the running `bytes_read`. Not part of the stable API.
    #[doc(hidden)]
    pub on_read: Option<Box<dyn Fn(u64) + Send + Sync>>,
}
impl DupProgress {
    fn read(&self, n: usize) {
        let t = self.bytes_read.fetch_add(n as u64, Ordering::Relaxed) + n as u64;
        let m = self.max_read.load(Ordering::Relaxed);
        if m != 0 && t >= m { self.budget_hit.store(true, Ordering::Relaxed); }
        if let Some(h) = &self.on_read { h(t); }
    }
    fn stop(&self, cancel: &AtomicBool) -> bool { cancel.load(Ordering::Relaxed) || self.budget_hit.load(Ordering::Relaxed) }
}

const PREFIX: usize = 4096;
const CHUNK: usize = 64 * 1024;

struct Opened { f: File, len: u64, nlink: u64 }
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Fail { Unreadable, Changed, Stopped }

fn open_checked(tree: &Tree, id: NodeId) -> Result<Opened, Fail> {
    let path = tree.path(id);
    let f = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&path).map_err(|_| Fail::Unreadable)?;
    let m = f.metadata().map_err(|_| Fail::Unreadable)?;
    if !m.file_type().is_file() { return Err(Fail::Changed); }
    if let Some((dev, ino)) = tree.scanned_identity(id) { if m.dev() != dev || m.ino() != ino { return Err(Fail::Changed); } }
    Ok(Opened { f, len: m.len(), nlink: m.nlink() })
}

fn hash_prefix(o: &mut Opened, pr: &DupProgress) -> Result<u64, Fail> {
    let mut buf = vec![0u8; PREFIX.min(o.len as usize)];
    o.f.read_exact(&mut buf).map_err(|_| Fail::Unreadable)?;
    pr.read(buf.len());
    let mut h = std::collections::hash_map::DefaultHasher::new();
    h.write(&buf);
    Ok(h.finish())
}

fn hash_full(tree: &Tree, id: NodeId, len: u64, cancel: &AtomicBool, pr: &DupProgress) -> Result<u64, Fail> {
    let mut o = open_checked(tree, id)?;
    if o.len != len { return Err(Fail::Changed); }
    let mut h = std::collections::hash_map::DefaultHasher::new();
    let mut buf = vec![0u8; CHUNK];
    let mut left = len;
    while left > 0 {
        if pr.stop(cancel) { return Err(Fail::Stopped); }
        let n = (left as usize).min(CHUNK);
        o.f.read_exact(&mut buf[..n]).map_err(|_| Fail::Unreadable)?;
        pr.read(n);
        h.write(&buf[..n]);
        left -= n as u64;
    }
    Ok(h.finish())
}

/// Which file of a compared pair a failure belongs to: A is the class representative, B the file being placed.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Side { A, B }

/// Byte-for-byte equality of two files of the same logical length. A failure names the file it happened on.
fn same_bytes(tree: &Tree, a: NodeId, b: NodeId, len: u64, cancel: &AtomicBool, pr: &DupProgress) -> Result<bool, (Fail, Side)> {
    let mut fa = open_checked(tree, a).map_err(|f| (f, Side::A))?;
    let mut fb = open_checked(tree, b).map_err(|f| (f, Side::B))?;
    if fa.len != len { return Err((Fail::Changed, Side::A)); }
    if fb.len != len { return Err((Fail::Changed, Side::B)); }
    let (mut ba, mut bb) = (vec![0u8; CHUNK], vec![0u8; CHUNK]);
    let mut left = len;
    while left > 0 {
        if pr.stop(cancel) { return Err((Fail::Stopped, Side::B)); }
        let n = (left as usize).min(CHUNK);
        fa.f.read_exact(&mut ba[..n]).map_err(|_| (Fail::Unreadable, Side::A))?;
        fb.f.read_exact(&mut bb[..n]).map_err(|_| (Fail::Unreadable, Side::B))?;
        pr.read(2 * n);
        if ba[..n] != bb[..n] { return Ok(false); }
        left -= n as u64;
    }
    Ok(true)
}

#[derive(Default)]
struct Part { groups: Vec<DupGroup>, unreadable: u32, changed: u32, aliases: u32 }
impl Part {
    fn fail(&mut self, f: Fail) { match f { Fail::Unreadable => self.unreadable += 1, Fail::Changed => self.changed += 1, Fail::Stopped => {} } }
}

fn process_size_group(tree: &Tree, size: u64, ids: Vec<NodeId>, cancel: &AtomicBool, pr: &DupProgress) -> Part {
    let mut part = Part::default();
    // 2. collapse hard-link aliases (same dev+ino) to the lowest id.
    let mut seen: HashMap<(u64, u64), NodeId> = HashMap::new();
    let mut ids: Vec<NodeId> = ids.into_iter().filter(|&i| match tree.scanned_identity(i) {
        Some(k) => if seen.contains_key(&k) { part.aliases += 1; pr.examined.fetch_add(1, Ordering::Relaxed); false } else { seen.insert(k, i); true },
        None => true,
    }).collect();
    ids.sort_unstable();
    if ids.len() < 2 { pr.examined.fetch_add(ids.len() as u64, Ordering::Relaxed); return part; }
    // 3 + 4a. open, check, group by (logical length, prefix hash); remember link counts.
    let mut nlink: HashMap<NodeId, u64> = HashMap::new();
    let mut by_prefix: BTreeMap<(u64, u64), Vec<NodeId>> = BTreeMap::new();
    for id in ids {
        if pr.stop(cancel) { return part; }
        match open_checked(tree, id).and_then(|mut o| { nlink.insert(id, o.nlink); hash_prefix(&mut o, pr).map(|h| (o.len, h)) }) {
            Ok(k) => by_prefix.entry(k).or_default().push(id),
            Err(f) => part.fail(f),
        }
        pr.examined.fetch_add(1, Ordering::Relaxed);
    }
    for ((len, _), cand) in by_prefix {
        if cand.len() < 2 { continue; }
        // 4b. full hash.
        let mut by_full: BTreeMap<u64, Vec<NodeId>> = BTreeMap::new();
        for id in cand {
            match hash_full(tree, id, len, cancel, pr) { Ok(h) => by_full.entry(h).or_default().push(id), Err(f) => part.fail(f) }
            if pr.stop(cancel) { return part; }
        }
        for (_, same_hash) in by_full {
            if same_hash.len() < 2 { continue; }
            // 4c. byte-for-byte against class representatives. A stopped pass drops this bucket's groups: a class could be missing members.
            let mut classes: Vec<Vec<NodeId>> = Vec::new();
            'files: for id in same_hash {
                loop {
                    let mut dropped_rep = false;
                    for ci in 0..classes.len() {
                        match same_bytes(tree, classes[ci][0], id, len, cancel, pr) {
                            Ok(true) => { classes[ci].push(id); continue 'files; }
                            Ok(false) => {}
                            Err((Fail::Stopped, _)) => return part,
                            Err((f, Side::B)) => { part.fail(f); continue 'files; }        // the file being placed is out
                            Err((f, Side::A)) => {                                          // the REPRESENTATIVE failed: it alone is out, the rest of its class stays
                                part.fail(f);
                                classes[ci].remove(0);
                                if classes[ci].is_empty() { classes.remove(ci); }
                                dropped_rep = true; break;
                            }
                        }
                    }
                    if !dropped_rep { classes.push(vec![id]); continue 'files; }
                }
            }
            if pr.stop(cancel) { return part; }
            for mut c in classes {
                if c.len() >= 2 {
                    c.sort_unstable();
                    let linked = c.iter().filter(|i| nlink.get(i).map_or(false, |&n| n > 1)).count() as u32;
                    part.groups.push(DupGroup { size, ids: c, linked });
                }
            }
        }
    }
    part
}

/// Options for `find_duplicates_opts`.
#[derive(Debug, Clone, Copy, Default)]
pub struct DupOptions {
    /// Minimum scanned (allocated) size; zero-size files are never candidates.
    pub min_size: u64,
    /// Stop after about this many bytes were read from disk (all stages); 0 = unbounded. Checked per chunk, so the overshoot is at most one chunk per worker.
    pub max_read_bytes: u64,
}

/// Find duplicate regular files with a cooperative `cancel`.
pub fn find_duplicates(tree: &Tree, min_size: u64, cancel: &AtomicBool) -> DupReport {
    find_duplicates_opts(tree, DupOptions { min_size, max_read_bytes: 0 }, cancel, &DupProgress::default())
}

/// As `find_duplicates` with counters (`progress`) and a read budget.
pub fn find_duplicates_with(tree: &Tree, min_size: u64, cancel: &AtomicBool, progress: &DupProgress) -> DupReport {
    find_duplicates_opts(tree, DupOptions { min_size, max_read_bytes: 0 }, cancel, progress)
}

pub fn find_duplicates_opts(tree: &Tree, opts: DupOptions, cancel: &AtomicBool, progress: &DupProgress) -> DupReport {
    // A DupProgress describes ONE pass: it is reset here (counters, budget flag) so reusing it never carries a stale budget_hit or old totals.
    // Sharing one DupProgress between passes that run at the same time is not supported.
    progress.candidates.store(0, Ordering::Relaxed); progress.examined.store(0, Ordering::Relaxed); progress.bytes_read.store(0, Ordering::Relaxed);
    progress.budget_hit.store(false, Ordering::Relaxed);
    progress.max_read.store(opts.max_read_bytes, Ordering::Relaxed);
    let min_size = opts.min_size;
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
    progress.candidates.store(work.iter().map(|(_, v)| v.len() as u64).sum(), Ordering::Relaxed);
    let parts: Vec<Part> = work.into_par_iter().map(|(s, v)| process_size_group(tree, s, v, cancel, progress)).collect();
    let cancelled = cancel.load(Ordering::Relaxed);
    let budget = progress.budget_hit.load(Ordering::Relaxed);
    let mut r = DupReport { version: tab.version, cancelled, budget_exhausted: budget, incomplete: cancelled || budget, ..Default::default() };
    for p in parts { r.groups.extend(p.groups); r.unreadable += p.unreadable; r.changed += p.changed; r.hardlink_aliases += p.aliases; }
    r.duplicate_allocated_bytes = r.groups.iter().map(|g| g.size * (g.ids.len() as u64 - 1)).sum();
    r.groups.sort_by(|a, b| (b.size * (b.ids.len() as u64 - 1)).cmp(&(a.size * (a.ids.len() as u64 - 1))).then(a.ids[0].cmp(&b.ids[0])));
    r
}
