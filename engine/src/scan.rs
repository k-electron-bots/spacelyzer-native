//! Parallel directory scanner.
//!
//! One thread-pool task per directory, work-stealing across subdirectories. Per-directory
//! enumeration is a backend: `getattrlistbulk(2)` on macOS (one syscall per batch of
//! entries, sizes included), `readdir` + `fstatat` elsewhere and as the macOS fallback.
//! Sizes are allocated bytes (st_blocks * 512 / ATTR_FILE_ALLOCSIZE). Hard-linked files
//! and directories reachable by two paths (firmlinks) are counted once.

use crate::category::Category;
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
}

impl ScanProgress {
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}

pub(crate) struct RawEntry {
    pub name: Box<str>,
    /// The real name is not valid UTF-8, so `name` is a lossy rendering that can collide with sibling names and cannot be used to reopen the entry.
    pub name_lossy: bool,
    /// 0 = a normal entry. 1 = its metadata could not be read (permission denied), 2 = other error other than "vanished". The entry has no usable size; it is
    /// recorded as skipped instead of silently disappearing from the totals. An entry that vanished mid-scan (ENOENT) is not an error and is not emitted.
    pub failed: u8,
    pub kind: Kind,
    pub alloc: u64,
    pub nlink: u32,
    pub dev: u64,
    pub ino: u64,
    pub mtime: i64,
}

struct Ent {
    /// Index into the scan's interned device table (see `dev_index`), not the raw device id: 1 byte instead of 8 per pending entry.
    dev: u8,
    ino: u64,
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
    root_ino: u64,
    devs: Mutex<Vec<u64>>,
    skipped: Mutex<Vec<Skipped>>,
    exclude: Vec<Option<String>>,
    /// Parallel to `exclude`: true once some scanned entry matched it. Non-matchable (non-UTF-8) exclusions stay false.
    excl_hit: Vec<AtomicBool>,
    excl_display: Vec<String>,
    /// Exclusion index by parent directory text: only directories that are the parent of some exclusion pay any per-entry matching cost.
    excl_by_parent: std::collections::HashMap<String, Vec<(Box<str>, usize)>>,
    #[allow(dead_code)]
    bulk: bool,
}

/// Stack for each walker thread. Linux PATH_MAX (4096) bounds depth near 2000 one-letter levels; this leaves roughly 30x headroom on that.
const WALK_STACK_BYTES: usize = 64 << 20;

pub fn scan(root: &Path, opts: &ScanOptions, progress: &ScanProgress) -> std::io::Result<Tree> {
    let root = root.canonicalize()?;
    // Fail closed: every path the tree builds is root + node names, and the root is stored as text. A root that is not valid UTF-8 would be stored lossily
    // and every later removal/reveal path would point somewhere else (or nowhere).
    if root.to_str().is_none() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "scan root path is not valid UTF-8"));
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
        root_ino: md.ino(),
        devs: Mutex::new(Vec::new()),
        skipped: Mutex::new(Vec::new()),
        excl_hit: opts.exclude.iter().map(|_| AtomicBool::new(false)).collect(),
        excl_display: opts.exclude.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
        exclude: opts
            .exclude
            .iter()
            // An exclusion that is not valid UTF-8 can only name a non-UTF-8 entry, which the walk already leaves out, so it is never matchable (None); a lossy
            // form could overmatch a real U+FFFD-named sibling. It stays in the list so it is REPORTED as unmatched rather than silently vanishing.
            .map(|p| p.to_str().map(|p| p.trim_end_matches('/').to_string()))
            .collect(),
        bulk: cfg!(target_os = "macos") && !opts.force_portable,
        excl_by_parent: Default::default(),
    };
    let mut ctx = ctx;
    ctx.excl_by_parent = build_exclusion_index(&ctx.exclude);
    ctx.dirs.claim(md.dev(), md.ino());

    // `walk` recurses once per directory level. The pool's workers get an explicit large stack (address space only; pages are touched on use) so a pathologically
    // deep tree returns a result instead of aborting the process. `install` runs the walk on a worker, never on the caller's thread, whose stack we do not own.
    let run = || walk(&root, &ctx);
    let mut pool = rayon::ThreadPoolBuilder::new().stack_size(WALK_STACK_BYTES);
    if opts.threads > 0 {
        pool = pool.num_threads(opts.threads);
    }
    let node = pool.build().map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?.install(run);

    Ok(flatten(root.to_string_lossy().into_owned(), node, ctx, progress))
}

