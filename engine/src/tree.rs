use crate::category::{Category, CATEGORY_COUNT};
use arc_swap::ArcSwap;
#[cfg(feature = "failpoints")]
use std::sync::atomic::AtomicU8;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// Immutable per-node cumulative sizes plus the version they belong to. Published whole by one pointer swap.
/// The version lives inside the table, so a reader that captured a table has a size array and a version that
/// can never disagree.
pub struct SizeTable {
    pub version: u64,
    pub sizes: Vec<u64>,
}

/// Number of SizeTable values currently alive (current, retired-but-pinned, and under construction). Test support.
static LIVE_TABLES: AtomicUsize = AtomicUsize::new(0);
/// Worst-case bytes reserved by running captures across ALL trees (each capture counts one full table).
static RESERVED_BYTES: AtomicUsize = AtomicUsize::new(0);
/// Hard ceiling on simultaneously running captures per tree.
pub const MAX_RUNNING_CAPTURES: usize = 64;
/// Budget for old tables pinned by running captures, shared by every tree in the process (a rescan keeps the old
/// tree alive next to the new one, so the budget is global, not per tree).
pub const PINNED_TABLE_BUDGET_BYTES: usize = 256 << 20;

/// Per-tree cap: budget / table bytes, clamped to 1..=64. At 5M nodes (40 MB) it is 6, at 1M it is 33, at 100k 64.
pub fn admission_cap(n: usize) -> usize {
    (PINNED_TABLE_BUDGET_BYTES / (n.max(1) * 8)).clamp(1, MAX_RUNNING_CAPTURES)
}

impl SizeTable {
    fn new(version: u64, sizes: Vec<u64>) -> SizeTable {
        LIVE_TABLES.fetch_add(1, Ordering::Relaxed);
        SizeTable { version, sizes }
    }
}
impl Default for SizeTable {
    fn default() -> SizeTable { SizeTable::new(0, Vec::new()) }
}
impl Drop for SizeTable {
    fn drop(&mut self) { LIVE_TABLES.fetch_sub(1, Ordering::Relaxed); }
}

pub fn live_tables() -> usize { LIVE_TABLES.load(Ordering::Relaxed) }
pub fn reserved_bytes() -> usize { RESERVED_BYTES.load(Ordering::Relaxed) }

/// A captured table plus an admission slot, released when dropped. One per running call.
pub struct Captured<'a> {
    pub table: Arc<SizeTable>,
    tree: &'a Tree,
    bytes: usize,
}
impl Drop for Captured<'_> {
    fn drop(&mut self) {
        self.tree.running.fetch_sub(1, Ordering::AcqRel);
        RESERVED_BYTES.fetch_sub(self.bytes, Ordering::AcqRel);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MutationError {
    /// Id outside the tree.
    Invalid,
    /// The new table could not be allocated. Tree unchanged.
    AllocFailed,
    /// A panic happened before the swap. Tree unchanged.
    Panicked,
}

/// Test-only failure injection (feature `failpoints`): 1 = after reserve, 2 = after apply, 3 = immediately before the swap.
#[cfg(feature = "failpoints")]
static FAILPOINT: AtomicU8 = AtomicU8::new(0);
#[cfg(feature = "failpoints")]
pub fn set_failpoint(n: u8) { FAILPOINT.store(n, Ordering::SeqCst); }
#[cfg(feature = "failpoints")]
fn failpoint(n: u8) {
    if FAILPOINT.load(Ordering::Relaxed) == n { FAILPOINT.store(0, Ordering::SeqCst); panic!("injected failpoint {n}"); }
}
/// Failpoint 9: a panic inside an FFI entry body (used by the shipped-profile example).
#[cfg(feature = "failpoints")]
pub fn ffi_failpoint() { failpoint(9) }
#[cfg(not(feature = "failpoints"))]
pub fn ffi_failpoint() {}
#[cfg(not(feature = "failpoints"))]
#[inline(always)]
fn failpoint(_n: u8) {}


pub type NodeId = u32;
pub const NO_NODE: NodeId = u32::MAX;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File = 0,
    Directory = 1,
    /// Application bundle (.app etc). Measured whole; the treemap does not descend into it.
    Package = 2,
    Symlink = 3,
}

impl Kind {
    pub fn from_u8(v: u8) -> Kind {
        match v {
            1 => Kind::Directory,
            2 => Kind::Package,
            3 => Kind::Symlink,
            _ => Kind::File,
        }
    }
}

