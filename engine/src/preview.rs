//! Preview publication driver (milestone 2, engine slice C - code-only, no UI).
//!
//! Ties the three slice-A/B pieces into one consumer-side object the app can drive
//! from a background thread: a `PreviewReceiver` is drained event by event; every
//! event feeds BOTH the throttled `PreviewCollector` and the identity `PreviewRegistry`;
//! publications come out one at a time, never more than one per event. The driver adds
//! its own generation/root gate in front of the pair as defense in depth; each store
//! also enforces the same scope independently (the collector ignores foreign
//! generation/root, the registry admits only its own generation and root).
//!
//! Terminal semantics: on `Finished` the driver drops the registry's generation (the
//! authoritative `Tree` supersedes every preview record) and emits exactly one
//! `Publication::Finished`. After that the driver is absorbing: later events publish
//! nothing and admit nothing.

use crate::events::{
    EventKind, PreviewCollector, PreviewReceiver, PreviewRegistry, PreviewSnapshot,
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
        }
    }

    /// Feed one event. Foreign generation or root: refused here and, independently,
    /// by BOTH stores (defense in depth - see the module docs). On the
    /// terminal event the registry generation is dropped before the final snapshot is
    /// published. Absorbing after `Finished`.
    pub fn pump(&mut self, ev: &ScanEvent, now: Instant) -> Option<Publication> {
        if self.finished {
            return None;
        }
        if ev.generation != self.generation || ev.root != self.root {
            return None;
        }
        let is_terminal = matches!(ev.kind, EventKind::Finished { .. });
        if is_terminal {
            self.registry.finish(self.generation);
        } else {
            self.registry.admit(ev);
        }
        let snap = self.collector.push(ev, now);
        match (is_terminal, snap) {
            (true, Some(s)) => {
                self.finished = true;
                Some(Publication::Finished(s))
            }
            (true, None) => {
                // The collector always publishes on Finished; a None here would mean a
                // foreign event slipped past the binding above - unreachable, but stay
                // absorbing rather than publish a lie.
                self.finished = true;
                None
            }
            (false, Some(s)) => Some(Publication::Interim(s)),
            (false, None) => None,
        }
    }

    /// The provisional records admitted so far (identity-bound, same volume).
    pub fn registry(&self) -> &PreviewRegistry {
        &self.registry
    }

    pub fn is_finished(&self) -> bool {
        self.finished
    }
}

/// Drain a receiver to its terminal event, publishing through `on_pub` with a real
/// clock. Blocks the calling thread; the app runs this off-main. Returns the number
/// of publications emitted (including the terminal one).
pub fn drive(rx: &PreviewReceiver, driver: &mut PreviewDriver, mut on_pub: impl FnMut(Publication)) -> u64 {
    let mut published = 0u64;
    while let Some(ev) = rx.recv_timeout(Duration::from_millis(500)) {
        if let Some(p) = driver.pump(&ev, Instant::now()) {
            let terminal = matches!(p, Publication::Finished(_));
            on_pub(p);
            published += 1;
            if terminal {
                break;
            }
        }
    }
    published
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

    fn dir_ev(generation: u64, root: &Path, path: &Path, size: u64) -> ScanEvent {
        ScanEvent {
            generation,
            root: root.to_path_buf(),
            kind: EventKind::DirComplete { path: path.to_path_buf(), size, id: crate::events::ScanIdentity::live(path).unwrap() },
        }
    }

    #[test]
    fn driver_publishes_interim_then_exactly_one_finished_and_is_absorbing() {
        let root = fixture("drive");
        use std::os::unix::fs::MetadataExt;
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let (sink, rx) = PreviewEvents::new(7, &root);
        let progress = ScanProgress::default();
        let mut drv = PreviewDriver::new(7, &root, root_dev, 10);
        let mut pubs = Vec::new();
        let t0 = Instant::now();
        let tree = std::thread::scope(|s| {
            let h = s.spawn(|| scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap());
            // Pump with a fast-forwarded clock so every event is publishable.
            let mut i = 0u64;
            while let Some(ev) = rx.recv_timeout(Duration::from_millis(500)) {
                if let Some(p) = drv.pump(&ev, t0 + Duration::from_millis(251 * i)) {
                    i += 1;
                    pubs.push(p);
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
        use std::os::unix::fs::MetadataExt;
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let mut drv = PreviewDriver::new(1, &root, root_dev, 5);
        let now = Instant::now();
        // Foreign generation, path inside root, same volume: the registry alone would
        // admit it (tagged generation 2); the driver must not let it through.
        let foreign_gen = dir_ev(2, &root, &root.join("alpha"), 100);
        assert!(drv.pump(&foreign_gen, now).is_none());
        // Foreign root: ignored by both stores.
        let other_root = root.parent().unwrap().to_path_buf();
        let foreign_root = ScanEvent { generation: 1, root: other_root, kind: dir_ev(1, &root, &root.join("alpha"), 100).kind };
        assert!(drv.pump(&foreign_root, now).is_none());
        assert!(drv.registry().is_empty(), "nothing foreign reached the registry");
        assert_eq!(drv.registry().len(), 0);
        // Own generation: admitted and published.
        let own = dir_ev(1, &root, &root.join("alpha"), 100);
        assert!(matches!(drv.pump(&own, now), Some(Publication::Interim(_))));
        assert_eq!(drv.registry().len(), 1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn drive_blocks_until_terminal_and_counts_publications() {
        let root = fixture("driveblock");
        use std::os::unix::fs::MetadataExt;
        let root_dev = fs::symlink_metadata(&root).unwrap().dev();
        let (sink, rx) = PreviewEvents::new(3, &root);
        let progress = ScanProgress::default();
        let mut drv = PreviewDriver::new(3, &root, root_dev, 10);
        let mut pubs = Vec::new();
        std::thread::scope(|s| {
            let h = s.spawn(|| scan_with_events(&root, &ScanOptions::default(), &progress, &sink).unwrap());
            let n = drive(&rx, &mut drv, |p| pubs.push(p));
            h.join().unwrap();
            // Real clock: a sub-interval scan may throttle interim publications, but the
            // terminal publication always lands.
            assert!(n >= 1);
            assert!(matches!(pubs.last(), Some(Publication::Finished(_))));
        });
        assert!(drv.is_finished());
        assert!(drv.registry().is_empty());
        let _ = fs::remove_dir_all(&root);
    }
}
