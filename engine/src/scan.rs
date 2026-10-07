//! Parallel directory scanner.
//!
//! One thread-pool task per directory, work-stealing across subdirectories. Per-directory
//! enumeration is a backend: `getattrlistbulk(2)` on macOS (one syscall per batch of
//! entries, sizes included), `readdir` + `fstatat` elsewhere and as the macOS fallback.
//! Sizes are allocated bytes (st_blocks * 512 / ATTR_FILE_ALLOCSIZE). Hard-linked files
//! and directories reachable by two paths (firmlinks) are counted once.

use crate::category::Category;
use crate::events::{EventKind, PreviewEvents};
use crate::tree::{Kind, SkipReason, Skipped, Tree, NO_NODE};
use rayon::prelude::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
pub struct ScanOptions {
    /// Absolute paths whose subtrees are skipped entirely.
    pub exclude: Vec<PathBuf>,
    /// Follow into other mounted volumes. Default false.
    pub cross_devices: bool,
    /// Force the portable readdir/stat backend (used to cross-check the bulk backend).
    pub force_portable: bool,
    /// Worker threads; 0 = rayon default (logical cores).
    pub threads: usize,
}

/// Shared, lock-free progress. Poll from any thread while `scan` runs.
#[derive(Default)]
pub struct ScanProgress {
    pub items: AtomicU64,
    pub bytes: AtomicU64,
    pub cancel: AtomicBool,
    #[cfg(test)]
    visited_dirs: AtomicU64,
    #[cfg(test)]
    cancel_after: AtomicU64,
}

impl ScanProgress {
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    /// Deterministic cancel injection for tests: the scan cancels when the Nth
    /// directory walk begins. 0 (the default) disables the tripwire.
    #[cfg(test)]
    #[doc(hidden)]
    pub fn cancel_after_dirs(&self, n: u64) {
        self.cancel_after.store(n, Ordering::Relaxed);
    }

    #[cfg(test)]
    fn note_dir(&self) {
        let n = self.visited_dirs.fetch_add(1, Ordering::Relaxed) + 1;
        let trip = self.cancel_after.load(Ordering::Relaxed);
        if trip != 0 && n >= trip {
            self.cancel();
        }
    }

    /// Shipping builds keep the per-directory path untouched.
    #[cfg(not(test))]
    #[inline(always)]
    fn note_dir(&self) {}
}

pub(crate) struct RawEntry {
    pub name: Box<str>,
    pub kind: Kind,
    pub alloc: u64,
    pub nlink: u32,
    pub dev: u64,
    pub ino: u64,
    pub mtime: i64,
}

struct Ent {
    mtime: i64,
    name: Box<str>,
    kind: Kind,
    size: u64,
    dir: Option<Box<DirNode>>,
}

struct DirNode {
    ents: Vec<Ent>,
    total: u64,
}

const SHARDS: usize = 64;

struct Seen {
    shards: Vec<Mutex<HashSet<(u64, u64)>>>,
}

impl Seen {
    fn new() -> Self {
        Seen { shards: (0..SHARDS).map(|_| Mutex::new(HashSet::new())).collect() }
    }
    /// True the first time an identity is claimed.
    fn claim(&self, dev: u64, ino: u64) -> bool {
        let s = (ino as usize ^ (ino >> 7) as usize) % SHARDS;
        self.shards[s].lock().unwrap().insert((dev, ino))
    }
}

struct Ctx<'a> {
    opts: &'a ScanOptions,
    progress: &'a ScanProgress,
    files: Seen,
    dirs: Seen,
    root_dev: u64,
    skipped: Mutex<Vec<Skipped>>,
    exclude: Vec<String>,
    events: Option<&'a PreviewEvents>,
    #[allow(dead_code)]
    bulk: bool,
}

pub fn scan(root: &Path, opts: &ScanOptions, progress: &ScanProgress) -> std::io::Result<Tree> {
    scan_inner(root, opts, progress, None)
}

/// `scan` plus progressive preview events. The returned `Tree` is identical to what
/// `scan` produces; events are best-effort extras bound to the sink's generation and
/// canonical root. Errors when the sink was built for a different root.
pub fn scan_with_events(
    root: &Path,
    opts: &ScanOptions,
    progress: &ScanProgress,
    events: &PreviewEvents,
) -> std::io::Result<Tree> {
    scan_inner(root, opts, progress, Some(events))
}

