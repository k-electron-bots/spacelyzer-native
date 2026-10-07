//! Preview publication driver (milestone 2, engine slice C - code-only, no UI).
//!
//! Ties the three slice-A/B pieces into one consumer-side object the app can drive
//! from a background thread: a `PreviewReceiver` is drained event by event; every
//! event is ADMITTED to the identity `PreviewRegistry` first and reaches the throttled
//! `PreviewCollector` (and any publication) only when admission accepts. Rejected
//! records (outside root, foreign volume, changed identity, cap full) never become
//! visible, and they mark the generation: every later publication stays `partial`.
//! Registry records and ranking rows share one key - the registry's canonical stored
//! path - so in-root symlink/dotdot aliases never appear as a second spelling, and an
//! identity rename updates its single row in both stores. Publications come out one
//! at a time, never more than one per event.
//!
//! The driver's own generation/root gate stands in front of both stores. Data events
//! are also scope-checked independently by the collector and by `admit`, but the
//! registry's finish path trusts its caller: this gate is the only thing keeping a
//! FOREIGN terminal event from dropping the live generation and freezing the driver.
//!
//! Terminal semantics: on `Finished` the driver drops the registry's generation (the
//! authoritative `Tree` supersedes every preview record) and emits exactly one
//! `Publication::Finished`. After that the driver is absorbing: later events publish
//! nothing and admit nothing.

use crate::events::{
    Admit, EventKind, PreviewCollector, PreviewReceiver, PreviewRegistry, PreviewSnapshot, Recv,
    ScanEvent,
};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// One batched publication from the driver. The app swaps its visible preview in one
/// shot; it never receives partial per-event updates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Publication {
    /// Throttled interim preview (may be partial; check `PreviewSnapshot::partial`).
    Interim(PreviewSnapshot),
    /// The terminal publication. The registry generation was dropped; after this the
    /// driver publishes nothing more.
    Finished(PreviewSnapshot),
}

pub struct PreviewDriver {
    generation: u64,
    root: PathBuf,
    collector: PreviewCollector,
    registry: PreviewRegistry,
    finished: bool,
    /// A record was rejected at admission or invalidated at reconcile: the visible
    /// preview no longer tracks what the scan covered, so every later publication of
    /// this generation stays partial. Only the authoritative `Tree` clears that.
    impaired: bool,
}

impl PreviewDriver {
    /// `root` must be the canonical scan root; `root_dev` its volume (from a stat at
    /// scan start); `n` caps the collector's largest list.
    pub fn new(generation: u64, root: &Path, root_dev: u64, n: usize) -> Self {
        PreviewDriver {
            generation,
            root: root.to_path_buf(),
            collector: PreviewCollector::new(generation, root, n),
            registry: PreviewRegistry::new(generation, root, root_dev),
            finished: false,
            impaired: false,
        }
    }

