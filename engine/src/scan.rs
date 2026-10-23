//! Parallel directory scanner.
//!
//! One thread-pool task per directory, work-stealing across subdirectories. Per-directory
//! enumeration is a backend: `getattrlistbulk(2)` on macOS (one syscall per batch of
//! entries, sizes included), `readdir` + `fstatat` elsewhere and as the macOS fallback.
//! Sizes are allocated bytes (st_blocks * 512 / ATTR_FILE_ALLOCSIZE). Hard-linked files
//! and directories reachable by two paths (firmlinks) are counted once.

use crate::category::Category;
use crate::events::{EventKind, PreviewEvents, ScanIdentity};
use crate::tree::{Kind, SkipReason, Skipped, Tree, NO_NODE};
use rayon::prelude::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
pub struct ScanOptions {
    /// Absolute paths whose subtrees are skipped entirely. Matching is textual against the walked paths, which
    /// start from the CANONICAL root, so a request is first rebased onto that basis: the scan root's own spelling
    /// resolves to the canonical root, and a symlinked ANCESTOR above the root (macOS /var -> /private/var,
    /// firmlinks, a user-made alias of the root itself) resolves the same way. Only a root-equivalent prefix - one
    /// whose canonical form IS the canonical root - is ever rewritten; the rest of the request is carried verbatim
    /// and no resolution below the root is ever APPLIED: a request spelled through a symlink ENTRY inside the tree
    /// names no scanned entry and excludes nothing (no silent broadening onto the entry's target). Requests that match nothing are reported in
    /// `Tree::unobserved_exclusions` with the request's original text.
    pub exclude: Vec<PathBuf>,
    /// Follow into other mounted volumes. Default false.
    pub cross_devices: bool,
    /// Force the portable readdir/stat backend (used to cross-check the bulk backend).
    pub force_portable: bool,
    /// Worker threads; 0 = rayon default (logical cores).
    pub threads: usize,
}

/// Shared, lock-free progress. Poll from any thread while `scan` runs.
/// CI-only rendezvous reached before the real walk cancellation check. Per-session, no globals.
/// 0 armed, 1 parked, 2 released, 3 expired. Expiry resumes the real walk and is never a pass.
#[cfg(feature = "ci-checks")]
pub struct CiScanGate {
    target: u64,
    visited: AtomicU64,
    state: std::sync::atomic::AtomicU8,
}
#[cfg(feature = "ci-checks")]
impl CiScanGate {
    pub fn new(target: u64) -> Self {
        Self { target: target.max(1), visited: AtomicU64::new(0), state: std::sync::atomic::AtomicU8::new(0) }
    }
    pub fn state(&self) -> u8 { self.state.load(Ordering::Acquire) }
    pub fn release(&self) {
        let _ = self.state.fetch_update(Ordering::AcqRel, Ordering::Acquire, |s| {
            if s <= 1 { Some(2) } else { None } // expiry is sticky, never laundered as released
        });
    }
    fn rendezvous(&self) {
        if self.visited.fetch_add(1, Ordering::Relaxed) + 1 != self.target { return; }
        // Release-before-arrival is respected, never overwritten by a late arrival.
        if self.state.compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire).is_err() { return; }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while self.state() == 1 {
            if std::time::Instant::now() >= deadline {
                let _ = self.state.compare_exchange(1, 3, Ordering::AcqRel, Ordering::Acquire);
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }
}

#[derive(Default)]
pub struct ScanProgress {
    #[cfg(feature = "ci-checks")]
    pub ci_gate: Option<Arc<CiScanGate>>,
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
    /// The kernel reported this directory as the root of a mounted filesystem (macOS `ATTR_DIR_MOUNTSTATUS`). Only the bulk backend sets it: `getattrlistbulk` can report the
    /// attributes of the filesystem a mount point covers, so a device compare alone may not see the boundary. The portable backend leaves it false (its `lstat` device is the mount's own).
    pub mount_point: bool,
}

/// A directory entry is a separate volume when its device differs from the scan root's, or when the kernel says it is a mount point. Pure so it is unit tested everywhere.
pub(crate) fn is_separate_volume(dev: u64, mount_point: bool, root_dev: u64, cross_devices: bool) -> bool {
    !cross_devices && (dev != root_dev || mount_point)
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
    events: Option<&'a PreviewEvents>,
    #[allow(dead_code)]
    bulk: bool,
    /// Test-only: runs once per walk right after the pre-walk identity capture, so
    /// tests can swap the directory mid-walk deterministically. Absent in release.
    /// A borrowed closure (not a fn pointer) so each test carries its OWN arming
    /// state - a process-global flag let parallel tests disarm each other (R2).
    #[cfg(test)]
    mid_walk_hook: Option<&'a (dyn Fn(&Path) + Sync + 'a)>,
}

