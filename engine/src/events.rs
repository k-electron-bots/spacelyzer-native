//! Progressive scan events (milestone 2, index-accelerated early results: engine slice A).
//!
//! The authoritative result stays the `Tree` returned by `scan`. Events exist so an
//! "Early results - scanning" preview can be published while a scan runs:
//!
//! - Bounded channel: a full channel DROPS the event and counts it, so preview plumbing
//!   can never block the scan.
//! - `DirComplete` fires only for a directory whose ENTIRE subtree completed (a cancelled
//!   or unreadable child makes every ancestor incomplete), so an event never presents a
//!   partial subtree as final.
//! - The terminal `Finished` event never enters the channel. After the scan's workers
//!   are joined, the sink records it in a terminal slot and sets a done flag (Release);
//!   the receiver, on seeing the flag (Acquire), drains the queue first and only then
//!   yields the terminal, exactly once. All data sends happen-before done, so ordering
//!   is linearized: a full channel can lose data events but never the terminal, and no
//!   data event can arrive after it. It carries the cancel flag, the root-completeness
//!   flag, and the number of dropped data events.
//! - Every event carries the scan generation and the canonical root as a raw `PathBuf`
//!   (never a lossy UTF-8 string), and `scan_with_events` refuses a sink built for a
//!   different root.
//! - The collector is absorbing once finished, and a cancelled or lossy scan leaves every
//!   later snapshot `partial: true` forever: only the authoritative `Tree` ends
//!   provisionality, never the event stream.
//! - A sink is ONE-SHOT: `scan_with_events` claims it atomically before walking and
//!   refuses concurrent or sequential reuse. Without that, a second scan's sends would
//!   race the first scan's done flag, and a reused receiver could never yield another
//!   terminal.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Bounded so a slow preview consumer can never stall the scan.
pub const CHANNEL_BOUND: usize = 100;
/// Minimum spacing between preview publications.
pub const PREVIEW_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventKind {
    /// A directory whose ENTIRE subtree finished scanning; `size` is its final
    /// allocated-byte total. Directories with a cancelled, unreadable, or otherwise
    /// incomplete subtree emit nothing, and neither do their ancestors. `dev`/`ino`
    /// are the directory's volume and inode at scan time: consumers key preview
    /// records by identity, never by path alone.
    DirComplete { path: PathBuf, size: u64, dev: u64, ino: u64 },
    /// The scan ended. `cancelled` says whether it ended by cancellation; `complete`
    /// says the walk finished every directory it entered under the scanner's
    /// accounting (false on cancellation or an unreadable subtree; the portable
    /// enumerator can silently skip per-entry errors, so this is not a proof that
    /// every reachable byte was read); `dropped` is how many preview data events were
    /// lost to a full channel. Durable: see the module docs - this event never enters
    /// the channel and is delivered exactly once.
    Finished { cancelled: bool, complete: bool, dropped: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanEvent {
    pub generation: u64,
    /// Canonical root of the scan this event belongs to, as a raw path (no lossy
    /// UTF-8 conversion; non-UTF-8 roots round-trip exactly).
    pub root: PathBuf,
    pub kind: EventKind,
}

struct Shared {
    terminal: Mutex<Option<ScanEvent>>,
    /// Set (Release) after the terminal is recorded and all workers are joined; every
    /// data send happens-before this store.
    done: AtomicBool,
    /// Terminal handed out already: delivery is exactly once.
    taken: AtomicBool,
}

/// The scan side of the event channel. Share by reference; safe from worker threads.
pub struct PreviewEvents {
    tx: SyncSender<ScanEvent>,
    generation: u64,
    root: PathBuf,
    dropped: AtomicU64,
    /// One-shot claim: taken by `scan_with_events` before the walk starts.
    claimed: AtomicBool,
    shared: Arc<Shared>,
}

/// The consumer side. Drains queued events; once the queue is empty and the terminal
/// event was recorded, yields it exactly once, however full the channel was when the
/// scan finished.
pub struct PreviewReceiver {
    rx: Receiver<ScanEvent>,
    shared: Arc<Shared>,
}

impl PreviewReceiver {
    /// Next event, waiting up to `d`. Once the scan signals done, queued data events
    /// are drained first and the durable terminal event is yielded after them, exactly
    /// once; later calls return None.
    pub fn recv_timeout(&self, d: Duration) -> Option<ScanEvent> {
        let deadline = Instant::now() + d;
        loop {
            if self.shared.done.load(Ordering::Acquire) {
                // Every data send happened-before done: the queue can only shrink now.
                match self.rx.try_recv() {
                    Ok(ev) => return Some(ev),
                    Err(_) => {
                        if !self.shared.taken.swap(true, Ordering::AcqRel) {
                            return self.shared.terminal.lock().unwrap().clone();
                        }
                        return None;
                    }
                }
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.rx.recv_timeout(remaining) {
                Ok(ev) => return Some(ev),
                Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {
                    if !self.shared.done.load(Ordering::Acquire) {
                        return None;
                    }
                    // done landed during the wait: loop into the drain path.
                }
            }
        }
    }
}

impl PreviewEvents {
    /// `root` must be the canonical scan root; `scan_with_events` checks this and errors
    /// on a mismatch rather than emitting events bound to the wrong root.
    pub fn new(generation: u64, root: &Path) -> (Self, PreviewReceiver) {
        Self::with_bound(generation, root, CHANNEL_BOUND)
    }

    pub fn with_bound(generation: u64, root: &Path, bound: usize) -> (Self, PreviewReceiver) {
        let (tx, rx) = sync_channel(bound);
        let shared = Arc::new(Shared {
            terminal: Mutex::new(None),
            done: AtomicBool::new(false),
            taken: AtomicBool::new(false),
        });
        (
            PreviewEvents {
                tx,
                generation,
                root: root.to_path_buf(),
                dropped: AtomicU64::new(0),
                claimed: AtomicBool::new(false),
                shared: shared.clone(),
            },
            PreviewReceiver { rx, shared },
        )
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Events dropped because the channel was full. A disconnected receiver is not
    /// counted: the consumer going away (for example after a cancel) is normal.
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    /// True when this sink was built for `canonical_root` (already canonicalized).
    /// Raw-path comparison: non-UTF-8 roots are compared byte for byte.
    pub(crate) fn root_matches(&self, canonical_root: &Path) -> bool {
        self.root == canonical_root
    }

    /// One-shot claim for exactly one scan. False when this sink is already running a
    /// scan or finished one: concurrent sends would race the first scan's done flag,
    /// and the receiver's terminal is single-use by design.
    pub(crate) fn claim(&self) -> bool {
        self.claimed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub(crate) fn emit(&self, kind: EventKind) {
        self.send(ScanEvent {
            generation: self.generation,
            root: self.root.clone(),
            kind,
        });
    }

    fn send(&self, ev: ScanEvent) {
        match self.tx.try_send(ev) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => {}
            Err(TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// Terminal event: recorded in the durable slot, then the done flag is released.
    /// Called after all scan workers are joined, so every data send (and its possible
    /// drop) happened-before the flag; the dropped count is therefore stable here.
    /// The terminal itself never enters the channel: it cannot be dropped or doubled.
    pub(crate) fn finish(&self, cancelled: bool, complete: bool) {
        let ev = ScanEvent {
            generation: self.generation,
            root: self.root.clone(),
            kind: EventKind::Finished {
                cancelled,
                complete: complete && !cancelled,
                dropped: self.dropped(),
            },
        };
        *self.shared.terminal.lock().unwrap() = Some(ev);
        self.shared.done.store(true, Ordering::Release);
    }
}

/// A preview record accepted into the registry: identity-bound, generation-bound,
/// inside the scan root, on the scan's root volume.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewRecord {
    pub path: PathBuf,
    pub size: u64,
    pub dev: u64,
    pub ino: u64,
    pub generation: u64,
}

/// Consumer-side store for preview records, kept deliberately separate from the
/// authoritative arena `Tree`: nothing here is a node id and nothing here feeds
/// totals. Records enter only from `DirComplete` events that pass containment and
/// volume checks, and leave when they fail reconciliation (vanished, unreadable, or
/// replaced: a re-read whose identity differs), when their generation is cancelled,
/// or when the scan finishes (`finish` drops the whole generation: the complete tree
/// supersedes every preview).
pub struct PreviewRegistry {
    root: PathBuf,
    root_dev: u64,
    records: Vec<PreviewRecord>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admit {
    Admitted,
    /// Path is not inside the canonical scan root.
    OutsideRoot,
    /// Directory lives on a different volume than the root and cross-device scans are off.
    ForeignVolume,
    /// Not a DirComplete event: only completed directories become preview records.
    NotARecord,
}

impl PreviewRegistry {
    pub fn new(root: &Path, root_dev: u64) -> Self {
        PreviewRegistry { root: root.to_path_buf(), root_dev, records: Vec::new() }
    }

    /// Admit one event's record. Root containment uses component-wise `Path::starts_with`,
    /// so `/rootx` never counts as inside `/root`. Raw paths: non-UTF-8 components are
    /// compared byte for byte.
    pub fn admit(&mut self, ev: &ScanEvent) -> Admit {
        let EventKind::DirComplete { path, size, dev, ino } = &ev.kind else {
            return Admit::NotARecord;
        };
        if !path.starts_with(&self.root) {
            return Admit::OutsideRoot;
        }
        if *dev != self.root_dev {
            return Admit::ForeignVolume;
        }
        // Identity-keyed: a second event for the same (dev, ino) replaces the earlier one.
        self.records.retain(|r| !(r.dev == *dev && r.ino == *ino));
        self.records.push(PreviewRecord {
            path: path.clone(),
            size: *size,
            dev: *dev,
            ino: *ino,
            generation: ev.generation,
        });
        Admit::Admitted
    }

    /// Re-verify one record against the live filesystem. Returns the record when the
    /// path still resolves to the SAME directory (dev, ino); removes and rejects it
    /// when it vanished, became unreadable, or now names a different identity.
    pub fn reconcile(&mut self, path: &Path) -> Option<&PreviewRecord> {
        use std::os::unix::fs::MetadataExt;
        let live = std::fs::symlink_metadata(path).ok().filter(|m| m.is_dir());
        let want = live.map(|m| (m.dev(), m.ino()));
        let pos = self.records.iter().position(|r| r.path == path);
        let Some(i) = pos else { return None };
        if want == Some((self.records[i].dev, self.records[i].ino)) {
            return self.records.get(i);
        }
        self.records.remove(i);
        None
    }

    /// Drop every record of a generation (root or filter changed, scan superseded).
    pub fn cancel_generation(&mut self, generation: u64) -> usize {
        let before = self.records.len();
        self.records.retain(|r| r.generation != generation);
        before - self.records.len()
    }

    /// The scan finished: the complete tree supersedes every preview record.
    pub fn finish(&mut self, generation: u64) -> usize {
        self.cancel_generation(generation)
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Test-only peek at the first record's inode (fixture sanity checks).
    #[cfg(test)]
    fn reconcile_probe_ino(&self) -> u64 {
        self.records[0].ino
    }
}

/// One throttled preview publication: the largest completed directories seen so far.
/// `partial` is true until the authoritative `Tree` exists - a cancelled or lossy
/// (`dropped > 0`) event stream can never clear it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewSnapshot {
    pub generation: u64,
    pub root: PathBuf,
    /// (path, size), largest first, capped at the collector's `n`.
    pub largest: Vec<(PathBuf, u64)>,
    pub dirs_completed: u64,
    /// The scan's terminal event arrived.
    pub finished: bool,
    /// The scan ended by cancellation.
    pub cancelled: bool,
    /// The terminal reported a fully completed walk under the scanner's accounting
    /// (false on cancellation or a suppressed unreadable subtree).
    pub complete: bool,
    /// Preview events lost to a full channel, as reported by the terminal event.
    pub events_dropped: u64,
    /// True while the ranking is incomplete. After a cancelled, lossy, or partially
    /// walked finish this stays true forever; only the authoritative `Tree`
    /// supersedes the preview.
    pub partial: bool,
}

/// Turns an event stream into throttled preview snapshots. Pure: the clock is injected,
/// so publication timing is decided by the caller (off the scan threads) and tests are
/// deterministic. Events from another generation or root are ignored. Once finished the
/// collector is absorbing: late or duplicate events change nothing and publish nothing.
pub struct PreviewCollector {
    generation: u64,
    root: PathBuf,
    n: usize,
    largest: Vec<(PathBuf, u64)>,
    dirs_completed: u64,
    finished: bool,
    cancelled: bool,
    complete: bool,
    events_dropped: u64,
    last_pub: Option<Instant>,
    published: u64,
}

impl PreviewCollector {
    pub fn new(generation: u64, root: &Path, n: usize) -> Self {
        PreviewCollector {
            generation,
            root: root.to_path_buf(),
            n,
            largest: Vec::new(),
            dirs_completed: 0,
            finished: false,
            cancelled: false,
            complete: false,
            events_dropped: 0,
            last_pub: None,
            published: 0,
        }
    }

    /// Feed one event. Returns a snapshot when the publication interval has elapsed, and
    /// always on the (first) `Finished`. Foreign generation or root: ignored. After
    /// `Finished`: ignored - the terminal state is absorbing.
    pub fn push(&mut self, ev: &ScanEvent, now: Instant) -> Option<PreviewSnapshot> {
        if self.finished {
            return None;
        }
        if ev.generation != self.generation || ev.root != self.root {
            return None;
        }
        match &ev.kind {
            EventKind::DirComplete { path, size, .. } => {
                self.dirs_completed += 1;
                self.insert(path.clone(), *size);
            }
            EventKind::Finished { cancelled, complete, dropped } => {
                self.finished = true;
                self.cancelled = *cancelled;
                self.complete = *complete;
                self.events_dropped = *dropped;
            }
        }
        let due = self
            .last_pub
            .map_or(true, |t| now.duration_since(t) >= PREVIEW_INTERVAL);
        if self.finished || due {
            self.last_pub = Some(now);
            self.published += 1;
            Some(self.snapshot())
        } else {
            None
        }
    }

    /// Snapshots published so far (throttle behavior is observable for tests).
    pub fn published(&self) -> u64 {
        self.published
    }

    pub fn dirs_completed(&self) -> u64 {
        self.dirs_completed
    }

    fn insert(&mut self, path: PathBuf, size: u64) {
        let pos = self
            .largest
            .iter()
            .position(|(_, s)| *s < size)
            .unwrap_or(self.largest.len());
        if pos < self.n {
            self.largest.insert(pos, (path, size));
            self.largest.truncate(self.n);
        }
    }

    fn snapshot(&self) -> PreviewSnapshot {
        PreviewSnapshot {
            generation: self.generation,
            root: self.root.clone(),
            largest: self.largest.clone(),
            dirs_completed: self.dirs_completed,
            finished: self.finished,
            cancelled: self.cancelled,
            complete: self.complete,
            events_dropped: self.events_dropped,
            // Provisional until the scan finished WITHOUT cancellation, WITHOUT loss,
            // and WITHOUT suppressed subtrees.
            partial: !self.finished || self.cancelled || !self.complete || self.events_dropped > 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::{scan, scan_with_events, ScanOptions, ScanProgress};
    use std::fs;

    fn ev(generation: u64, root: &Path, path: &Path, size: u64) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::DirComplete { path: path.to_path_buf(), size, dev: 1, ino: 1 },
        }
    }

    fn fin(generation: u64, root: &Path, cancelled: bool, complete: bool, dropped: u64) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::Finished { cancelled, complete, dropped },
        }
    }

    /// Fixture: root with two subdirectories and files with real bytes (sparse files
    /// would keep st_blocks at 0).
    fn fixture(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("spz-events-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("alpha")).unwrap();
        fs::create_dir_all(dir.join("beta/nested")).unwrap();
        fs::write(dir.join("alpha/f1"), vec![1u8; 4096]).unwrap();
        fs::write(dir.join("beta/f2"), vec![1u8; 8192]).unwrap();
        fs::write(dir.join("beta/nested/f3"), vec![1u8; 4096]).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn full_channel_drops_events_and_never_blocks() {
        let (sink, _rx) = PreviewEvents::with_bound(7, Path::new("/tmp"), 2);
        for i in 0..5u64 {
            sink.emit(EventKind::DirComplete { path: PathBuf::from(format!("/tmp/d{i}")), size: i, dev: 1, ino: i });
        }
        assert_eq!(sink.dropped(), 3);
        assert_eq!(sink.generation(), 7);
    }

    #[test]
    fn collector_ignores_foreign_generation_and_root() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let now = Instant::now();
        assert!(c.push(&ev(2, Path::new("/root"), Path::new("/root/a"), 10), now).is_none());
        assert!(c.push(&ev(1, Path::new("/other"), Path::new("/other/a"), 10), now).is_none());
        assert_eq!(c.dirs_completed(), 0);
        assert_eq!(c.published(), 0);
    }

    #[test]
    fn collector_throttles_at_the_249_250ms_boundary() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let t0 = Instant::now();
        assert!(c.push(&ev(1, Path::new("/root"), Path::new("/root/a"), 10), t0).is_some());
        assert!(c.push(&ev(1, Path::new("/root"), Path::new("/root/b"), 20), t0 + Duration::from_millis(249)).is_none());
        let s = c.push(&ev(1, Path::new("/root"), Path::new("/root/c"), 30), t0 + Duration::from_millis(250)).unwrap();
        assert_eq!(s.largest.len(), 3);
        assert!(s.partial && !s.finished && !s.cancelled && s.events_dropped == 0);
    }

    #[test]
    fn collector_keeps_largest_first_capped_at_n() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 2);
        let now = Instant::now();
        c.push(&ev(1, Path::new("/root"), Path::new("/root/small"), 5), now);
        c.push(&ev(1, Path::new("/root"), Path::new("/root/big"), 50), now);
        let s = c.push(&ev(1, Path::new("/root"), Path::new("/root/mid"), 20), now + PREVIEW_INTERVAL).unwrap();
        let sizes: Vec<u64> = s.largest.iter().map(|(_, s)| *s).collect();
        assert_eq!(sizes, vec![50, 20]);
    }

    #[test]
    fn cancelled_collector_stays_partial_forever_and_is_absorbing() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let t0 = Instant::now();
        c.push(&ev(1, Path::new("/root"), Path::new("/root/a"), 10), t0);
        let s = c.push(&fin(1, Path::new("/root"), true, false, 0), t0 + Duration::from_millis(10)).unwrap();
        assert!(s.finished && s.cancelled && s.partial, "a cancelled scan must stay provisional");
        // Absorbing: late events change nothing and publish nothing.
        assert!(c.push(&ev(1, Path::new("/root"), Path::new("/root/late"), 99), t0 + Duration::from_secs(60)).is_none());
        assert!(c.push(&fin(1, Path::new("/root"), false, true, 0), t0 + Duration::from_secs(61)).is_none());
        assert_eq!(c.dirs_completed(), 1);
        assert_eq!(c.published(), 2);
    }

    #[test]
    fn loss_then_finished_stays_partial() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let s = c.push(&fin(1, Path::new("/root"), false, true, 3), Instant::now()).unwrap();
        assert!(s.finished && !s.cancelled && s.events_dropped == 3 && s.partial,
                "dropped events mean the preview was never complete");
    }

    #[test]
    fn incomplete_finish_stays_partial() {
        // The walk covered only part of the tree (a suppressed subtree): not cancelled,
        // no loss, still provisional forever.
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let s = c.push(&fin(1, Path::new("/root"), false, false, 0), Instant::now()).unwrap();
        assert!(s.finished && !s.cancelled && !s.complete && s.events_dropped == 0 && s.partial,
                "a partially walked tree can never clear provisional status");
    }

    #[test]
    fn clean_finished_clears_partial() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let s = c.push(&fin(1, Path::new("/root"), false, true, 0), Instant::now()).unwrap();
        assert!(s.finished && s.complete && !s.partial);
    }

    #[test]
    fn events_are_bound_to_generation_and_canonical_root_with_full_tree_parity() {
        let root = fixture("bind");
        let (sink, rx) = PreviewEvents::new(42, &root);
        let progress = ScanProgress::default();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        assert!(!events.is_empty());
        for e in &events {
            assert_eq!(e.generation, 42);
            assert_eq!(e.root, root);
        }
        let mut completes: Vec<PathBuf> = events
            .iter()
            .filter_map(|e| match &e.kind {
                EventKind::DirComplete { path, .. } => Some(path.clone()),
                _ => None,
            })
            .collect();
        completes.sort();
        let mut want = vec![root.clone(), root.join("alpha"), root.join("beta"), root.join("beta/nested")];
        want.sort();
        assert_eq!(completes, want);
        assert!(matches!(events.last().map(|e| &e.kind),
                         Some(EventKind::Finished { cancelled: false, complete: true, dropped: 0 })));
        // Full parity with a plain scan: every authoritative field matches.
        let plain = scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        assert_eq!(tree.root_path, plain.root_path);
        assert_eq!(tree.names, plain.names);
        assert_eq!(tree.parent, plain.parent);
        assert_eq!(tree.kind, plain.kind);
        assert_eq!(tree.size, plain.size);
        assert_eq!(tree.first_child, plain.first_child);
        assert_eq!(tree.child_count, plain.child_count);
        assert_eq!(tree.mtime, plain.mtime, "metadata (mtime) parity");
        assert_eq!(tree.category, plain.category, "category parity");
        assert_eq!(tree.items, plain.items);
        assert_eq!(tree.cancelled, plain.cancelled);
        let mut skipped_a: Vec<(String, String)> = tree.skipped.iter().map(|s| (s.path.clone(), format!("{:?}", s.reason))).collect();
        let mut skipped_b: Vec<(String, String)> = plain.skipped.iter().map(|s| (s.path.clone(), format!("{:?}", s.reason))).collect();
        skipped_a.sort();
        skipped_b.sort();
        assert_eq!(skipped_a, skipped_b, "skipped-record parity");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_before_scan_reports_finished_cancelled_and_no_dir_events() {
        let root = fixture("cancel0");
        let (sink, rx) = PreviewEvents::new(1, &root);
        let progress = ScanProgress::default();
        progress.cancel();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        assert!(tree.cancelled);
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        assert!(events.iter().all(|e| !matches!(e.kind, EventKind::DirComplete { .. })));
        assert_eq!(events.len(), 1, "terminal only, exactly once");
        assert!(matches!(events.last().map(|e| &e.kind),
                         Some(EventKind::Finished { cancelled: true, complete: false, dropped: 0 })));
        let _ = fs::remove_dir_all(&root);
    }

    /// Wide fixture: 5000 single-file directories, so a mid-scan cancel tripwire always
    /// has unvisited directories left to suppress.
    fn wide_fixture(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("spz-events-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        for i in 0..5000 {
            let sub = dir.join(format!("d{i:04}"));
            fs::create_dir_all(&sub).unwrap();
            // Sparse 1 MiB file: only metadata is touched, so fixture setup stays fast
            // while the walk still has to stat and aggregate 5000 children.
            fs::File::create(sub.join("f")).unwrap().set_len(1 << 20).unwrap();
        }
        dir.canonicalize().unwrap()
    }

    #[test]
    fn mid_scan_cancel_suppresses_incomplete_subtrees() {
        // Deterministic cancel injection: the tripwire fires when the 150th directory
        // walk begins, whatever the thread schedule. No sleeps, no retries.
        let root = wide_fixture("cancelmid");
        let (sink, rx) = PreviewEvents::new(1, &root);
        let progress = ScanProgress::default();
        progress.cancel_after_dirs(150);
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        assert!(tree.cancelled);
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let completes: Vec<&PathBuf> = events
            .iter()
            .filter_map(|e| match &e.kind {
                EventKind::DirComplete { path, .. } => Some(path),
                _ => None,
            })
            .collect();
        assert!(!completes.is_empty(), "directories walked before the tripwire still complete");
        // Whatever completed before the cancel is fine; the root (whose subtree was cut
        // short) must NEVER be emitted as complete.
        assert!(!completes.iter().any(|p| **p == root), "incomplete root emitted: {completes:?}");
        assert!(completes.len() < 5001, "every directory completed despite cancel");
        let terminals: Vec<&ScanEvent> = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::Finished { .. }))
            .collect();
        assert_eq!(terminals.len(), 1, "exactly one terminal event");
        assert!(matches!(terminals[0].kind,
                         EventKind::Finished { cancelled: true, complete: false, .. }));
        assert!(matches!(events.last().map(|e| &e.kind), Some(EventKind::Finished { .. })),
                "terminal is last");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn unreadable_child_suppresses_every_ancestor_event() {
        use std::os::unix::fs::PermissionsExt;
        let root = fixture("unreadable");
        let sealed = root.join("beta/nested");
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read_dir(&sealed).is_ok() {
            // Mode bits not enforced here (root, or a filesystem without unix modes):
            // the permission-denied path cannot be exercised on this platform.
            fs::set_permissions(&sealed, fs::Permissions::from_mode(0o755)).unwrap();
            let _ = fs::remove_dir_all(&root);
            eprintln!("unreadable_child_suppresses_every_ancestor_event: UNEXERCISED - mode bits not enforced for this user/platform");
            return;
        }
        let (sink, rx) = PreviewEvents::new(1, &root);
        let progress = ScanProgress::default();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o755)).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let completes: Vec<&PathBuf> = events
            .iter()
            .filter_map(|e| match &e.kind {
                EventKind::DirComplete { path, .. } => Some(path),
                _ => None,
            })
            .collect();
        assert!(completes.iter().any(|p| **p == root.join("alpha")), "readable sibling completes");
        assert!(!completes.iter().any(|p| **p == root.join("beta")), "parent of unreadable child suppressed");
        assert!(!completes.iter().any(|p| **p == root), "root with unreadable descendant suppressed");
        assert!(matches!(events.last().map(|e| &e.kind),
                         Some(EventKind::Finished { cancelled: false, complete: false, dropped: 0 })),
                "terminal reports the incomplete walk");
        // Tree behavior unchanged: the unreadable directory is recorded as skipped.
        assert!(tree.skipped.iter().any(|s| s.path.ends_with("beta/nested")));
        // Collector: not cancelled, no loss, but the walk was incomplete -> provisional
        // forever. Only the authoritative Tree supersedes the preview.
        let mut c = PreviewCollector::new(1, &root, 10);
        let mut last = None;
        let mut now = Instant::now();
        for e in &events {
            if let Some(s) = c.push(e, now) {
                last = Some(s);
            }
            now += Duration::from_millis(1);
        }
        let s = last.unwrap();
        assert!(s.finished && !s.cancelled && !s.complete && s.events_dropped == 0 && s.partial,
                "suppressed subtree leaves the preview provisional");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn full_queue_cannot_lose_the_terminal_event() {
        let root = fixture("terminal");
        let (sink, rx) = PreviewEvents::with_bound(1, &root, 1);
        let progress = ScanProgress::default();
        let _tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        assert!(sink.dropped() > 0, "bound=1 must drop under a 4-directory scan");
        // Drain AFTER the scan: exactly one terminal, last, and its dropped count must
        // account for every data event that never arrived (consistent snapshot).
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let terminals: Vec<&ScanEvent> = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::Finished { .. }))
            .collect();
        assert_eq!(terminals.len(), 1, "exactly one terminal event");
        let dropped = match terminals[0].kind {
            EventKind::Finished { cancelled: false, complete: true, dropped } => dropped,
            _ => panic!("unexpected terminal: {:?}", terminals[0]),
        };
        let received_data = (events.len() - 1) as u64;
        assert_eq!(received_data + dropped, 4,
                   "every DirComplete is either received or counted dropped: {events:?}");
        assert_eq!(dropped, sink.dropped(), "terminal snapshot matches the sink's final count");
        assert!(matches!(events.last().map(|e| &e.kind), Some(EventKind::Finished { .. })),
                "terminal is last");
        assert!(rx.recv_timeout(Duration::from_millis(100)).is_none(), "terminal yields once");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn terminal_delivered_exactly_once_on_the_lossless_path() {
        let root = fixture("once");
        let (sink, rx) = PreviewEvents::new(3, &root);
        let progress = ScanProgress::default();
        scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let terminals = events.iter().filter(|e| matches!(e.kind, EventKind::Finished { .. })).count();
        assert_eq!(terminals, 1, "terminal exactly once on the lossless path: {events:?}");
        assert_eq!(events.len(), 5, "4 DirComplete + 1 terminal: {events:?}");
        assert!(matches!(events.last().map(|e| &e.kind),
                         Some(EventKind::Finished { cancelled: false, complete: true, dropped: 0 })));
        assert!(rx.recv_timeout(Duration::from_millis(100)).is_none(), "no second terminal");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn queued_data_events_drain_before_the_terminal() {
        // Bound large enough to hold every event; never poll during the scan, so the
        // done flag lands while the queue still holds all data events.
        let root = fixture("ordering");
        let (sink, rx) = PreviewEvents::with_bound(4, &root, 8);
        let progress = ScanProgress::default();
        scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        assert_eq!(events.len(), 5, "all 4 data events retained + terminal: {events:?}");
        assert!(events[..4].iter().all(|e| matches!(e.kind, EventKind::DirComplete { .. })),
                "all data events precede the terminal: {events:?}");
        assert!(matches!(events[4].kind, EventKind::Finished { .. }));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn non_utf8_roots_with_identical_lossy_text_stay_distinct() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let base = std::env::temp_dir().join(format!("spz-events-utf8pair-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let dir_a = base.join(OsStr::from_bytes(b"root-\xff"));
        let dir_b = base.join(OsStr::from_bytes(b"root-\xfe"));
        fs::create_dir_all(&dir_a).unwrap();
        fs::create_dir_all(&dir_b).unwrap();
        let root_a = dir_a.canonicalize().unwrap();
        let root_b = dir_b.canonicalize().unwrap();
        assert_ne!(root_a, root_b);
        assert_eq!(root_a.to_string_lossy(), root_b.to_string_lossy(),
                   "fixtures must collide under lossy UTF-8");
        let (sink_a, _rx) = PreviewEvents::new(1, &root_a);
        assert!(sink_a.root_matches(&root_a));
        assert!(!sink_a.root_matches(&root_b), "lossy-equal roots must not bind");
        // A scan of root B must not emit into root A's sink.
        let progress = ScanProgress::default();
        assert!(scan_with_events(&root_b, &ScanOptions::default(), &progress, &sink_a).is_err());
        // And a collector bound to root A ignores root B's events.
        let mut c = PreviewCollector::new(1, &root_a, 5);
        assert!(c.push(&ev(1, &root_b, &root_b, 10), Instant::now()).is_none());
        assert_eq!(c.dirs_completed(), 0);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn non_utf8_root_round_trips_exactly() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let base = std::env::temp_dir().join(format!("spz-events-utf8-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let raw = OsStr::from_bytes(b"root-\xff-\xfe");
        let dir = base.join(raw);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("sub/f"), vec![1u8; 1024]).unwrap();
        let root = dir.canonicalize().unwrap();
        assert!(root.to_str().is_none(), "fixture must be non-UTF-8");
        let (sink, rx) = PreviewEvents::new(5, &root);
        let progress = ScanProgress::default();
        scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        assert!(events.iter().all(|e| e.root == root), "raw root bytes preserved");
        assert!(sink.root_matches(&root));
        // The collector's raw-path binding accepts the same bytes.
        let mut c = PreviewCollector::new(5, &root, 5);
        let s = c.push(&events[0], Instant::now());
        assert!(s.is_some());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn sink_root_mismatch_is_an_error_not_wrong_events() {
        let root = fixture("mismatch");
        let (sink, _rx) = PreviewEvents::new(1, Path::new("/tmp"));
        let progress = ScanProgress::default();
        match scan_with_events(&root, &ScanOptions::default(), &progress, &sink) {
            Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::InvalidInput),
            Ok(_) => panic!("a sink built for a different root must be refused"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sink_is_one_shot_sequential_reuse_refused() {
        let root = fixture("oneshot");
        let (sink, rx) = PreviewEvents::new(1, &root);
        let progress = ScanProgress::default();
        scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        while rx.recv_timeout(Duration::from_millis(500)).is_some() {}
        match scan_with_events(&root, &ScanOptions::default(), &ScanProgress::default(), &sink) {
            Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::InvalidInput),
            Ok(_) => panic!("sequential reuse of a finished sink must be refused"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sink_concurrent_claim_lets_exactly_one_scan_run() {
        // Deterministic: scan A's claim happens before its first event, so once the
        // receiver sees that event, a second scan on the same sink must be refused.
        let root = wide_fixture("concurrent");
        let (sink, rx) = PreviewEvents::new(1, &root);
        let progress = ScanProgress::default();
        std::thread::scope(|s| {
            let a = s.spawn(|| scan_with_events(&root, &ScanOptions::default(), &progress, &sink));
            let first = rx.recv_timeout(Duration::from_secs(30)).expect("scan A emits an event");
            assert!(matches!(first.kind, EventKind::DirComplete { .. }));
            match scan_with_events(&root, &ScanOptions::default(), &ScanProgress::default(), &sink) {
                Err(e) => assert_eq!(e.kind(), std::io::ErrorKind::InvalidInput),
                Ok(_) => panic!("concurrent use of a claimed sink must be refused"),
            }
            let tree = a.join().unwrap().unwrap();
            assert!(!tree.cancelled, "the refused second scan must not disturb the first");
        });
        let _ = fs::remove_dir_all(&root);
    }

    fn dir_event(generation: u64, root: &Path, path: &Path, size: u64) -> ScanEvent {
        use std::os::unix::fs::MetadataExt;
        let md = fs::symlink_metadata(path).unwrap();
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::DirComplete {
                path: path.to_path_buf(),
                size,
                dev: md.dev(),
                ino: md.ino(),
            },
        }
    }

    #[test]
    fn registry_admits_only_contained_same_volume_records_keyed_by_identity() {
        let root = fixture("reg-admit");
        use std::os::unix::fs::MetadataExt;
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let mut reg = PreviewRegistry::new(&root, root_dev);

        // Inside root, same volume: admitted; re-admission of the same identity replaces.
        let ev1 = dir_event(1, &root, &root.join("alpha"), 100);
        assert_eq!(reg.admit(&ev1), Admit::Admitted);
        assert_eq!(reg.admit(&ev1), Admit::Admitted);
        assert_eq!(reg.len(), 1);

        // Prefix trap: /rootx is not inside /root.
        let other = root.with_file_name(format!("{}x", root.file_name().unwrap().to_string_lossy()));
        let outside = ScanEvent {
            generation: 1,
            root: root.to_path_buf(),
            kind: EventKind::DirComplete { path: other, size: 1, dev: root_dev, ino: 999 },
        };
        assert_eq!(reg.admit(&outside), Admit::OutsideRoot);

        // Foreign volume is refused even inside the root.
        let foreign = ScanEvent {
            generation: 1,
            root: root.to_path_buf(),
            kind: EventKind::DirComplete { path: root.join("alpha"), size: 100, dev: root_dev + 1, ino: 42 },
        };
        assert_eq!(reg.admit(&foreign), Admit::ForeignVolume);

        // Finished is not a record.
        let fin = fin(1, &root, false, true, 0);
        assert_eq!(reg.admit(&fin), Admit::NotARecord);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn reconcile_rejects_vanished_and_replaced_paths() {
        let root = fixture("reg-reconcile");
        use std::os::unix::fs::MetadataExt;
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let mut reg = PreviewRegistry::new(&root, root_dev);
        let alpha = root.join("alpha");
        reg.admit(&dir_event(1, &root, &alpha, 100));
        // Live and identical: confirmed.
        assert!(reg.reconcile(&alpha).is_some());
        // Vanished: removed and rejected.
        let beta = root.join("beta");
        reg.admit(&dir_event(1, &root, &beta, 200));
        fs::remove_dir_all(&beta).unwrap();
        assert!(reg.reconcile(&beta).is_none());
        assert_eq!(reg.len(), 1);
        // Replaced by a different identity at the same path: removed and rejected.
        // mkdir while the original still exists guarantees a different inode, then the
        // rename puts that new identity at the old path (no inode-recycling race).
        let gamma = root.join("alpha");
        let staging = root.join("staging");
        fs::create_dir_all(&staging).unwrap();
        fs::remove_dir_all(&gamma).unwrap();
        fs::rename(&staging, &gamma).unwrap();
        let live_ino = fs::symlink_metadata(&gamma).unwrap().ino();
        assert_ne!(live_ino, reg.reconcile_probe_ino(), "fixture must replace the inode");
        assert!(reg.reconcile(&gamma).is_none());
        assert!(reg.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_and_finish_drop_the_generation() {
        let root = fixture("reg-cancel");
        use std::os::unix::fs::MetadataExt;
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let mut reg = PreviewRegistry::new(&root, root_dev);
        reg.admit(&dir_event(1, &root, &root.join("alpha"), 100));
        reg.admit(&dir_event(1, &root, &root.join("beta"), 200));
        reg.admit(&dir_event(2, &root, &root.join("beta/nested"), 50));
        assert_eq!(reg.cancel_generation(1), 2);
        assert_eq!(reg.len(), 1);
        assert_eq!(reg.finish(2), 1);
        assert!(reg.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn real_scan_events_carry_live_identity_and_feed_the_registry() {
        let root = fixture("reg-e2e");
        use std::os::unix::fs::MetadataExt;
        let (sink, rx) = PreviewEvents::new(11, &root);
        let progress = ScanProgress::default();
        scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let mut reg = PreviewRegistry::new(&root, root_dev);
        let mut terminal = None;
        for e in &events {
            match &e.kind {
                EventKind::DirComplete { path, dev, ino, .. } => {
                    // Identity matches the live filesystem exactly.
                    let md = fs::symlink_metadata(path).unwrap();
                    assert_eq!((*dev, *ino), (md.dev(), md.ino()), "event identity for {path:?}");
                    assert_eq!(reg.admit(e), Admit::Admitted);
                }
                k @ EventKind::Finished { .. } => terminal = Some(k.clone()),
                _ => {}
            }
        }
        assert!(terminal.is_some());
        assert_eq!(reg.len(), 4, "root + alpha + beta + beta/nested");
        // The scan finished: the complete tree supersedes every preview record.
        assert_eq!(reg.finish(11), 4);
        assert!(reg.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn end_to_end_collector_over_a_real_scan() {
        let root = fixture("e2e");
        let (sink, rx) = PreviewEvents::new(9, &root);
        let progress = ScanProgress::default();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let mut c = PreviewCollector::new(9, &root, 10);
        let mut now = Instant::now();
        let mut last = None;
        for e in &events {
            if let Some(s) = c.push(e, now) {
                last = Some(s);
            }
            now += Duration::from_millis(1);
        }
        let s = last.unwrap();
        assert!(s.finished && !s.partial && !s.cancelled);
        assert_eq!(s.generation, 9);
        assert_eq!(s.root, root);
        assert_eq!(s.dirs_completed, 4);
        let root_total = s.largest.iter().find(|(p, _)| *p == root).map(|(_, sz)| *sz);
        assert_eq!(root_total, Some(tree.size[0]));
        let _ = fs::remove_dir_all(&root);
    }
}