    /// Feed one event. Foreign generation or root: refused here (see the module docs
    /// for why the gate is load-bearing on the terminal path). Data events are
    /// admitted to the registry FIRST and reach the collector and publications only
    /// on `Admit::Admitted`. On the terminal event the registry generation is dropped
    /// before the final snapshot is published. Absorbing after `Finished`.
    pub fn pump(&mut self, ev: &ScanEvent, now: Instant) -> Option<Publication> {
        if self.finished {
            return None;
        }
        if ev.generation != self.generation || ev.root != self.root {
            return None;
        }
        match &ev.kind {
            EventKind::DirComplete { path, size, id } => {
                // The identity's previous home, if any: a rename moves the path, not
                // the (dev, ino) key, so the old spelling is found by identity.
                let prior = self.registry.record_by_key(id.dev, id.ino).map(|r| r.path.clone());
                // Central invalidation, one path shared with `reconcile`: a stale row
                // leaves BOTH stores, so a rejected re-admission can never leave a
                // ghost row behind - at the event's path AND at the identity's old
                // path. A still-valid row is kept. No fs probes when nothing is held.
                let _ = self.invalidate_stale(path);
                if let Some(old) = prior.as_deref() {
                    if old != path {
                        let _ = self.invalidate_stale(old);
                    }
                }
                match self.registry.admit(ev) {
                    Admit::Admitted => {
                        // Publish under the registry's canonical stored path: registry
                        // records and ranking rows share one key, and in-root
                        // symlink/dotdot aliases never reach the ranking as a second
                        // spelling (which no reconcile could then remove).
                        let canon = self
                            .registry
                            .record_by_key(id.dev, id.ino)
                            .map(|r| r.path.clone())
                            .unwrap_or_else(|| path.clone());
                        // Identity rename: one ranking row per identity - the old
                        // spelling leaves when the new one lands.
                        if let Some(old) = prior {
                            if old != canon {
                                self.collector.remove_path(&old);
                            }
                        }
                        let admitted = ScanEvent {
                            generation: ev.generation,
                            root: ev.root.clone(),
                            kind: EventKind::DirComplete { path: canon, size: *size, id: *id },
                        };
                        let snap = self.collector.push(&admitted, now);
                        Self::publish(snap, self.impaired, false)
                    }
                    _ => {
                        // Rejected (outside root, foreign volume, changed identity,
                        // cap full): the record never reaches the visible ranking,
                        // and this generation's publications stay partial.
                        self.impaired = true;
                        None
                    }
                }
            }
            EventKind::Finished { .. } => {
                self.registry.finish(self.generation);
                self.finished = true;
                // The collector always publishes on Finished; a None here would mean a
                // foreign event slipped past the gate above - unreachable, but stay
                // absorbing rather than publish a lie.
                let snap = self.collector.push(ev, now);
                Self::publish(snap, self.impaired, true)
            }
        }
    }

    /// Re-verify one held row against the live filesystem. A vanished, unreadable, or
    /// identity-replaced row is removed from the registry AND from the visible
    /// ranking, and later publications stay partial. True when the row is held and
    /// still valid. Reconciling a path the driver never held is a no-op (false).
    /// An in-root alias (symlink, `..`) of a LIVE directory resolves to the canonical
    /// stored path first; an alias of a vanished directory cannot resolve and is a
    /// no-op - reconcile the canonical spelling.
    pub fn reconcile(&mut self, path: &Path) -> bool {
        let canon = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let before = self.registry.len();
        if self.registry.reconcile(&canon).is_some() {
            return true;
        }
        // Not held (anymore): no row may stay visible under this path either. Any
        // removal - registry or ranking - is an invalidation and stays partial.
        let registry_removed = self.registry.len() < before;
        let ranking_removed = self.collector.remove_path(&canon);
        if registry_removed || ranking_removed {
            self.impaired = true;
        }
        false
    }

    /// The central invalidation both callers share: if a held row for `path` fails
    /// re-verification it leaves the registry AND the ranking. True when a row was
    /// removed. Never touches a still-valid row. Impairment is the caller's policy:
    /// `reconcile` (app-initiated) impairs; the pump purge leaves it to the admit
    /// verdict, so a clean replacement or rename self-heals.
    fn invalidate_stale(&mut self, path: &Path) -> bool {
        let before = self.registry.len();
        if self.registry.reconcile(path).is_some() {
            return false; // row held and still valid
        }
        if self.registry.len() < before {
            self.collector.remove_path(path);
            return true;
        }
        false
    }

    /// The provisional records admitted so far (identity-bound, same volume).
    pub fn registry(&self) -> &PreviewRegistry {
        &self.registry
    }

    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// Test-only: plant a fabricated registry record (stale-row traps).
    #[cfg(test)]
    fn plant_for_test(&mut self, record: crate::events::PreviewRecord) {
        self.registry.plant_record(record);
    }

    fn publish(snap: Option<PreviewSnapshot>, impaired: bool, terminal: bool) -> Option<Publication> {
        snap.map(|mut s| {
            s.partial = s.partial || impaired;
            if terminal {
                Publication::Finished(s)
            } else {
                Publication::Interim(s)
            }
        })
    }
}

/// Why `drive` returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DriveOutcome {
    /// The terminal publication was delivered. Whether the scan itself completed or
    /// cancelled is on the terminal snapshot, not here.
    Terminal,
    /// The channel closed before the terminal event: the scan died without
    /// finishing. No terminal publication exists; everything already shown stays
    /// partial. Distinct from a silent interval, which is NOT an outcome.
    Disconnected,
}