/// Stack for each walker thread. Linux PATH_MAX (4096) bounds depth near 2000 one-letter levels; this leaves roughly 30x headroom on that.
const WALK_STACK_BYTES: usize = 64 << 20;

pub fn scan(root: &Path, opts: &ScanOptions, progress: &ScanProgress) -> std::io::Result<Tree> {
    // Fail closed: every path the tree builds is root + node names, and the root is stored as text. A root that is not valid UTF-8 would be stored lossily
    // and every later removal/reveal path would point somewhere else (or nowhere).
    let given = root;
    let root = &root.canonicalize()?;
    if root.to_str().is_none() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "scan root path is not valid UTF-8"));
    }
    scan_inner(root, opts, progress, None, #[cfg(test)] None, given)
}

/// `scan` plus progressive preview events. Events are best-effort extras bound to the sink's
/// generation and canonical root, carried with byte-exact paths. Errors when the sink was
/// built for a different root.
///
/// Root policy differs from `scan` BY CONTRACT: this entry does not refuse a non-UTF-8
/// root, because the measurement pipeline binds and compares raw path bytes. The returned
/// Tree still stores its root as lossy text, so for a non-UTF-8 root its derived paths
/// (removal/reveal/rescan) would point nowhere or at a colliding lossy sibling: such a
/// Tree is measurement-only and must never feed a mutation or navigation path. `scan`
/// (the app's entry) keeps the fail-closed refusal, so no app Tree can carry a lossy root.
pub fn scan_with_events(
    root: &Path,
    opts: &ScanOptions,
    progress: &ScanProgress,
    events: &PreviewEvents,
) -> std::io::Result<Tree> {
    scan_inner(root, opts, progress, Some(events), #[cfg(test)] None, root)
}

/// Test-only: like `scan_with_events` with a mid-walk hook installed, so tests can
/// change a directory's identity during the walk deterministically.
#[cfg(test)]
pub(crate) fn scan_with_events_hook(
    root: &Path,
    opts: &ScanOptions,
    progress: &ScanProgress,
    events: &PreviewEvents,
    hook: &(dyn Fn(&Path) + Sync),
) -> std::io::Result<Tree> {
    scan_inner(root, opts, progress, Some(events), Some(hook), root)
}

fn scan_inner(
    root: &Path,
    opts: &ScanOptions,
    progress: &ScanProgress,
    events: Option<&PreviewEvents>,
    #[cfg(test)] mid_walk_hook: Option<&(dyn Fn(&Path) + Sync)>,
    root_given: &Path,
) -> std::io::Result<Tree> {
    let root = root.canonicalize()?;
    // Rebase the exclusion requests onto the walk basis (see ScanOptions::exclude). The walk starts from the
    // canonical root and matches exclusions textually; without this, a request spelled through the caller's own
    // (legitimate) symlinked spelling of the root - macOS /var -> /private/var is the standing case - would
    // match nothing and the subtree the user asked to skip would stay in the tree. `excl_display` below keeps
    // the original request text, so an unmatched request is reported the way the caller wrote it.
    let rebased_exclude = rebase_exclusions(root_given, &root, &opts.exclude);
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
        root_ino: md.ino(),
        devs: Mutex::new(Vec::new()),
        skipped: Mutex::new(Vec::new()),
        excl_hit: opts.exclude.iter().map(|_| AtomicBool::new(false)).collect(),
        excl_display: opts.exclude.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
        exclude: rebased_exclude
            .iter()
            // An exclusion that is not valid UTF-8 can only name a non-UTF-8 entry, which the walk already leaves out, so it is never matchable (None); a lossy
            // form could overmatch a real U+FFFD-named sibling. It stays in the list so it is REPORTED as unmatched rather than silently vanishing.
            .map(|p| p.to_str().map(|p| p.trim_end_matches('/').to_string()))
            .collect(),
        events,
        bulk: cfg!(target_os = "macos") && !opts.force_portable,
        excl_by_parent: Default::default(),
        #[cfg(test)]
        mid_walk_hook,
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
    let (node, complete, previews_complete) = pool.build().map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?.install(run);

    let tree = flatten(root.to_string_lossy().into_owned(), node, ctx, progress);
    if let Some(ev) = events {
        // Root completeness (under the scanner's accounting) rides the terminal: a
        // suppressed subtree leaves previews provisional even when the scan was
        // neither cancelled nor lossy.
        ev.finish(tree.cancelled, complete, previews_complete);
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
/// Rebase exclusion requests onto the canonical-root basis the walk matches against. A request that IS the root
/// or sits under it, spelled the way the caller spelled the root (macOS /var/... while the canonical root is
/// /private/var/...), is rewritten onto the canonical root textually. The rewrite stops at the root-equivalent
/// prefix - no symlink resolution below the root is ever applied - so a request through a symlink ENTRY inside
/// the tree still names nothing (its target must NOT be excluded in its place - no silent broadening). A request spelled some other way entirely gets one
/// chance through `rebase_through_root`. Non-UTF-8 requests are returned unchanged (the Ctx maps them to
/// unmatchable None, reported NotMatchable).
fn rebase_exclusions(root_given: &Path, root_canonical: &Path, exclude: &[PathBuf]) -> Vec<PathBuf> {
    let given = root_given.to_string_lossy().trim_end_matches('/').to_string();
    let can_full = root_canonical.to_string_lossy().into_owned();
    // Join basis with NO trailing separator of its own: the canonical root "/" trims to "", so joining
    // "<can>/<rest>" yields "/Library", never "//Library" (a double separator matches no walked path and would
    // silently drop the exclusion - run 39668574065: firmlink test scanned all of /System, "dir nodes: 3").
    let can = can_full.trim_end_matches('/');
    exclude
        .iter()
        .map(|p| {
            let Some(raw) = p.to_str() else { return p.clone() };
            let trimmed = raw.trim_end_matches('/');
            if trimmed == given {
                // The root itself: keep the canonical root's exact spelling ("/" stays "/").
                PathBuf::from(&can_full)
            } else if let Some(rest) = trimmed.strip_prefix(&format!("{given}/")) {
                PathBuf::from(format!("{can}/{rest}"))
            } else {
                PathBuf::from(rebase_through_root(trimmed, &can_full))
            }
        })
        .collect()
}

/// A request spelled differently from the scan root can still name a directory inside the scanned tree through
/// a symlinked ANCESTOR above the root (macOS /var -> /private/var, a firmlink, an alias of the root's parent).
/// Candidate prefixes are canonicalized while searching, but the rewrite applies ONLY to the longest
/// root-equivalent prefix (one whose canonical form is exactly the canonical root); every component after it is
/// carried verbatim and no deeper resolution is ever applied - applying one could silently broaden the request
/// onto the target of a symlink that is a scanned ENTRY inside the tree. Anything that never reaches the root is
/// returned unchanged, as before.
fn rebase_through_root(e: &str, root_can: &str) -> String {
    let mut best: Option<usize> = None; // byte length of the longest prefix whose canonical form is the root
    for (i, ch) in e.char_indices() {
        if ch != '/' || i == 0 {
            continue;
        }
        if let Ok(c) = std::fs::canonicalize(&e[..i]) {
            if c.to_string_lossy() == root_can {
                best = Some(i);
            }
        }
    }
    if best.is_none() {
        if let Ok(c) = std::fs::canonicalize(e) {
            if c.to_string_lossy() == root_can {
                return root_can.to_string();
            }
        }
    }
    match best {
        // Same single-separator rule: root_can "/" + rest "/sub" must yield "/sub", never "//sub".
        Some(i) => format!("{}{}", root_can.trim_end_matches('/'), &e[i..]),
        None => e.to_string(),
    }
}

/// The walk looks exclusions up by the CURRENT directory's string; the index keys each request by its parent path.
/// A request directly under "/" (e.g. "/tmp") is keyed under "" (its parent spelling from rfind), so the root
/// directory's lookup key must be "" too - using "/" there would never match (previously untested, known-gaps doc).
fn excl_lookup_key(dir: &str) -> &str {
    if dir == "/" { "" } else { dir }
}

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

/// Post-walk identity gate over the FULL captured identity (dev, ino, ctime, and
/// birthtime where available), compared by value: a mid-walk swap or metadata change
/// suppresses the preview record. The ctime/birthtime components are part of the
/// contract, not just dev/ino.
fn walk_identity_intact(pre: Option<ScanIdentity>, post: Option<ScanIdentity>) -> bool {
    pre.is_some() && pre == post
}

/// Returns the node, whether the subtree completed under the scanner's accounting,
/// and whether every eligible preview event was emitted with an intact identity
/// (false when a mid-walk identity change suppressed this directory's record or any
/// descendant's). Tree accounting is unaffected by the third flag.
fn walk(dir: &Path, ctx: &Ctx) -> (DirNode, bool, bool) {
    // Pre-walk identity binding: the preview record carries the FULL identity of the
    // directory ACTUALLY traversed (dev, ino, ctime, birthtime where available),
    // captured at walk start - not the parent's earlier enumeration. If the directory
    // was swapped between enumeration and this walk, the record simply describes the
    // directory that was walked; if it changes mid-walk, the post-walk gate below
    // suppresses the record. Captured ONLY for event-enabled scans: a plain scan
    // pays zero extra stats.
    let pre = ctx.events.and_then(|_| ScanIdentity::live(dir));
    #[cfg(test)]
    if let Some(h) = ctx.mid_walk_hook {
        h(dir);
    }
    ctx.progress.note_dir();
    #[cfg(feature = "ci-checks")]
    if let Some(gate) = &ctx.progress.ci_gate { gate.rendezvous(); }
    if ctx.progress.cancel.load(Ordering::Relaxed) {
        return (DirNode { ents: vec![], total: 0 }, false, true);
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
            return (DirNode { ents: vec![], total: 0 }, false, true);
        }
    };

    let mut ents: Vec<Ent> = Vec::with_capacity(raw.len());
    let mut subdirs: Vec<(usize, PathBuf)> = Vec::new();
    let mut local_bytes = 0u64;
    let mut last_dev: (u64, u8) = (0, crate::tree::DEV_UNKNOWN);
    // Entry-level accounting failures (non-UTF-8 or failed entries) dirty completeness the same
    // way a failed directory enumeration does: those bytes are in no total, so the directory is
    // not "complete under the scanner's accounting" and no final preview record may claim it.
    let mut entries_complete = true;
    let dir_excl: Option<&Vec<(Box<str>, usize)>> = if ctx.excl_by_parent.is_empty() { None } else {
        dir.to_str().and_then(|d| ctx.excl_by_parent.get(excl_lookup_key(d)))
    };
    for r in raw {
        if r.name_lossy {
            // Fail closed: a node must never carry a name that can alias a sibling or point at a different real entry (removal/reveal/rescan build
            // paths from names). Left out of the tree and listed as unreadable with the lossy flag; its bytes are NOT in any total.
            ctx.skipped.lock().unwrap().push(Skipped::with_lossy(&dir.join(&*r.name), SkipReason::Unreadable, true));
            entries_complete = false;
            continue;
        }
        if r.failed != 0 {
            // Empty name = the iterator failed for this directory: the skipped path is the directory itself.
            let path = if r.name.is_empty() { dir.to_path_buf() } else { dir.join(&*r.name) };
            ctx.skipped.lock().unwrap().push(Skipped::new(&path, if r.failed == 1 { SkipReason::PermissionDenied } else { SkipReason::Unreadable }));
            entries_complete = false;
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
                if is_separate_volume(r.dev, r.mount_point, ctx.root_dev, ctx.opts.cross_devices) {
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

    let results: Vec<(usize, (DirNode, bool, bool))> = if subdirs.len() > 1 {
        subdirs
            .par_iter()
            .map(|(i, p)| {
                crate::tree::worker_failpoint();
                (*i, walk(p, ctx))
            })
            .collect()
    } else {
        subdirs.iter().map(|(i, p)| (*i, walk(p, ctx))).collect()
    };
    let mut total = local_bytes;
    let mut complete = entries_complete;
    let mut previews_complete = true;
    for (i, (node, child_complete, child_previews)) in results {
        total += node.total;
        ents[i].size = node.total;
        ents[i].dir = Some(Box::new(node));
        complete &= child_complete;
        previews_complete &= child_previews;
    }
    if complete {
        if let Some(ev) = ctx.events {
            // Post-walk gate over the full identity: emit only when the traversed
            // directory survived the walk unchanged. A mid-walk swap or metadata
            // change suppresses the record and marks the preview stream incomplete
            // (propagated to the terminal); the Tree above already accounted the
            // bytes as walked.
            if walk_identity_intact(pre, ScanIdentity::live(dir)) {
                ev.emit(EventKind::DirComplete {
                    path: dir.to_path_buf(),
                    size: total,
                    id: pre.unwrap(),
                });
            } else {
                previews_complete = false;
            }
        }
    }
    (DirNode { ents, total }, complete, previews_complete)
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
        kind: Kind::File, alloc: 0, nlink: 1, dev: 0, ino: 0, mtime: 0, mount_point: false,
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
            mount_point: false,
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

#[cfg(test)]
mod volume_boundary_tests {
    use super::is_separate_volume;

    #[test]
    fn a_mount_point_is_a_separate_volume_even_when_its_reported_device_equals_the_roots() {
        // The old rule was `dev != root_dev`; it cannot see this case, which is the suspected RAM-disk miss.
        let old_rule = |dev: u64, root: u64| dev != root;
        assert!(!old_rule(5, 5));
        assert!(is_separate_volume(5, true, 5, false));
    }

    #[test]
    fn device_difference_still_separates_and_cross_devices_still_overrides_both() {
        assert!(is_separate_volume(6, false, 5, false));
        assert!(!is_separate_volume(5, false, 5, false));
        assert!(!is_separate_volume(6, false, 5, true));
        assert!(!is_separate_volume(5, true, 5, true));
    }
}

/// Test-only: one-shot arming against PER-TEST state. True exactly once per flag.
/// No process-global state: parallel tests each hold their own flag and cannot
/// disarm one another (the R2 flake).
#[cfg(test)]
pub(crate) fn armed_once(flag: &std::sync::atomic::AtomicBool) -> bool {
    !flag.swap(true, std::sync::atomic::Ordering::SeqCst)
}

/// Test-only mid-walk effect: replace the walked directory with a different identity
/// at the same path, exactly once per `flag` (mkdir aside first, then rename over -
/// no inode-recycling race). Tests install it as `move |d| swap_dir_once(d, &flag)`.
#[cfg(test)]
pub(crate) fn swap_dir_once(dir: &Path, flag: &std::sync::atomic::AtomicBool) {
    if !armed_once(flag) {
        return;
    }
    let staging = dir.with_file_name(format!("{}-staging", dir.file_name().unwrap().to_string_lossy()));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).unwrap();
    std::fs::write(staging.join("g"), vec![1u8; 8192]).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    std::fs::rename(&staging, dir).unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn ctx_for<'a>(opts: &'a ScanOptions, progress: &'a ScanProgress, events: &'a PreviewEvents, root_dev: u64) -> Ctx<'a> {
        Ctx {
            opts,
            progress,
            files: Seen::new(),
            dirs: Seen::new(),
            root_dev,
            root_ino: 0,
            devs: Mutex::new(Vec::new()),
            skipped: Mutex::new(Vec::new()),
            exclude: Vec::new(),
            events: Some(events),
            excl_hit: Vec::new(),
            excl_display: Vec::new(),
            excl_by_parent: Default::default(),
            bulk: false,
            mid_walk_hook: None,
        }
    }

    fn fixture(tag: &str, bytes: usize) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("spz-walk-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("f"), vec![1u8; bytes]).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn walk_identity_gate_compares_full_identity() {
        let a = ScanIdentity { dev: 1, ino: 2, ctime: 10, ctime_nsec: 5, birthtime: Some((9, 1)) };
        assert!(walk_identity_intact(Some(a), Some(a)));
        assert!(!walk_identity_intact(Some(a), None));
        assert!(!walk_identity_intact(None, Some(a)));
        let mut b = a;
        b.ctime = 11;
        assert!(!walk_identity_intact(Some(a), Some(b)), "ctime is part of the gate");
        let mut c = a;
        c.birthtime = Some((9, 2));
        assert!(!walk_identity_intact(Some(a), Some(c)), "birthtime is part of the gate");
        let mut d = a;
        d.ino = 3;
        assert!(!walk_identity_intact(Some(a), Some(d)), "ino is part of the gate");
    }

    #[test]
    fn walk_emits_preview_record_with_traversed_identity() {
        // The record carries the walked directory's own live identity.
        let dir = fixture("ok", 2048);
        let want = ScanIdentity::live(&dir).unwrap();
        let opts = ScanOptions::default();
        let progress = ScanProgress::default();
        let (events, rx) = PreviewEvents::new(1, &dir);
        let ctx = ctx_for(&opts, &progress, &events, want.dev);
        let (_node, complete, previews) = walk(&dir, &ctx);
        assert!(complete && previews);
        let ev = rx.recv_timeout(std::time::Duration::from_millis(100)).expect("record emitted");
        match ev.kind {
            EventKind::DirComplete { id, .. } => assert_eq!(id, want),
            other => panic!("unexpected event: {other:?}"),
        }
        events.finish(false, true, true);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hook_arming_is_per_state_not_global() {
        // Regression pin for the R2 process-global flake: independent flags must not
        // share firing state - firing one leaves the other armed.
        let a = std::sync::atomic::AtomicBool::new(false);
        let b = std::sync::atomic::AtomicBool::new(false);
        assert!(armed_once(&a), "first use of state A fires");
        assert!(armed_once(&b), "independent state B still fires - a global would have consumed it");
        assert!(!armed_once(&a), "state A is consumed");
        assert!(armed_once(&b) == false, "state B is consumed");
    }

    #[test]
    fn walk_suppresses_record_marks_previews_incomplete_when_identity_changes_mid_walk() {
        let swapped = std::sync::atomic::AtomicBool::new(false);
        let hook = |d: &Path| swap_dir_once(d, &swapped);
        let dir = fixture("swap", 2048);
        let want = ScanIdentity::live(&dir).unwrap();
        let opts = ScanOptions::default();
        let progress = ScanProgress::default();
        let (events, rx) = PreviewEvents::new(1, &dir);
        let mut ctx = ctx_for(&opts, &progress, &events, want.dev);
        ctx.mid_walk_hook = Some(&hook);
        let (node, complete, previews) = walk(&dir, &ctx);
        assert!(complete, "walk completed on the swapped-in directory");
        assert!(!previews, "suppressed record must mark previews incomplete");
        assert!(node.total >= 8192, "bytes accounted as walked: {}", node.total);
        assert!(
            rx.recv_timeout(std::time::Duration::from_millis(100)).is_none(),
            "mid-walk identity change must suppress the preview record"
        );
        events.finish(false, true, false);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn plain_scan_walk_captures_no_identity() {
        // Event-disabled scans pay zero preview stats: pre is None, no event path runs.
        let dir = fixture("plain", 1024);
        let opts = ScanOptions::default();
        let progress = ScanProgress::default();
        let ctx = Ctx {
            opts: &opts,
            progress: &progress,
            files: Seen::new(),
            dirs: Seen::new(),
            root_dev: 0,
            root_ino: 0,
            devs: Mutex::new(Vec::new()),
            skipped: Mutex::new(Vec::new()),
            exclude: Vec::new(),
            events: None,
            excl_hit: Vec::new(),
            excl_display: Vec::new(),
            excl_by_parent: Default::default(),
            bulk: false,
            mid_walk_hook: None,
        };
        let (node, complete, previews) = walk(&dir, &ctx);
        assert!(complete && previews);
        assert!(node.total >= 1024);
        let _ = fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod exclusion_rebase_tests {
    //! Path-boundary battery for the exclusion rebase. The pinned contracts: single separators ALWAYS (a doubled
    //! "/" matches no walked path and silently drops the exclusion - run 39668574065, firmlink "dir nodes: 3");
    //! only a root-equivalent prefix is ever rewritten; below-root components are carried verbatim (no broadening
    //! onto a symlinked entry's target); non-UTF-8 requests pass through untouched for the NotMatchable mapping.
    use super::*;
    use std::path::PathBuf;

    fn rebased(root_given: &str, root_canonical: &str, exclusions: &[&str]) -> Vec<String> {
        let ex: Vec<PathBuf> = exclusions.iter().map(PathBuf::from).collect();
        rebase_exclusions(Path::new(root_given), Path::new(root_canonical), &ex)
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect()
    }

    fn sandbox(tag: &str) -> PathBuf {
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("spz-rebase-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    #[test]
    fn an_exclusion_directly_under_the_scan_root_matches_at_the_root_directory() {
        // The known-gaps untested case: scan rooted at "/", request "/tmp". The index keys it under "" (parent
        // spelling from rfind); the root directory's lookup must use the same "" key or the exclusion never matches.
        let idx = build_exclusion_index(&[Some("/tmp".to_string()), Some("/tmp/x".to_string()), Some("/".to_string()), Some("relative".to_string())]);
        let root_hits = &idx[excl_lookup_key("/")];
        assert!(root_hits.iter().any(|(n, _)| &**n == "tmp"), "root-level request found at the root directory: {idx:?}");
        assert!(!root_hits.iter().any(|(n, _)| &**n == "x"), "a deeper request is NOT matched at the root");
        assert!(idx[excl_lookup_key("/tmp")].iter().any(|(n, _)| &**n == "x"), "the deeper request matches at its own parent");
        assert!(idx.values().flatten().all(|(n, _)| !n.is_empty()), "a bare / or relative request is unindexable (reported unobserved, never matched)");
    }

    #[test]
    fn root_slash_never_produces_double_slash_exclusions() {
        // The run-39668574065 repro: exclusions under "/" must keep their exact walked-path spelling.
        assert_eq!(
            rebased("/", "/", &["/System/Applications", "/Library", "/System"]),
            vec!["/System/Applications", "/Library", "/System"]
        );
    }

    #[test]
    fn exact_root_exclusion_keeps_the_canonical_spelling() {
        assert_eq!(rebased("/", "/", &["/"]), vec!["/"]);
        assert_eq!(rebased("/var/", "/private/var", &["/var"]), vec!["/private/var"]);
    }

    #[test]
    fn trailing_separators_are_ignored_on_root_and_exclusion() {
        assert_eq!(rebased("/var", "/private/var", &["/var/log/"]), vec!["/private/var/log"]);
        assert_eq!(rebased("/var/", "/private/var", &["/var/log"]), vec!["/private/var/log"]);
    }

    #[test]
    fn identity_root_spelling_is_preserved_verbatim() {
        assert_eq!(rebased("/tmp/xyz", "/tmp/xyz", &["/tmp/xyz/a/b"]), vec!["/tmp/xyz/a/b"]);
        // An absolute path under "/" is already on the canonical basis: unchanged, still single-slash.
        assert_eq!(rebased("/", "/", &["/nonexistent-xyz/deep"]), vec!["/nonexistent-xyz/deep"]);
    }

    #[test]
    fn exclusion_spelled_through_a_symlinked_ancestor_of_the_root_is_honored() {
        let base = sandbox("alias");
        let real = base.join("real");
        std::fs::create_dir_all(real.join("sub")).unwrap();
        std::os::unix::fs::symlink(&real, base.join("alias")).unwrap();
        let root_can = real.canonicalize().unwrap().to_string_lossy().into_owned();
        let ex = base.join("alias").join("sub").to_string_lossy().into_owned();
        assert_eq!(
            rebased(&base.join("other-given").to_string_lossy(), &root_can, &[&ex]),
            vec![format!("{root_can}/sub")]
        );
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn below_root_symlink_entry_is_never_resolved_onto_its_target() {
        let base = sandbox("entry");
        let real = base.join("real");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::create_dir_all(base.join("other")).unwrap();
        std::fs::write(base.join("other").join("f"), b"x").unwrap();
        std::os::unix::fs::symlink(base.join("other"), real.join("entry")).unwrap();
        let root = real.to_string_lossy().into_owned();
        let ex = format!("{root}/entry/f");
        // The walk lists `entry` as a symlink ENTRY; no scanned entry is named `entry/f`; the text must
        // come back with `entry` unresolved (no broadening onto base/other/f).
        assert_eq!(rebased(&root, &root, &[&ex]), vec![ex]);
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn root_equivalent_alias_of_slash_rebases_with_a_single_separator() {
        let base = sandbox("loop");
        std::os::unix::fs::symlink("/", base.join("loop")).unwrap();
        let ex = base.join("loop").join("sub").to_string_lossy().into_owned();
        // Direct rebase_through_root contract: "<alias>/sub" with canonical root "/" -> "/sub", never "//sub".
        assert_eq!(rebase_through_root(&ex, "/"), "/sub");
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn nonexistent_spellings_off_the_root_basis_come_back_unchanged() {
        let base = sandbox("nx");
        let real = base.join("real");
        std::fs::create_dir_all(&real).unwrap();
        let root = real.to_string_lossy().into_owned();
        let ex = base.join("never-existed").join("deep").to_string_lossy().into_owned();
        assert_eq!(rebased(&root, &root, &[&ex]), vec![ex]);
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn non_utf8_exclusions_pass_through_byte_identical() {
        use std::os::unix::ffi::OsStrExt;
        let raw = std::ffi::OsStr::from_bytes(b"/var/bad\xff");
        let ex = vec![PathBuf::from(raw)];
        let out = rebase_exclusions(Path::new("/var"), Path::new("/private/var"), &ex);
        assert_eq!(out[0].as_os_str().as_bytes(), b"/var/bad\xff");
    }
}