/// Structure-of-arrays arena. Children of a node are contiguous, sorted by size
/// descending, so `children(id)` is a slice range and layout never sorts.
#[derive(Default)]
pub struct Tree {
    pub(crate) names: Vec<Box<str>>,
    pub(crate) parent: Vec<NodeId>,
    pub(crate) kind: Vec<u8>,
    pub(crate) category: Vec<u8>,
    /// Cumulative allocated bytes (own bytes for files).
    /// Build-time staging only. `seal` moves it into the published table; nothing reads it afterwards.
    pub(crate) size: Vec<u64>,
    /// Current immutable size table. Replaced whole by `forget`.
    pub(crate) table: ArcSwap<SizeTable>,
    /// Serializes writers from capturing the current table through the swap.
    pub(crate) writer: Mutex<()>,
    /// Running captures on this tree.
    pub(crate) running: AtomicUsize,
    pub(crate) mtime: Vec<i64>,
    pub(crate) first_child: Vec<NodeId>,
    pub(crate) child_count: Vec<u32>,
    pub(crate) root_path: String,
    pub skipped: Vec<Skipped>,
    pub items: u64,
    pub cancelled: bool,
    /// Process-unique generation id, assigned when the tree is handed across the FFI. Filters and layouts are bound to it.
    pub uid: u64,
}

#[derive(Clone, Debug)]
pub struct Skipped {
    pub path: String,
    pub reason: SkipReason,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkipReason {
    PermissionDenied = 0,
    Unreadable = 1,
    SeparateVolume = 2,
    UserExcluded = 3,
}

impl Tree {
    pub fn len(&self) -> usize {
        self.names.len()
    }
    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }
    pub fn root(&self) -> NodeId {
        0
    }
    pub fn root_path(&self) -> &str {
        &self.root_path
    }
    pub fn name(&self, id: NodeId) -> &str {
        &self.names[id as usize]
    }
    pub fn mtime(&self, id: NodeId) -> i64 {
        self.mtime[id as usize]
    }
    pub fn size(&self, id: NodeId) -> u64 {
        self.table.load().sizes[id as usize]
    }
    pub fn kind(&self, id: NodeId) -> Kind {
        Kind::from_u8(self.kind[id as usize])
    }
    pub fn category(&self, id: NodeId) -> Category {
        Category::from_u8(self.category[id as usize])
    }
    pub fn parent(&self, id: NodeId) -> Option<NodeId> {
        let p = self.parent[id as usize];
        (p != NO_NODE).then_some(p)
    }
    pub fn child_count(&self, id: NodeId) -> u32 {
        self.child_count[id as usize]
    }
    pub fn children(&self, id: NodeId) -> std::ops::Range<NodeId> {
        let f = self.first_child[id as usize];
        if f == NO_NODE {
            0..0
        } else {
            f..f + self.child_count[id as usize]
        }
    }

    /// Absolute path of a node.
    pub fn path(&self, id: NodeId) -> String {
        let mut parts: Vec<&str> = Vec::new();
        let mut cur = id;
        while let Some(p) = self.parent(cur) {
            parts.push(self.name(cur));
            cur = p;
        }
        let mut out = self.root_path.clone();
        for p in parts.iter().rev() {
            if !out.ends_with('/') {
                out.push('/');
            }
            out.push_str(p);
        }
        out
    }

    /// Resolve an absolute path back to a node, if it lies under the scanned root.
    pub fn find(&self, path: &str) -> Option<NodeId> {
        let rest = path.strip_prefix(self.root_path.trim_end_matches('/'))?;
        let mut cur = self.root();
        for comp in rest.split('/').filter(|c| !c.is_empty()) {
            cur = self.children(cur).find(|&c| self.name(c) == comp)?;
        }
        Some(cur)
    }

    /// Bytes and item counts per category over the whole tree (files only).
    pub fn category_totals(&self) -> [(u64, u64); CATEGORY_COUNT] {
        self.category_totals_in(&self.table())
    }
    pub fn category_totals_in(&self, tab: &SizeTable) -> [(u64, u64); CATEGORY_COUNT] {
        let mut out = [(0u64, 0u64); CATEGORY_COUNT];
        for i in 0..self.len() {
            let k = self.kind[i];
            if k == Kind::Directory as u8 {
                continue;
            }
            // Packages are aggregated by the whole bundle's size; their inner files are
            // not separate nodes at this level when the package is collapsed.
            let c = self.category[i] as usize;
            out[c].0 += self.own_bytes_in(&tab.sizes, i as NodeId);
            out[c].1 += 1;
        }
        out
    }

