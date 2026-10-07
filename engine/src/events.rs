//! Progressive scan events (milestone 2, index-accelerated early results: engine slice A).
//!
//! The authoritative result stays the `Tree` returned by `scan`. Events exist so an
//! "Early results - scanning" preview can be published while a scan runs. The channel is
//! bounded: when it is full the event is DROPPED (counted in `dropped`), so preview
//! plumbing can never block the scan. Every event carries the scan generation and the
//! canonical root, and `scan_with_events` refuses a sink whose root does not match the
//! canonical scan root, so a consumer can always reject stale or foreign events.
//! Design inspired by dua-cli's bounded entry/finished channel; no code is copied.

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::time::{Duration, Instant};

/// Bounded so a slow preview consumer can never stall the scan.
pub const CHANNEL_BOUND: usize = 100;
/// Minimum spacing between preview publications.
pub const PREVIEW_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventKind {
    /// A directory whose subtree finished scanning; `size` is its final allocated-byte
    /// total for that subtree. Directories that did not complete emit nothing.
    DirComplete { path: Box<str>, size: u64 },
    /// The scan ended; `cancelled` says whether it ended by cancellation.
    Finished { cancelled: bool },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanEvent {
    pub generation: u64,
    /// Canonical root path of the scan this event belongs to.
    pub root: Box<str>,
    pub kind: EventKind,
}

/// The scan side of the event channel. Share by reference; safe to use from worker threads.
pub struct PreviewEvents {
    tx: SyncSender<ScanEvent>,
    generation: u64,
    root: Box<str>,
    dropped: AtomicU64,
}

impl PreviewEvents {
    /// `root` must be the canonical scan root; `scan_with_events` checks this and errors
    /// on a mismatch rather than emitting events bound to the wrong root.
    pub fn new(generation: u64, root: &Path) -> (Self, Receiver<ScanEvent>) {
        Self::with_bound(generation, root, CHANNEL_BOUND)
    }

    pub fn with_bound(generation: u64, root: &Path, bound: usize) -> (Self, Receiver<ScanEvent>) {
        let (tx, rx) = sync_channel(bound);
        (
            PreviewEvents {
                tx,
                generation,
                root: root.to_string_lossy().into_owned().into_boxed_str(),
                dropped: AtomicU64::new(0),
            },
            rx,
        )
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// True when this sink was built for `canonical_root` (already canonicalized).
    pub(crate) fn root_matches(&self, canonical_root: &Path) -> bool {
        *self.root == *canonical_root.to_string_lossy()
    }

    /// Events dropped because the channel was full. A disconnected receiver is not
    /// counted: the consumer going away (for example after a cancel) is normal.
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    pub(crate) fn emit(&self, kind: EventKind) {
        let ev = ScanEvent {
            generation: self.generation,
            root: self.root.clone(),
            kind,
        };
        match self.tx.try_send(ev) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => {}
            Err(TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

/// One throttled preview publication: the largest completed directories seen so far.
/// `partial` is true until the scan's `Finished` event; a partial preview is never a
/// complete ranking and must never feed totals.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewSnapshot {
    pub generation: u64,
    pub root: Box<str>,
    /// (path, size), largest first, capped at the collector's `n`.
    pub largest: Vec<(Box<str>, u64)>,
    pub dirs_completed: u64,
    pub finished: bool,
    pub partial: bool,
}

/// Turns an event stream into throttled preview snapshots. Pure: the clock is injected,
/// so publication timing is decided by the caller (off the scan threads) and tests are
/// deterministic. Events from another generation or root are ignored.
pub struct PreviewCollector {
    generation: u64,
    root: Box<str>,
    n: usize,
    largest: Vec<(Box<str>, u64)>,
    dirs_completed: u64,
    finished: bool,
    last_pub: Option<Instant>,
    published: u64,
}

impl PreviewCollector {
    pub fn new(generation: u64, root: &str, n: usize) -> Self {
        PreviewCollector {
            generation,
            root: root.into(),
            n,
            largest: Vec::new(),
            dirs_completed: 0,
            finished: false,
            last_pub: None,
            published: 0,
        }
    }

    /// Feed one event. Returns a snapshot when the publication interval has elapsed, and
    /// always on `Finished`. Foreign generation or root: ignored, no publication.
    pub fn push(&mut self, ev: &ScanEvent, now: Instant) -> Option<PreviewSnapshot> {
        if ev.generation != self.generation || *ev.root != *self.root {
            return None;
        }
        match &ev.kind {
            EventKind::DirComplete { path, size } => {
                self.dirs_completed += 1;
                self.insert(path.clone(), *size);
            }
            EventKind::Finished { .. } => self.finished = true,
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

    fn insert(&mut self, path: Box<str>, size: u64) {
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
            partial: !self.finished,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::{scan, scan_with_events, ScanOptions, ScanProgress};
    use std::fs;

    fn ev(generation: u64, root: &str, path: &str, size: u64) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.into(),
            kind: EventKind::DirComplete { path: path.into(), size },
        }
    }

    #[test]
    fn full_channel_drops_events_and_never_blocks() {
        let (sink, _rx) = PreviewEvents::with_bound(7, Path::new("/tmp"), 2);
        for i in 0..5 {
            sink.emit(EventKind::DirComplete { path: format!("/tmp/d{i}").into(), size: i });
        }
        assert_eq!(sink.dropped(), 3);
        assert_eq!(sink.generation(), 7);
    }

    #[test]
    fn collector_ignores_foreign_generation_and_root() {
        let mut c = PreviewCollector::new(1, "/root", 5);
        let now = Instant::now();
        assert!(c.push(&ev(2, "/root", "/root/a", 10), now).is_none());
        assert!(c.push(&ev(1, "/other", "/other/a", 10), now).is_none());
        assert_eq!(c.dirs_completed(), 0);
        assert_eq!(c.published(), 0);
    }

    #[test]
    fn collector_throttles_to_the_interval_and_publishes_on_finish() {
        let mut c = PreviewCollector::new(1, "/root", 5);
        let t0 = Instant::now();
        assert!(c.push(&ev(1, "/root", "/root/a", 10), t0).is_some());
        assert!(c.push(&ev(1, "/root", "/root/b", 20), t0 + Duration::from_millis(100)).is_none());
        let s = c.push(&ev(1, "/root", "/root/c", 30), t0 + Duration::from_millis(300)).unwrap();
        assert_eq!(s.largest.len(), 3);
        assert!(s.partial && !s.finished);
        let fin = ScanEvent { generation: 1, root: "/root".into(), kind: EventKind::Finished { cancelled: false } };
        let s = c.push(&fin, t0 + Duration::from_millis(310)).unwrap();
        assert!(s.finished && !s.partial);
        assert_eq!(c.published(), 3);
    }

    #[test]
    fn collector_keeps_largest_first_capped_at_n() {
        let mut c = PreviewCollector::new(1, "/root", 2);
        let now = Instant::now();
        c.push(&ev(1, "/root", "/root/small", 5), now);
        c.push(&ev(1, "/root", "/root/big", 50), now);
        let s = c.push(&ev(1, "/root", "/root/mid", 20), now + PREVIEW_INTERVAL).unwrap();
        let sizes: Vec<u64> = s.largest.iter().map(|(_, s)| *s).collect();
        assert_eq!(sizes, vec![50, 20]);
        let paths: Vec<&str> = s.largest.iter().map(|(p, _)| &**p).collect();
        assert_eq!(paths, vec!["/root/big", "/root/mid"]);
    }

    /// Fixture: root with two subdirectories and files of known allocated size
    /// (sparse files keep st_blocks at 0, so write real bytes).
    fn fixture(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("spz-events-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("alpha")).unwrap();
        fs::create_dir_all(dir.join("beta/nested")).unwrap();
        fs::write(dir.join("alpha/f1"), vec![1u8; 4096]).unwrap();
        fs::write(dir.join("beta/f2"), vec![1u8; 8192]).unwrap();
        fs::write(dir.join("beta/nested/f3"), vec![1u8; 4096]).unwrap();
        dir.canonicalize().unwrap()
    }

    fn drain(rx: Receiver<ScanEvent>) -> Vec<ScanEvent> {
        let mut out = Vec::new();
        while let Ok(ev) = rx.recv_timeout(Duration::from_millis(500)) {
            out.push(ev);
        }
        out
    }

    #[test]
    fn events_are_bound_to_generation_and_canonical_root() {
        let root = fixture("bind");
        let (sink, rx) = PreviewEvents::new(42, &root);
        let progress = ScanProgress::default();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let events = drain(rx);
        let canon = root.to_string_lossy().into_owned();
        assert!(!events.is_empty());
        for e in &events {
            assert_eq!(e.generation, 42);
            assert_eq!(*e.root, *canon);
        }
        // Every readable directory completes exactly once, then one Finished.
        let mut completes: Vec<&str> = events
            .iter()
            .filter_map(|e| match &e.kind {
                EventKind::DirComplete { path, .. } => Some(&**path),
                _ => None,
            })
            .collect();
        completes.sort_unstable();
        let mut want: Vec<String> = [&root, &root.join("alpha"), &root.join("beta"), &root.join("beta/nested")]
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        want.sort_unstable();
        assert_eq!(completes, want);
        assert!(matches!(events.last().map(|e| &e.kind), Some(EventKind::Finished { cancelled: false })));
        // Parity: the authoritative tree is identical to a plain scan.
        let plain = scan(&root, &ScanOptions::default(), &ScanProgress::default()).unwrap();
        assert_eq!(tree.items, plain.items);
        assert_eq!(tree.size[0], plain.size[0]);
        assert!(!tree.cancelled);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn cancelled_scan_reports_finished_cancelled() {
        let root = fixture("cancel");
        let (sink, rx) = PreviewEvents::new(1, &root);
        let progress = ScanProgress::default();
        progress.cancel();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        assert!(tree.cancelled);
        let events = drain(rx);
        assert!(matches!(events.last().map(|e| &e.kind), Some(EventKind::Finished { cancelled: true })));
        // A cancelled walk emits no DirComplete for incomplete directories.
        assert!(events.iter().all(|e| !matches!(e.kind, EventKind::DirComplete { .. })));
        let _ = fs::remove_dir_all(&root);
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
        let canon = root.to_string_lossy().into_owned();
        let (sink, rx) = PreviewEvents::new(9, &root);
        let progress = ScanProgress::default();
        let tree = scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap();
        let events = drain(rx);
        let mut c = PreviewCollector::new(9, &canon, 10);
        let mut now = Instant::now();
        let mut last = None;
        for e in &events {
            if let Some(s) = c.push(e, now) {
                last = Some(s);
            }
            now += Duration::from_millis(1);
        }
        let s = last.unwrap();
        assert!(s.finished && !s.partial);
        assert_eq!(s.generation, 9);
        assert_eq!(*s.root, *canon);
        assert_eq!(s.dirs_completed, 4);
        // The root's own completion carries the full tree total.
        let root_total = s.largest.iter().find(|(p, _)| &**p == &*canon).map(|(_, sz)| *sz);
        assert_eq!(root_total, Some(tree.size[0]));
        let _ = fs::remove_dir_all(&root);
    }
}