/// Drain a receiver to its terminal event, publishing through `on_pub` with a real
/// clock. Blocks the calling thread; running it off the main thread is the caller's
/// requirement, nothing here enforces it. Pairing is caller-controlled too: the
/// driver refuses events whose generation/root differ from its own binding, but
/// handing it the receiver of the SAME scan is the caller's job - no automatic
/// same-scan pairing is claimed. Silent intervals
/// (a slow scan emitting nothing for a while) are waited through, never treated as
/// the end: the loop leaves only on the terminal publication or on the channel
/// closing without one. Returns the publication count and why it stopped.
pub fn drive(rx: &PreviewReceiver, driver: &mut PreviewDriver, mut on_pub: impl FnMut(Publication)) -> (u64, DriveOutcome) {
    let mut published = 0u64;
    loop {
        match rx.recv_timeout_kind(Duration::from_millis(500)) {
            Recv::Event(ev) => {
                if let Some(p) = driver.pump(&ev, Instant::now()) {
                    let terminal = matches!(p, Publication::Finished(_));
                    on_pub(p);
                    published += 1;
                    if terminal {
                        return (published, DriveOutcome::Terminal);
                    }
                }
            }
            Recv::Timeout => {}
            Recv::Closed => return (published, DriveOutcome::Disconnected),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::PreviewEvents;
    use crate::scan::{scan_with_events, ScanOptions, ScanProgress};
    use std::fs;

    fn fixture(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("spz-preview-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("alpha")).unwrap();
        fs::create_dir_all(dir.join("beta/nested")).unwrap();
        fs::write(dir.join("alpha/f1"), vec![1u8; 4096]).unwrap();
        fs::write(dir.join("beta/f2"), vec![1u8; 8192]).unwrap();
        fs::write(dir.join("beta/nested/f3"), vec![1u8; 4096]).unwrap();
        dir.canonicalize().unwrap()
    }

    fn root_dev(root: &Path) -> u64 {
        use std::os::unix::fs::MetadataExt;
        fs::symlink_metadata(root).unwrap().dev()
    }

    fn dir_ev(generation: u64, root: &Path, path: &Path, size: u64) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::DirComplete { path: path.to_path_buf(), size, id: crate::events::ScanIdentity::live(path).unwrap() },
        }
    }

    fn fin_ev(generation: u64, root: &Path) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::Finished { cancelled: false, complete: true, previews_complete: true, dropped: 0 },
        }
    }

    #[test]
    fn driver_publishes_interim_then_exactly_one_finished_and_is_absorbing() {
        let root = fixture("drive");
        let (sink, rx) = PreviewEvents::new(7, &root);
        let progress = ScanProgress::default();
        let mut drv = PreviewDriver::new(7, &root, root_dev(&root), 10);
        let mut pubs = Vec::new();
        let t0 = Instant::now();
        let tree = std::thread::scope(|s| {
            let h = s.spawn(|| scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap());
            // Pump with a fast-forwarded clock so every event is publishable.
            let mut i = 0u64;
            loop {
                match rx.recv_timeout_kind(Duration::from_millis(500)) {
                    Recv::Event(ev) => {
                        if let Some(p) = drv.pump(&ev, t0 + Duration::from_millis(251 * i)) {
                            i += 1;
                            pubs.push(p);
                        }
                    }
                    Recv::Timeout => {}
                    Recv::Closed => break,
                }
            }
            h.join().unwrap()
        });
        assert!(!tree.cancelled);
        let finished = pubs.iter().filter(|p| matches!(p, Publication::Finished(_))).count();
        assert_eq!(finished, 1, "exactly one terminal publication: {pubs:?}");
        assert!(matches!(pubs.last(), Some(Publication::Finished(_))), "terminal is last");
        for p in &pubs[..pubs.len() - 1] {
            assert!(matches!(p, Publication::Interim(_)), "every earlier publication is interim");
        }
        let Some(Publication::Finished(s)) = pubs.last() else { unreachable!() };
        assert!(s.finished && s.complete && !s.partial && !s.cancelled);
        assert_eq!(s.dirs_completed, 4);
        // The registry generation was dropped at the terminal.
        assert!(drv.registry().is_empty());
        assert!(drv.is_finished());
        // Absorbing: a late event publishes nothing and admits nothing.
        let late = dir_ev(7, &root, &root.join("alpha"), 100);
        assert!(drv.pump(&late, t0 + Duration::from_secs(60)).is_none());
        assert!(drv.registry().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn driver_binds_registry_to_generation_and_root() {
        let root = fixture("bind");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 5);
        let now = Instant::now();
        // Foreign generation, path inside root, same volume: refused at the gate.
        let foreign_gen = dir_ev(2, &root, &root.join("alpha"), 100);
        assert!(drv.pump(&foreign_gen, now).is_none());
        // Foreign root: refused at the gate.
        let other_root = root.parent().unwrap().to_path_buf();
        let foreign_root = ScanEvent { generation: 1, root: other_root, kind: dir_ev(1, &root, &root.join("alpha"), 100).kind };
        assert!(drv.pump(&foreign_root, now).is_none());
        assert!(drv.registry().is_empty(), "nothing foreign reached the registry");
        // Own generation: admitted and published.
        let own = dir_ev(1, &root, &root.join("alpha"), 100);
        assert!(matches!(drv.pump(&own, now), Some(Publication::Interim(_))));
        assert_eq!(drv.registry().len(), 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn foreign_generation_terminal_leaves_driver_and_registry_intact() {
        let root = fixture("foreign-gen-fin");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 5);
        let now = Instant::now();
        let own = dir_ev(1, &root, &root.join("alpha"), 100);
        assert!(matches!(drv.pump(&own, now), Some(Publication::Interim(_))));
        assert_eq!(drv.registry().len(), 1);
        // A terminal event from ANOTHER generation: without the gate this calls
        // registry.finish(1), kills the live row, and freezes the driver.
        let foreign = fin_ev(2, &root);
        assert!(drv.pump(&foreign, now).is_none());
        assert!(!drv.is_finished(), "foreign terminal must not finish the driver");
        assert_eq!(drv.registry().len(), 1, "foreign terminal must not drop the live generation");
        // The correct terminal still succeeds.
        match drv.pump(&fin_ev(1, &root), now) {
            Some(Publication::Finished(s)) => assert!(!s.partial),
            other => panic!("correct terminal publishes Finished: {other:?}"),
        }
        assert!(drv.registry().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn foreign_root_terminal_leaves_driver_and_registry_intact() {
        let root = fixture("foreign-root-fin");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 5);
        let now = Instant::now();
        let own = dir_ev(1, &root, &root.join("alpha"), 100);
        assert!(matches!(drv.pump(&own, now), Some(Publication::Interim(_))));
        assert_eq!(drv.registry().len(), 1);
        let other_root = root.parent().unwrap().to_path_buf();
        let foreign = fin_ev(1, &other_root);
        assert!(drv.pump(&foreign, now).is_none());
        assert!(!drv.is_finished(), "foreign-root terminal must not finish the driver");
        assert_eq!(drv.registry().len(), 1);
        match drv.pump(&fin_ev(1, &root), now) {
            Some(Publication::Finished(s)) => assert!(!s.partial),
            other => panic!("correct terminal publishes Finished: {other:?}"),
        }
        assert!(drv.registry().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rejected_records_never_publish_and_the_terminal_stays_partial() {
        let root = fixture("reject");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let now = Instant::now();
        // An event whose target vanishes before admission: admit rejects it (Replaced).
        let ghost = root.join("ghost");
        fs::create_dir_all(&ghost).unwrap();
        let ev_ghost = dir_ev(1, &root, &ghost, 999_999);
        fs::remove_dir_all(&ghost).unwrap();
        assert!(drv.pump(&ev_ghost, now).is_none(), "a rejected record publishes nothing");
        assert!(drv.registry().is_empty(), "a rejected record is not held");
        // A valid record publishes; the ghost never appears in the ranking.
        let own = dir_ev(1, &root, &root.join("alpha"), 100);
        let Some(Publication::Interim(s)) = drv.pump(&own, now) else { panic!("admitted record publishes") };
        assert_eq!(s.dirs_completed, 1, "only admitted records count");
        assert!(s.largest.iter().all(|(p, _)| *p != ghost));
        // The terminal stays partial even though the scan itself was clean: a record
        // was rejected, so the preview cannot claim full coverage.
        match drv.pump(&fin_ev(1, &root), now) {
            Some(Publication::Finished(s)) => {
                assert!(s.partial, "rejection keeps the terminal partial");
                assert!(s.largest.iter().all(|(p, _)| *p != ghost));
            }
            other => panic!("terminal publishes Finished: {other:?}"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn registry_replacement_purges_the_stale_row_before_admission() {
        let root = fixture("purge");
        let target = root.join("alpha");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let now = Instant::now();
        // An earlier record for the path, keyed by an identity no real inode will
        // share. Planted, not fs-made: this filesystem can recycle inode and ctime
        // together, which would make a fs-only replacement invisible to the key.
        let mut fake = crate::events::ScanIdentity::live(&target).unwrap();
        fake.ino = !fake.ino;
        drv.plant_for_test(crate::events::PreviewRecord { path: target.clone(), size: 100, id: fake, generation: 1 });
        assert_eq!(drv.registry().len(), 1);
        // The directory is replaced on disk: new live identity at the same path.
        fs::remove_dir_all(&target).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("g"), vec![1u8; 4096]).unwrap();
        let ev = dir_ev(1, &root, &target, 999);
        assert!(matches!(drv.pump(&ev, now), Some(Publication::Interim(_))));
        // The stale row is purged at pump time; the fresh admit replaces it.
        assert_eq!(drv.registry().len(), 1, "replacement updates, never duplicates");
        assert!(drv.reconcile(&target), "the held row tracks the live replacement");
        assert_eq!(drv.registry().len(), 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn ranking_replacement_updates_the_row_instead_of_duplicating_it() {
        let root = fixture("replace");
        let target = root.join("alpha");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let t0 = Instant::now();
        let ev1 = dir_ev(1, &root, &target, 100);
        assert!(matches!(drv.pump(&ev1, t0), Some(Publication::Interim(_))));
        // Replace the directory on disk, then re-emit the event.
        fs::remove_dir_all(&target).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("g"), vec![1u8; 4096]).unwrap();
        let ev2 = dir_ev(1, &root, &target, 999);
        let Some(Publication::Interim(s)) = drv.pump(&ev2, t0 + Duration::from_millis(251)) else {
            panic!("replacement event publishes")
        };
        assert_eq!(drv.registry().len(), 1, "registry keeps one row for the path");
        let rows: Vec<_> = s.largest.iter().filter(|(p, _)| *p == target).collect();
        assert_eq!(rows.len(), 1, "one ranking row per path");
        assert_eq!(rows[0].1, 999, "the row carries the new size");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn driver_reconcile_removes_invalidated_rows_from_registry_and_ranking() {
        let root = fixture("drv-reconcile");
        let alpha = root.join("alpha");
        let beta = root.join("beta");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let t0 = Instant::now();
        let ev_a = dir_ev(1, &root, &alpha, 100);
        let ev_b = dir_ev(1, &root, &beta, 200);
        assert!(matches!(drv.pump(&ev_a, t0), Some(Publication::Interim(_))));
        let Some(Publication::Interim(s)) = drv.pump(&ev_b, t0 + Duration::from_millis(251)) else {
            panic!("second record publishes")
        };
        assert_eq!(s.largest.len(), 2);
        assert_eq!(drv.registry().len(), 2);
        // A live row reconciles true and changes nothing.
        assert!(drv.reconcile(&alpha));
        assert_eq!(drv.registry().len(), 2);
        // Invalidate beta on disk: reconcile removes it from BOTH the registry and
        // the visible ranking, and the terminal stays partial.
        fs::remove_dir_all(&beta).unwrap();
        assert!(!drv.reconcile(&beta), "invalidated row reconciles false");
        assert_eq!(drv.registry().len(), 1, "registry drops the invalidated row");
        match drv.pump(&fin_ev(1, &root), t0 + Duration::from_millis(502)) {
            Some(Publication::Finished(s)) => {
                assert!(s.partial, "invalidation keeps the terminal partial");
                assert!(s.largest.iter().all(|(p, _)| *p != beta), "ranking drops the invalidated row");
                assert_eq!(s.largest.len(), 1);
            }
            other => panic!("terminal publishes Finished: {other:?}"),
        }
        // Reconciling a path never held is a no-op, not an invalidation.
        let mut drv2 = PreviewDriver::new(9, &root, root_dev(&root), 10);
        assert!(!drv2.reconcile(&root.join("beta/nested")));
        match drv2.pump(&fin_ev(9, &root), t0) {
            Some(Publication::Finished(s)) => assert!(!s.partial, "a no-op reconcile impairs nothing"),
            other => panic!("terminal publishes Finished: {other:?}"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rejected_re_admission_after_purge_leaves_no_ghost_in_registry_or_ranking() {
        let root = fixture("ghost");
        let alpha = root.join("alpha");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let t0 = Instant::now();
        let ev1 = dir_ev(1, &root, &alpha, 100);
        assert!(matches!(drv.pump(&ev1, t0), Some(Publication::Interim(_))));
        assert_eq!(drv.registry().len(), 1);
        // alpha vanishes; a STALE event (identity captured before the delete) re-arrives.
        let stale = dir_ev(1, &root, &alpha, 100);
        fs::remove_dir_all(&alpha).unwrap();
        assert!(drv.pump(&stale, t0 + Duration::from_millis(251)).is_none(), "stale event is rejected");
        assert!(drv.registry().is_empty(), "the old row is purged from the registry");
        match drv.pump(&fin_ev(1, &root), t0 + Duration::from_millis(502)) {
            Some(Publication::Finished(s)) => {
                assert!(s.partial, "terminal stays provisional after the invalidation");
                assert!(s.largest.is_empty(), "no ghost row publishes: {:?}", s.largest);
            }
            other => panic!("terminal publishes Finished: {other:?}"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn two_spellings_of_one_identity_publish_one_canonical_row() {
        let root = fixture("spellings");
        let target = root.join("alpha");
        let link = root.join("link-alpha");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let dotdot = root.join("beta/../alpha");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let t0 = Instant::now();
        let id = crate::events::ScanIdentity::live(&target).unwrap();
        // The same identity under two alias spellings: an in-root symlink and a `..` path.
        for (i, spelling) in [link.clone(), dotdot.clone()].into_iter().enumerate() {
            let ev = ScanEvent { generation: 1, root: root.clone(),
                kind: EventKind::DirComplete { path: spelling, size: 100, id } };
            let now = t0 + Duration::from_millis(251 * i as u64);
            assert!(matches!(drv.pump(&ev, now), Some(Publication::Interim(_))));
        }
        assert_eq!(drv.registry().len(), 1, "one registry row per identity");
        // The canonical spelling reconciles; an alias of the LIVE dir resolves to it too.
        assert!(drv.reconcile(&target));
        assert!(drv.reconcile(&link), "alias of a live dir resolves to the canonical row");
        match drv.pump(&fin_ev(1, &root), t0 + Duration::from_millis(502)) {
            Some(Publication::Finished(s)) => {
                let rows: Vec<_> = s.largest.iter().filter(|(p, _)| *p == target).collect();
                assert_eq!(rows.len(), 1, "one canonical ranking row: {:?}", s.largest);
                assert!(s.largest.iter().all(|(p, _)| *p != link && *p != dotdot), "no alias spelling publishes");
                assert!(!s.partial, "clean aliases do not impair");
            }
            other => panic!("terminal publishes Finished: {other:?}"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn identity_rename_updates_both_stores_to_the_new_path() {
        let root = fixture("rename");
        let alpha = root.join("alpha");
        let renamed = root.join("renamed");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let t0 = Instant::now();
        let ev1 = dir_ev(1, &root, &alpha, 100);
        assert!(matches!(drv.pump(&ev1, t0), Some(Publication::Interim(_))));
        // Rename keeps the inode: the (dev, ino) key survives; the path moves.
        fs::rename(&alpha, &renamed).unwrap();
        let ev2 = dir_ev(1, &root, &renamed, 100);
        let Some(Publication::Interim(s)) = drv.pump(&ev2, t0 + Duration::from_millis(251)) else {
            panic!("renamed event publishes")
        };
        assert_eq!(drv.registry().len(), 1, "one registry row per identity");
        assert!(drv.reconcile(&renamed), "the row lives at the new path");
        assert!(s.largest.iter().all(|(p, _)| *p != alpha), "old spelling left the ranking: {:?}", s.largest);
        let rows: Vec<_> = s.largest.iter().filter(|(p, _)| *p == renamed).collect();
        assert_eq!(rows.len(), 1, "new spelling has exactly one row");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rejected_event_for_a_renamed_identity_purges_the_old_row_from_both_stores() {
        let root = fixture("rename-reject");
        let alpha = root.join("alpha");
        let renamed = root.join("renamed");
        let mut drv = PreviewDriver::new(1, &root, root_dev(&root), 10);
        let t0 = Instant::now();
        let ev1 = dir_ev(1, &root, &alpha, 100);
        assert!(matches!(drv.pump(&ev1, t0), Some(Publication::Interim(_))));
        // The identity moves, then vanishes entirely; its event arrives too late.
        fs::rename(&alpha, &renamed).unwrap();
        let ev2 = dir_ev(1, &root, &renamed, 100);
        fs::remove_dir_all(&renamed).unwrap();
        assert!(drv.pump(&ev2, t0 + Duration::from_millis(251)).is_none(), "vanished identity is rejected");
        assert!(drv.registry().is_empty(), "old row purged even though the new admission failed");
        match drv.pump(&fin_ev(1, &root), t0 + Duration::from_millis(502)) {
            Some(Publication::Finished(s)) => {
                assert!(s.partial, "terminal stays provisional after the invalidation");
                assert!(s.largest.is_empty(), "no ghost under either spelling: {:?}", s.largest);
            }
            other => panic!("terminal publishes Finished: {other:?}"),
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn drive_waits_through_silent_intervals_for_a_delayed_first_event_and_gaps() {
        let root = fixture("gaps");
        let (sink, rx) = PreviewEvents::new(5, &root);
        let mut drv = PreviewDriver::new(5, &root, root_dev(&root), 10);
        // Producer: 700ms of silence, an event, a 700ms gap, an event, 700ms, terminal.
        // Every silence exceeds the 500ms poll; none of them may end the drain.
        let alpha = root.join("alpha");
        let beta = root.join("beta");
        let producer = std::thread::spawn(move || {
            let gap = Duration::from_millis(700);
            std::thread::sleep(gap);
            sink.emit(EventKind::DirComplete { path: alpha.clone(), size: 100, id: crate::events::ScanIdentity::live(&alpha).unwrap() });
            std::thread::sleep(gap);
            sink.emit(EventKind::DirComplete { path: beta.clone(), size: 200, id: crate::events::ScanIdentity::live(&beta).unwrap() });
            std::thread::sleep(gap);
            sink.finish(false, true, true);
        });
        let mut seen = Vec::new();
        let (n, outcome) = drive(&rx, &mut drv, |p| seen.push(p));
        producer.join().unwrap();
        assert_eq!(outcome, DriveOutcome::Terminal, "silent intervals are waited through");
        assert!(n >= 1);
        assert!(matches!(seen.last(), Some(Publication::Finished(_))));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn drive_reports_disconnect_when_the_scan_dies_without_a_terminal() {
        let root = fixture("disconnect");
        let (sink, rx) = PreviewEvents::new(6, &root);
        let mut drv = PreviewDriver::new(6, &root, root_dev(&root), 10);
        // The sender dies without finishing: its own outcome, never a silent Terminal.
        drop(sink);
        let (n, outcome) = drive(&rx, &mut drv, |_| {});
        assert_eq!(outcome, DriveOutcome::Disconnected);
        assert_eq!(n, 0);
        assert!(!drv.is_finished());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn drive_blocks_until_terminal_and_counts_publications() {
        let root = fixture("driveblock");
        let (sink, rx) = PreviewEvents::new(3, &root);
        let progress = ScanProgress::default();
        let mut drv = PreviewDriver::new(3, &root, root_dev(&root), 10);
        let mut pubs = Vec::new();
        std::thread::scope(|s| {
            let h = s.spawn(|| scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap());
            let (n, outcome) = drive(&rx, &mut drv, |p| pubs.push(p));
            h.join().unwrap();
            // Real clock: a sub-interval scan may throttle interim publications, but the
            // terminal publication always lands.
            assert!(n >= 1);
            assert_eq!(outcome, DriveOutcome::Terminal);
            assert!(matches!(pubs.last(), Some(Publication::Finished(_))));
        });
        assert!(drv.is_finished());
        assert!(drv.registry().is_empty());
        let _ = fs::remove_dir_all(&root);
    }
}