    /// Bytes owned directly by this node (cumulative minus children).
    pub fn own_bytes(&self, id: NodeId) -> u64 {
        self.own_bytes_in(&self.table.load().sizes, id)
    }

    /// Same, against a table the caller already captured (hot loops capture once per call).
    pub fn own_bytes_in(&self, sizes: &[u64], id: NodeId) -> u64 {
        let r = self.children(id);
        if r.is_empty() {
            return sizes[id as usize];
        }
        let kids: u64 = r.map(|c| sizes[c as usize]).sum();
        sizes[id as usize].saturating_sub(kids)
    }

    /// Current table, uncapped (tests, internal one-shot reads).
    pub fn table(&self) -> Arc<SizeTable> { self.table.load_full() }

    /// Running captures on this tree.
    pub fn running(&self) -> usize { self.running.load(Ordering::Relaxed) }

    /// Capture the current table under the admission policy. Never waits: refused (None = BUSY) when this tree is at
    /// its cap, or when the process-wide reserved bytes would pass the budget. A tree's first capture is always
    /// admitted (floor of one), so a single table larger than the budget is still served, alone: the policy for
    /// oversize trees is one running capture per tree, never zero.
    pub fn capture(&self) -> Option<Captured<'_>> {
        let bytes = self.len().max(1).saturating_mul(8);
        let prev = self.running.fetch_add(1, Ordering::AcqRel);
        if prev >= admission_cap(self.len()) {
            self.running.fetch_sub(1, Ordering::AcqRel);
            return None;
        }
        // Atomic reservation: a compare-exchange loop, overflow safe. A tree's first capture (prev == 0) is exempt from
        // the budget, so reserved bytes can reach the budget PLUS one exempt table for every tree that has a running call. Tables a writer is building, and old tables pinned by legacy (uncapped) readers, are outside this counter. It is a counter for status-API callers, not an application memory bound.
        let mut cur = RESERVED_BYTES.load(Ordering::Acquire);
        loop {
            let next = cur.saturating_add(bytes);
            if prev > 0 && next > PINNED_TABLE_BUDGET_BYTES {
                self.running.fetch_sub(1, Ordering::AcqRel);
                return None;
            }
            match RESERVED_BYTES.compare_exchange_weak(cur, next, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => break,
                Err(seen) => cur = seen,
            }
        }
        Some(Captured { table: self.table.load_full(), tree: self, bytes })
    }

    /// Move build-time sizes into the published table. Called once when a tree is complete.
    pub(crate) fn seal(mut self) -> Tree {
        let v = std::mem::take(&mut self.size);
        self.table.store(Arc::new(SizeTable::new(0, v)));
        self
    }

    /// The `n` largest regular files, largest first.
    pub fn largest_files(&self, n: usize) -> Vec<NodeId> {
        self.largest_files_in(&self.table(), n)
    }
    pub fn largest_files_in(&self, tab: &SizeTable, n: usize) -> Vec<NodeId> {
        let sizes = &tab.sizes;
        let mut v: Vec<NodeId> = (0..self.len() as NodeId)
            .filter(|&i| self.kind[i as usize] == Kind::File as u8)
            .collect();
        let n = n.min(v.len());
        if n == 0 {
            return vec![];
        }
        v.select_nth_unstable_by_key(n - 1, |&i| std::cmp::Reverse(sizes[i as usize]));
        v.truncate(n);
        v.sort_by_key(|&i| std::cmp::Reverse(sizes[i as usize]));
        v
    }

    /// Remove a subtree from the result (after a move to Trash) and fix ancestor totals.
    /// The node stays in the arena with size 0. Returns the table version after the change.
    ///
    /// One writer at a time, from capturing the current table through the swap. All fallible or panicking work
    /// (reserve, copy, apply, building the new table value) happens before the swap, on a private copy. The swap is a
    /// single pointer store and nothing fallible follows it, so a failure leaves the published table untouched.
    pub fn forget(&self, id: NodeId) -> Result<u64, MutationError> {
        let guard = self.writer.lock().unwrap_or_else(|e| e.into_inner());
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.prepare_forget(id)));
        let out = match r {
            Ok(Ok(Some(next))) => {
                let v = next.version;
                self.table.store(next);
                Ok(v)
            }
            Ok(Ok(None)) => Ok(self.table.load().version),
            Ok(Err(e)) => Err(e),
            Err(_) => Err(MutationError::Panicked),
        };
        drop(guard);
        out
    }

    /// Builds the replacement table. `Ok(None)` means nothing to change.
    fn prepare_forget(&self, id: NodeId) -> Result<Option<Arc<SizeTable>>, MutationError> {
        let cur = self.table.load_full();
        if id as usize >= cur.sizes.len() { return Err(MutationError::Invalid); }
        let removed = cur.sizes[id as usize];
        if removed == 0 && self.kind[id as usize] == Kind::Directory as u8 { return Ok(None); }
        let mut copy: Vec<u64> = Vec::new();
        copy.try_reserve_exact(cur.sizes.len()).map_err(|_| MutationError::AllocFailed)?;
        failpoint(1);
        copy.extend_from_slice(&cur.sizes);
        self.apply_forget(&mut copy, id, removed);
        failpoint(2);
        let next = Arc::new(SizeTable::new(cur.version + 1, copy));
        failpoint(3);
        Ok(Some(next))
    }

    /// Zero the subtree and subtract from ancestors, without allocating: a pre-order walk using parent links.
    fn apply_forget(&self, sizes: &mut [u64], id: NodeId, removed: u64) {
        let mut n = id;
        loop {
            sizes[n as usize] = 0;
            let kids = self.children(n);
            if !kids.is_empty() {
                n = kids.start;
                continue;
            }
            // climb until a next sibling exists, never leaving the subtree rooted at `id`
            loop {
                if n == id { break; }
                let p = self.parent[n as usize];
                let sib = n + 1;
                if self.children(p).contains(&sib) { n = sib; break; }
                n = p;
            }
            if n == id { break; }
        }
        let mut cur = self.parent(id);
        while let Some(p) = cur {
            sizes[p as usize] = sizes[p as usize].saturating_sub(removed);
            cur = self.parent(p);
        }
    }
}

