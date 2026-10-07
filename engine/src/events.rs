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
//! - The terminal `Finished` event is durable: it is always recorded in the terminal slot
//!   (and only best-effort queued), so a full channel can never lose it. It carries the
//!   cancel flag and the number of dropped events.
//! - Every event carries the scan generation and the canonical root as a raw `PathBuf`
//!   (never a lossy UTF-8 string), and `scan_with_events` refuses a sink built for a
//!   different root.
//! - The collector is absorbing once finished, and a cancelled or lossy scan leaves every
//!   later snapshot `partial: true` forever: only the authoritative `Tree` ends
//!   provisionality, never the event stream.
//!
//! Design inspired by dua-cli's bounded entry/finished channel; no code is copied.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
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
    /// incomplete subtree emit nothing, and neither do their ancestors.
    DirComplete { path: PathBuf, size: u64 },
    /// The scan ended. `cancelled` says whether it ended by cancellation; `dropped` is
    /// how many preview events were lost to a full channel. Durable: see the module
    /// docs - this event is recorded even when the channel is full.
    Finished { cancelled: bool, dropped: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanEvent {
    pub generation: u64,
    /// Canonical root of the scan this event belongs to, as a raw path (no lossy
    /// UTF-8 conversion; non-UTF-8 roots round-trip exactly).
    pub root: PathBuf,
    pub kind: EventKind,
}

struct Terminal {
    slot: Mutex<Option<ScanEvent>>,
}

/// The scan side of the event channel. Share by reference; safe from worker threads.
pub struct PreviewEvents {
    tx: SyncSender<ScanEvent>,
    generation: u64,
    root: PathBuf,
    dropped: AtomicU64,
    terminal: Arc<Terminal>,
}

/// The consumer side. Drains queued events; once the queue is empty and the terminal
/// event was recorded, yields it exactly once, however full the channel was when the
/// scan finished.
pub struct PreviewReceiver {
    rx: Receiver<ScanEvent>,
    terminal: Arc<Terminal>,
}

impl PreviewReceiver {
    /// Next event, waiting up to `d`. After the queued events, the durable terminal
    /// event is returned exactly once; later calls return None.
    pub fn recv_timeout(&self, d: Duration) -> Option<ScanEvent> {
        if let Ok(ev) = self.rx.recv_timeout(d) {
            return Some(ev);
        }
        self.terminal.slot.lock().unwrap().take()
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
        let terminal = Arc::new(Terminal { slot: Mutex::new(None) });
        (
            PreviewEvents {
                tx,
                generation,
                root: root.to_path_buf(),
                dropped: AtomicU64::new(0),
                terminal: terminal.clone(),
            },
            PreviewReceiver { rx, terminal },
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

    /// Terminal event: ALWAYS recorded in the durable slot, best-effort queued. The
    /// dropped count is frozen at finish time so the consumer can see the loss.
    pub(crate) fn finish(&self, cancelled: bool) {
        let ev = ScanEvent {
            generation: self.generation,
            root: self.root.clone(),
            kind: EventKind::Finished {
                cancelled,
                dropped: self.dropped(),
            },
        };
        *self.terminal.slot.lock().unwrap() = Some(ev.clone());
        self.send(ev);
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
    /// Preview events lost to a full channel, as reported by the terminal event.
    pub events_dropped: u64,
    /// True while the ranking is incomplete. After a cancelled or lossy finish this
    /// stays true forever; only the authoritative `Tree` supersedes the preview.
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
            EventKind::DirComplete { path, size } => {
                self.dirs_completed += 1;
                self.insert(path.clone(), *size);
            }
            EventKind::Finished { cancelled, dropped } => {
                self.finished = true;
                self.cancelled = *cancelled;
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
            events_dropped: self.events_dropped,
            // Provisional until the scan finished WITHOUT cancellation and WITHOUT loss.
            partial: !self.finished || self.cancelled || self.events_dropped > 0,
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
            kind: EventKind::DirComplete { path: path.to_path_buf(), size },
        }
    }

    fn fin(generation: u64, root: &Path, cancelled: bool, dropped: u64) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::Finished { cancelled, dropped },
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
            sink.emit(EventKind::DirComplete { path: PathBuf::from(format!("/tmp/d{i}")), size: i });
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
        let s = c.push(&fin(1, Path::new("/root"), true, 0), t0 + Duration::from_millis(10)).unwrap();
        assert!(s.finished && s.cancelled && s.partial, "a cancelled scan must stay provisional");
        // Absorbing: late events change nothing and publish nothing.
        assert!(c.push(&ev(1, Path::new("/root"), Path::new("/root/late"), 99), t0 + Duration::from_secs(60)).is_none());
        assert!(c.push(&fin(1, Path::new("/root"), false, 0), t0 + Duration::from_secs(61)).is_none());
        assert_eq!(c.dirs_completed(), 1);
        assert_eq!(c.published(), 2);
    }

    #[test]
    fn loss_then_finished_stays_partial() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let s = c.push(&fin(1, Path::new("/root"), false, 3), Instant::now()).unwrap();
        assert!(s.finished && !s.cancelled && s.events_dropped == 3 && s.partial,
                "dropped events mean the preview was never complete");
    }

    #[test]
    fn clean_finished_clears_partial() {
        let mut c = PreviewCollector::new(1, Path::new("/root"), 5);
        let s = c.push(&fin(1, Path::new("/root"), false, 0), Instant::now()).unwrap();
        assert!(s.finished && !s.partial);
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
                         Some(EventKind::Finished { cancelled: false, dropped: 0 })));
        // Full parity with a plain scan: every authoritative field matches.
        let plain = scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        assert_eq!(tree.root_path, plain.root_path);
        assert_eq!(tree.names, plain.names);
        assert_eq!(tree.parent, plain.parent);
        assert_eq!(tree.kind, plain.kind);
        assert_eq!(tree.size, plain.size);
        assert_eq!(tree.first_child, plain.first_child);
        assert_eq!(tree.child_count, plain.child_count);
        assert_eq!(tree.items, plain.items);
        assert_eq!(tree.cancelled, plain.cancelled);
        assert_eq!(tree.skipped.len(), plain.skipped.len());
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
        assert!(matches!(events.last().map(|e| &e.kind),
                         Some(EventKind::Finished { cancelled: true, .. })));
        let _ = fs::remove_dir_all(&root);
    }

    /// Wide fixture: 300 single-file directories, so a scan is still in flight when the
    /// cancel lands after the first completed directory.
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
        // The cancel must land while the scan is running; allow a few attempts in case a
        // fast machine finishes the fixture before the receiver wakes.
        for attempt in 0..3 {
            let root = wide_fixture(&format!("cancelmid{attempt}"));
            let (sink, rx) = PreviewEvents::new(1, &root);
            let progress = ScanProgress::default();
            let (tree, mut events) = std::thread::scope(|s| {
                let handle = s.spawn(|| {
                    scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap()
                });
                let mut collected = Vec::new();
                if let Some(first) = rx.recv_timeout(Duration::from_secs(10)) {
                    assert!(matches!(first.kind, EventKind::DirComplete { .. }));
                    collected.push(first);
                    progress.cancel();
                }
                let tree = handle.join().unwrap();
                while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
                    collected.push(e);
                }
                (tree, collected)
            });
            if !tree.cancelled {
                let _ = fs::remove_dir_all(&root);
                continue; // scan finished before the cancel landed; retry wider window
            }
            let completes: Vec<&PathBuf> = events
                .iter()
                .filter_map(|e| match &e.kind {
                    EventKind::DirComplete { path, .. } => Some(path),
                    _ => None,
                })
                .collect();
            assert!(!completes.is_empty(), "at least the first directory completed");
            // Whatever completed before the cancel is fine; the root (whose subtree was
            // cut short) must NEVER be emitted as complete.
            assert!(!completes.iter().any(|p| **p == root), "incomplete root emitted: {completes:?}");
            assert!(completes.len() < 5001, "every directory completed despite cancel");
            assert!(matches!(events.last().map(|e| &e.kind),
                             Some(EventKind::Finished { cancelled: true, .. })));
            events.clear();
            let _ = fs::remove_dir_all(&root);
            return;
        }
        panic!("cancel never landed mid-scan in 3 attempts");
    }

    #[test]
    fn unreadable_child_suppresses_every_ancestor_event() {
        use std::os::unix::fs::PermissionsExt;
        let root = fixture("unreadable");
        let sealed = root.join("beta/nested");
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o000)).unwrap();
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
                         Some(EventKind::Finished { cancelled: false, .. })));
        // Tree behavior unchanged: the unreadable directory is recorded as skipped.
        assert!(tree.skipped.iter().any(|s| s.path.ends_with("beta/nested")));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn full_queue_cannot_lose_the_terminal_event() {
        let root = fixture("terminal");
        let (sink, rx) = PreviewEvents::with_bound(1, &root, 1);
        let progress = ScanProgress::default();
        let _tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        assert!(sink.dropped() > 0, "bound=1 must drop under a 4-directory scan");
        // Drain: one queued event, then the durable terminal exactly once, then None.
        let mut events = Vec::new();
        while let Some(e) = rx.recv_timeout(Duration::from_millis(500)) {
            events.push(e);
        }
        let terminals: Vec<&ScanEvent> = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::Finished { .. }))
            .collect();
        assert_eq!(terminals.len(), 1, "exactly one terminal event, queued or slotted");
        assert!(matches!(terminals[0].kind, EventKind::Finished { cancelled: false, dropped } if dropped > 0));
        assert!(rx.recv_timeout(Duration::from_millis(100)).is_none(), "terminal yields once");
        let _ = fs::remove_dir_all(&root);
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