fn scan_inner(
    root: &Path,
    opts: &ScanOptions,
    progress: &ScanProgress,
    events: Option<&PreviewEvents>,
) -> std::io::Result<Tree> {
    let root = root.canonicalize()?;
    if let Some(ev) = events {
        if !ev.root_matches(&root) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "preview event sink root does not match the canonical scan root",
            ));
        }
        if !ev.claim() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "preview event sink already claimed by a scan (sinks are one-shot)",
            ));
        }
    }
    let md = std::fs::symlink_metadata(&root)?;
    if !md.is_dir() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "not a directory"));
    }
    use std::os::unix::fs::MetadataExt;
    let ctx = Ctx {
        opts,
        progress,
        files: Seen::new(),
        dirs: Seen::new(),
        root_dev: md.dev(),
        skipped: Mutex::new(Vec::new()),
        exclude: opts
            .exclude
            .iter()
            .map(|p| p.to_string_lossy().trim_end_matches('/').to_string())
            .collect(),
        events,
        bulk: cfg!(target_os = "macos") && !opts.force_portable,
    };
    ctx.dirs.claim(md.dev(), md.ino());

    let run = || walk(&root, &ctx);
    let (node, complete) = if opts.threads > 0 {
        let pool = rayon::ThreadPoolBuilder::new().num_threads(opts.threads).build().unwrap();
        pool.install(run)
    } else {
        run()
    };

    let tree = flatten(root.to_string_lossy().into_owned(), node, ctx, progress);
    if let Some(ev) = events {
        // Root completeness (under the scanner's accounting) rides the terminal: a
        // suppressed subtree leaves previews provisional even when the scan was
        // neither cancelled nor lossy.
        ev.finish(tree.cancelled, complete);
    }
    Ok(tree)
}