impl Tree {
    /// Deterministic synthetic tree with about `n` nodes for benchmarks and tests (not a scan).
    /// Every directory has up to 50 children, a fifth of which are directories.
    #[doc(hidden)]
    pub fn synthetic(n: usize) -> Tree {
        let mut t = Tree { root_path: "/synthetic".into(), ..Default::default() };
        let exts = ["swift", "rs", "png", "mov", "json", "txt", "zip", "so", "mp3", "pdf", "bin", "ttf"];
        let mut rng: u64 = 0x9E3779B97F4A7C15;
        let mut next = move || {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng
        };
        let push = |t: &mut Tree, name: String, parent: u32, kind: Kind, size: u64, mtime: i64| -> u32 {
            let id = t.names.len() as u32;
            let cat = if kind == Kind::Directory { Category::Folder as u8 } else { Category::classify(&name) as u8 };
            t.names.push(name.into());
            t.parent.push(parent);
            t.kind.push(kind as u8);
            t.category.push(cat);
            t.size.push(size);
            t.mtime.push(mtime);
            t.first_child.push(NO_NODE);
            t.child_count.push(0);
            id
        };
        push(&mut t, String::new(), NO_NODE, Kind::Directory, 0, 0);
        let mut cur = 0usize;
        while t.names.len() < n && cur < t.names.len() {
            if t.kind[cur] == Kind::Directory as u8 {
                let kids = 10 + (next() % 41) as u32;
                let first = t.names.len() as u32;
                for k in 0..kids {
                    if t.names.len() >= n {
                        break;
                    }
                    let r = next();
                    if r % 5 == 0 {
                        push(&mut t, format!("dir{}", k), cur as u32, Kind::Directory, 0, 1_600_000_000 + (r % 100_000_000) as i64);
                    } else {
                        let size = 4096 * (1 + (r >> 8) % 64) * if r % 97 == 0 { 2000 } else { 1 };
                        push(&mut t, format!("file{}_{}.{}", k, r % 1000, exts[(r >> 20) as usize % exts.len()]), cur as u32, Kind::File, size, 1_500_000_000 + (r % 200_000_000) as i64);
                    }
                }
                t.first_child[cur] = first;
                t.child_count[cur] = t.names.len() as u32 - first;
            }
            cur += 1;
        }
        // Roll sizes up (children after parents), then sort each directory's children by size.
        for i in (1..t.names.len()).rev() {
            let p = t.parent[i] as usize;
            t.size[p] += t.size[i];
        }
        t.items = t.names.len() as u64 - 1;
        t.seal()
    }
}