fn is_package(name: &str) -> bool {
    const EXTS: [&str; 8] = ["app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "photoslibrary"];
    match name.rfind('.') {
        Some(i) if i > 0 => EXTS.iter().any(|e| name[i + 1..].eq_ignore_ascii_case(e)),
        _ => false,
    }
}

/// Intern a device id into the shared table (normally 1-2 entries; the lock is taken only when a directory's device changes).
/// Up to 255 distinct devices get indexes 0..=254; the 256th and later map to DEV_UNKNOWN (255), which the tree reads as "no scanned identity".
fn dev_index(ctx: &Ctx, last: &mut (u64, u8), dev: u64) -> u8 { intern_dev(&ctx.devs, last, dev) }
fn intern_dev(devs: &Mutex<Vec<u64>>, last: &mut (u64, u8), dev: u64) -> u8 {
    if last.1 != crate::tree::DEV_UNKNOWN && last.0 == dev { return last.1; }
    let mut g = devs.lock().unwrap();
    let ix = match g.iter().position(|&d| d == dev) {
        Some(i) => i as u8,
        None if g.len() < crate::tree::DEV_UNKNOWN as usize => { g.push(dev); (g.len() - 1) as u8 }
        None => crate::tree::DEV_UNKNOWN,
    };
    *last = (dev, ix); ix
}

/// parent text -> [(entry name, exclusion index)]. An exclusion "P/N" matches exactly the entry named N inside the directory whose text is P, which is the same
/// string equality as comparing dir.join(name) with the whole exclusion, without building a path per scanned entry. The root directory "/" is keyed as "".
fn build_exclusion_index(ex: &[Option<String>]) -> std::collections::HashMap<String, Vec<(Box<str>, usize)>> {
    let mut m: std::collections::HashMap<String, Vec<(Box<str>, usize)>> = Default::default();
    for (i, x) in ex.iter().enumerate() {
        let Some(x) = x else { continue };
        let Some(k) = x.rfind('/') else { continue }; // a relative request can never equal a joined absolute path
        if k + 1 == x.len() { continue }
        m.entry(x[..k].to_string()).or_default().push((x[k + 1..].into(), i));
    }
    m
}

fn walk(dir: &Path, ctx: &Ctx) -> DirNode {
    if ctx.progress.cancel.load(Ordering::Relaxed) {
        return DirNode { ents: vec![], total: 0 };
    }
    let raw = match enumerate(dir, ctx) {
        Ok(r) => r,
        Err(e) => {
            let reason = if e.kind() == std::io::ErrorKind::PermissionDenied {
                SkipReason::PermissionDenied
            } else {
                SkipReason::Unreadable
            };
            ctx.skipped.lock().unwrap().push(Skipped::new(dir, reason));
            return DirNode { ents: vec![], total: 0 };
        }
    };

    let mut ents: Vec<Ent> = Vec::with_capacity(raw.len());
    let mut subdirs: Vec<(usize, PathBuf)> = Vec::new();
    let mut local_bytes = 0u64;
    let mut last_dev: (u64, u8) = (0, crate::tree::DEV_UNKNOWN);
    let dir_excl: Option<&Vec<(Box<str>, usize)>> = if ctx.excl_by_parent.is_empty() { None } else {
        dir.to_str().and_then(|d| ctx.excl_by_parent.get(if d == "/" { "" } else { d }))
    };
    for r in raw {
        if r.name_lossy {
            // Fail closed: a node must never carry a name that can alias a sibling or point at a different real entry (removal/reveal/rescan build
            // paths from names). Left out of the tree and listed as unreadable with the lossy flag; its bytes are NOT in any total.
            ctx.skipped.lock().unwrap().push(Skipped::new(&dir.join(&*r.name), SkipReason::Unreadable));
            continue;
        }
        if r.failed != 0 {
            // Empty name = the iterator failed for this directory: the skipped path is the directory itself.
            let path = if r.name.is_empty() { dir.to_path_buf() } else { dir.join(&*r.name) };
            ctx.skipped.lock().unwrap().push(Skipped::new(&path, if r.failed == 1 { SkipReason::PermissionDenied } else { SkipReason::Unreadable }));
            continue;
        }
        if let Some(list) = dir_excl {
            // Any entry kind (directory, file, symlink) can be excluded by exact path. Every equal exclusion is marked as hit.
            let mut hit = false;
            for (n, i) in list { if **n == *r.name { ctx.excl_hit[*i].store(true, Ordering::Relaxed); hit = true; } }
            if hit {
                ctx.skipped.lock().unwrap().push(Skipped::new(&dir.join(&*r.name), SkipReason::UserExcluded));
                continue;
            }
        }
        match r.kind {
            Kind::Directory => {
                let path = dir.join(&*r.name);
                if !ctx.opts.cross_devices && r.dev != ctx.root_dev {
                    ctx.skipped.lock().unwrap().push(Skipped::new(&path, SkipReason::SeparateVolume));
                    continue;
                }
                // Same directory reachable twice (macOS firmlinks): walk it once.
                if !ctx.dirs.claim(r.dev, r.ino) {
                    continue;
                }
                let kind = if is_package(&r.name) { Kind::Package } else { Kind::Directory };
                subdirs.push((ents.len(), path));
                ents.push(Ent { dev: dev_index(ctx, &mut last_dev, r.dev), ino: r.ino, mtime: r.mtime, name: r.name, kind, size: 0, dir: None });
            }
            k => {
                let size = if k == Kind::File && r.nlink > 1 && !ctx.files.claim(r.dev, r.ino) {
                    0
                } else {
                    r.alloc
                };
                local_bytes += size;
                ents.push(Ent { dev: dev_index(ctx, &mut last_dev, r.dev), ino: r.ino, mtime: r.mtime, name: r.name, kind: k, size, dir: None });
            }
        }
    }
    ctx.progress.items.fetch_add(ents.len() as u64, Ordering::Relaxed);
    ctx.progress.bytes.fetch_add(local_bytes, Ordering::Relaxed);

    let results: Vec<(usize, DirNode)> = if subdirs.len() > 1 {
        subdirs.par_iter().map(|(i, p)| { crate::tree::worker_failpoint(); (*i, walk(p, ctx)) }).collect()
    } else {
        subdirs.iter().map(|(i, p)| (*i, walk(p, ctx))).collect()
    };
    let mut total = local_bytes;
    for (i, node) in results {
        total += node.total;
        ents[i].size = node.total;
        ents[i].dir = Some(Box::new(node));
    }
    DirNode { ents, total }
}

/// Breadth-first flatten so each directory's children are contiguous and size-sorted.
fn flatten(root_path: String, root: DirNode, ctx: Ctx, progress: &ScanProgress) -> Tree {
    let root_dev_ix = dev_index(&ctx, &mut (0, crate::tree::DEV_UNKNOWN), ctx.root_dev);
    let root_ident = (root_dev_ix, ctx.root_ino);
    let mut t = Tree { root_path, ..Default::default() };
    t.identity_enabled = t.reserve_identity(ctx.progress.items.load(Ordering::Relaxed) as usize + 1);
    let push = |t: &mut Tree, name: &str, parent: u32, kind: Kind, size: u64, mtime: i64, ident: (u8, u64)| -> u32 {
        let id = t.names.len() as u32;
        t.push_identity_ix(ident.0, ident.1);
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
    push(&mut t, "", NO_NODE, Kind::Directory, root.total, 0, root_ident);
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
            let cid = push(&mut t, &e.name, id, e.kind, e.size, e.mtime, (e.dev, e.ino));
            if let Some(d) = e.dir {
                queue.push_back((cid, *d));
            }
        }
    }
    t.devs = ctx.devs.into_inner().unwrap();
    t.items = t.len() as u64 - 1;
    t.cancelled = progress.cancel.load(Ordering::Relaxed);
    t.skipped = ctx.skipped.into_inner().unwrap();
    // Exclusions the walk never observed an entry for. NOT "nothing exists there": a request under a skipped subtree (excluded, permission denied, unreadable,
    // separate volume, or a lossy-named directory) was never visited and may well exist. Reason codes: see `UnobservedReason`. Only meaningful for a complete
    // scan: a cancelled walk may simply not have reached the entry.
    if !t.cancelled {
        let mut u: Vec<(String, u8)> = Vec::new();
        for (i, d) in ctx.excl_display.iter().enumerate() {
            if ctx.excl_hit[i].load(Ordering::Relaxed) { continue; }
            let reason = if ctx.exclude[i].is_none() { crate::tree::UnobservedReason::NotMatchable }
                else if t.skipped.iter().any(|sk| *d == sk.path || d.strip_prefix(&sk.path).map_or(false, |r| r.starts_with('/'))) { crate::tree::UnobservedReason::InsideSkippedSubtree }
                else { crate::tree::UnobservedReason::NotSeen };
            u.push((d.clone(), reason as u8));
        }
        u.sort(); u.dedup();
        t.unobserved_exclusions = u;
    }
    // Pushed from parallel workers in whatever order they finish; sort so index i means the same entry on every scan of the same disk state.
    t.skipped.sort_by(|a, b| a.path.cmp(&b.path).then((a.reason as u8).cmp(&(b.reason as u8))));
    t.seal()
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

fn dir_name_marker() -> std::ffi::OsString { std::ffi::OsString::new() }

fn failed_entry(name: std::ffi::OsString, err: &std::io::Error) -> RawEntry {
    RawEntry {
        name_lossy: name.to_str().is_none(),
        name: name.to_string_lossy().into_owned().into_boxed_str(),
        failed: if err.kind() == std::io::ErrorKind::PermissionDenied { 1 } else { 2 },
        kind: Kind::File, alloc: 0, nlink: 1, dev: 0, ino: 0, mtime: 0,
    }
}

pub(crate) fn enumerate_portable(dir: &Path) -> std::io::Result<Vec<RawEntry>> {
    use std::os::unix::fs::MetadataExt;
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir)? {
        let e = match e {
            Ok(e) => e,
            // The directory iterator itself failed (no entry name available): record the directory once as unreadable.
            Err(err) => { out.push(failed_entry(dir_name_marker(), &err)); continue }
        };
        let md = match e.metadata() { // lstat semantics, no symlink follow
            Ok(m) => m,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
            Err(err) => { out.push(failed_entry(e.file_name(), &err)); continue }
        };
        let ft = md.file_type();
        let kind = if ft.is_dir() {
            Kind::Directory
        } else if ft.is_symlink() {
            Kind::Symlink
        } else {
            Kind::File
        };
        out.push(RawEntry {
            name_lossy: e.file_name().to_str().is_none(),
            failed: 0,
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

#[cfg(test)]
mod dev_intern_tests {
    use super::*;
    use crate::tree::DEV_UNKNOWN;
    fn fresh() -> ((u64, u8), Mutex<Vec<u64>>) { ((0, DEV_UNKNOWN), Mutex::new(Vec::new())) }

    #[test]
    fn device_changes_between_entries_keep_indexes_consistent_through_the_one_entry_cache() {
        let (mut last, devs) = fresh();
        let seq = [7u64, 7, 9, 7, 9, 9, 7];
        let ix: Vec<u8> = seq.iter().map(|&d| intern_dev(&devs, &mut last, d)).collect();
        assert_eq!(ix, vec![0, 0, 1, 0, 1, 1, 0]);
        assert_eq!(*devs.lock().unwrap(), vec![7, 9], "no duplicate table entries when the cache is bypassed");
    }

    #[test]
    fn table_overflow_maps_extra_devices_to_unknown_and_keeps_earlier_indexes_stable() {
        let (mut last, devs) = fresh();
        let first: Vec<u8> = (0..300u64).map(|d| intern_dev(&devs, &mut last, 1000 + d)).collect();
        assert!(first[..DEV_UNKNOWN as usize].iter().enumerate().all(|(i, &x)| x as usize == i), "first 255 get 0..=254");
        assert!(first[DEV_UNKNOWN as usize..].iter().all(|&x| x == DEV_UNKNOWN), "the rest are unknown, never a wrapped or shared index");
        assert_eq!(devs.lock().unwrap().len(), DEV_UNKNOWN as usize);
        // Asking again returns the same answers: known devs keep their index, overflowed devs stay unknown (and are never cached as a valid index).
        let again: Vec<u8> = (0..300u64).map(|d| intern_dev(&devs, &mut last, 1000 + d)).collect();
        assert_eq!(first, again);
        assert_eq!(devs.lock().unwrap().len(), DEV_UNKNOWN as usize);
    }

    #[test]
    fn concurrent_per_directory_interning_gives_one_index_per_device() {
        let devs = Mutex::new(Vec::<u64>::new());
        let results: Vec<Vec<(u64, u8)>> = std::thread::scope(|sc| {
            let hs: Vec<_> = (0..8u64).map(|t| { let devs = &devs; sc.spawn(move || {
                let mut last = (0u64, DEV_UNKNOWN); let mut out = Vec::new();
                for round in 0..200u64 { let d = 500 + (round * (t + 3)) % 50; out.push((d, intern_dev(devs, &mut last, d))); }
                out }) }).collect();
            hs.into_iter().map(|h| h.join().unwrap()).collect()
        });
        let table = devs.lock().unwrap().clone();
        let mut sorted = table.clone(); sorted.sort_unstable(); sorted.dedup();
        assert_eq!(sorted.len(), table.len(), "duplicate device in the shared table");
        for r in &results { for &(d, ix) in r { assert_eq!(table[ix as usize], d, "an index must always map back to its own device"); } }
    }
}