fn is_package(name: &str) -> bool {
    const EXTS: [&str; 8] = ["app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "photoslibrary"];
    match name.rfind('.') {
        Some(i) if i > 0 => EXTS.iter().any(|e| name[i + 1..].eq_ignore_ascii_case(e)),
        _ => false,
    }
}

fn walk(dir: &Path, ctx: &Ctx) -> (DirNode, bool) {
    ctx.progress.note_dir();
    if ctx.progress.cancel.load(Ordering::Relaxed) {
        return (DirNode { ents: vec![], total: 0 }, false);
    }
    let raw = match enumerate(dir, ctx) {
        Ok(r) => r,
        Err(e) => {
            let reason = if e.kind() == std::io::ErrorKind::PermissionDenied {
                SkipReason::PermissionDenied
            } else {
                SkipReason::Unreadable
            };
            ctx.skipped.lock().unwrap().push(Skipped { path: dir.to_string_lossy().into_owned(), reason });
            return (DirNode { ents: vec![], total: 0 }, false);
        }
    };

    let mut ents: Vec<Ent> = Vec::with_capacity(raw.len());
    let mut subdirs: Vec<(usize, PathBuf)> = Vec::new();
    let mut local_bytes = 0u64;
    for r in raw {
        match r.kind {
            Kind::Directory => {
                let path = dir.join(&*r.name);
                if !ctx.exclude.is_empty() {
                    let p = path.to_string_lossy();
                    if ctx.exclude.iter().any(|x| *x == *p) {
                        ctx.skipped.lock().unwrap().push(Skipped {
                            path: p.into_owned(),
                            reason: SkipReason::UserExcluded,
                        });
                        continue;
                    }
                }
                if !ctx.opts.cross_devices && r.dev != ctx.root_dev {
                    ctx.skipped.lock().unwrap().push(Skipped {
                        path: path.to_string_lossy().into_owned(),
                        reason: SkipReason::SeparateVolume,
                    });
                    continue;
                }
                // Same directory reachable twice (macOS firmlinks): walk it once.
                if !ctx.dirs.claim(r.dev, r.ino) {
                    continue;
                }
                let kind = if is_package(&r.name) { Kind::Package } else { Kind::Directory };
                subdirs.push((ents.len(), path));
                ents.push(Ent { mtime: r.mtime, name: r.name, kind, size: 0, dir: None });
            }
            k => {
                let size = if k == Kind::File && r.nlink > 1 && !ctx.files.claim(r.dev, r.ino) {
                    0
                } else {
                    r.alloc
                };
                local_bytes += size;
                ents.push(Ent { mtime: r.mtime, name: r.name, kind: k, size, dir: None });
            }
        }
    }
    ctx.progress.items.fetch_add(ents.len() as u64, Ordering::Relaxed);
    ctx.progress.bytes.fetch_add(local_bytes, Ordering::Relaxed);

    let results: Vec<(usize, (DirNode, bool))> = if subdirs.len() > 1 {
        subdirs.par_iter().map(|(i, p)| (*i, walk(p, ctx))).collect()
    } else {
        subdirs.iter().map(|(i, p)| (*i, walk(p, ctx))).collect()
    };
    let mut total = local_bytes;
    let mut complete = true;
    for (i, (node, child_complete)) in results {
        total += node.total;
        ents[i].size = node.total;
        ents[i].dir = Some(Box::new(node));
        complete &= child_complete;
    }
    if complete {
        if let Some(ev) = ctx.events {
            ev.emit(EventKind::DirComplete {
                path: dir.to_path_buf(),
                size: total,
            });
        }
    }
    (DirNode { ents, total }, complete)
}

/// Breadth-first flatten so each directory's children are contiguous and size-sorted.
fn flatten(root_path: String, root: DirNode, ctx: Ctx, progress: &ScanProgress) -> Tree {
    let mut t = Tree { root_path, ..Default::default() };
    let push = |t: &mut Tree, name: &str, parent: u32, kind: Kind, size: u64, mtime: i64| -> u32 {
        let id = t.names.len() as u32;
        t.names.push(name.into());
        t.parent.push(parent);
        t.kind.push(kind as u8);
        t.category.push(if kind == Kind::Directory || kind == Kind::Package {
            Category::Folder as u8
        } else {
            Category::classify(name) as u8
        });
        t.size.push(size);
        t.mtime.push(mtime);
        t.first_child.push(NO_NODE);
        t.child_count.push(0);
        id
    };
    push(&mut t, "", NO_NODE, Kind::Directory, root.total, 0);
    let mut queue: std::collections::VecDeque<(u32, DirNode)> = std::collections::VecDeque::new();
    queue.push_back((0, root));
    while let Some((id, mut node)) = queue.pop_front() {
        node.ents.sort_unstable_by(|a, b| b.size.cmp(&a.size).then_with(|| a.name.cmp(&b.name)));
        if node.ents.is_empty() {
            continue;
        }
        t.first_child[id as usize] = t.names.len() as u32;
        t.child_count[id as usize] = node.ents.len() as u32;
        for e in node.ents {
            let cid = push(&mut t, &e.name, id, e.kind, e.size, e.mtime);
            if let Some(d) = e.dir {
                queue.push_back((cid, *d));
            }
        }
    }
    t.items = t.len() as u64 - 1;
    t.cancelled = progress.cancel.load(Ordering::Relaxed);
    t.skipped = ctx.skipped.into_inner().unwrap();
    t
}

#[cfg(target_os = "macos")]
fn enumerate(dir: &Path, ctx: &Ctx) -> std::io::Result<Vec<RawEntry>> {
    if ctx.bulk {
        match crate::scan_macos::enumerate_bulk(dir) {
            Ok(v) => return Ok(v),
            // Filesystem without getattrlistbulk support: fall back for this directory.
            Err(e) if matches!(e.raw_os_error(), Some(libc::ENOTSUP) | Some(libc::EINVAL)) => {}
            Err(e) => return Err(e),
        }
    }
    enumerate_portable(dir)
}

#[cfg(not(target_os = "macos"))]
fn enumerate(dir: &Path, _ctx: &Ctx) -> std::io::Result<Vec<RawEntry>> {
    enumerate_portable(dir)
}

pub(crate) fn enumerate_portable(dir: &Path) -> std::io::Result<Vec<RawEntry>> {
    use std::os::unix::fs::MetadataExt;
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir)? {
        let Ok(e) = e else { continue };
        let Ok(md) = e.metadata() else { continue }; // lstat semantics, no symlink follow
        let ft = md.file_type();
        let kind = if ft.is_dir() {
            Kind::Directory
        } else if ft.is_symlink() {
            Kind::Symlink
        } else {
            Kind::File
        };
        out.push(RawEntry {
            name: e.file_name().to_string_lossy().into_owned().into_boxed_str(),
            kind,
            alloc: md.blocks() * 512,
            nlink: md.nlink() as u32,
            dev: md.dev(),
            ino: md.ino(),
            mtime: md.mtime(),
        });
    }
    Ok(out)
}

/// Convenience for callers that want a shared handle.
pub fn new_progress() -> Arc<ScanProgress> {
    Arc::new(ScanProgress::default())
}
