//! Shared test helpers. Not a test binary (it lives in a subdirectory).
//!
//! `made` wraps fixture creation that a platform may legitimately refuse (APFS rejects non-UTF-8 names with EILSEQ).
//! Rust has no runtime "skipped" state, so a bare early `return` is reported `ok`. To keep that from reading as a pass:
//!  * Linux: any creation failure panics. A fixture that cannot be built is a failure, never a skip.
//!  * Elsewhere, EILSEQ panics UNLESS `SPZ_ALLOW_PLATFORM_SKIP=1`. Then `SPZ_SKIP_MANIFEST` MUST name an ABSOLUTE path to a file that
//!    the caller created (empty) for THIS run. The helper never creates or defaults it (a missing, relative or unset path panics), but it
//!    does NOT detect a stale file: freshness is the caller's responsibility. Each skip appends one complete line `<test name>\t<reason>\n`
//!    with a single `write_all` on an O_APPEND handle under an in-process mutex. `write_all` may loop over several writes, so there is no
//!    guarantee of a single syscall or of non-interleaving across processes (only a simulation on Linux was run; nothing on APFS or network filesystems). cargo still prints `ok` for the skipped test. A consumer must read the
//!    manifest, list the names, and subtract them from the raw pass total; the raw "N passed" is not the exercised count.
#![allow(dead_code)]
use std::io::Write;
use std::sync::Mutex;

static MANIFEST_LOCK: Mutex<()> = Mutex::new(());

pub fn made(r: std::io::Result<()>) -> bool {
    match r {
        Ok(()) => true,
        Err(e) if e.raw_os_error() == Some(92) && !cfg!(target_os = "linux") => {
            let name = std::thread::current().name().unwrap_or("?").to_string();
            if std::env::var("SPZ_ALLOW_PLATFORM_SKIP").ok().as_deref() != Some("1") {
                panic!("{name}: this filesystem refuses non-UTF-8 names (EILSEQ), so the case cannot run here. Set SPZ_ALLOW_PLATFORM_SKIP=1 and SPZ_SKIP_MANIFEST=<absolute path of a fresh file> to record it as not exercised instead of failing.");
            }
            let path = std::path::PathBuf::from(std::env::var("SPZ_SKIP_MANIFEST").unwrap_or_else(|_| panic!("{name}: SPZ_SKIP_MANIFEST is required with SPZ_ALLOW_PLATFORM_SKIP=1")));
            assert!(path.is_absolute(), "{name}: SPZ_SKIP_MANIFEST must be an absolute path, got {}", path.display());
            let line = format!("{name}\tNOT EXERCISED: non-UTF-8 name refused (EILSEQ)\n");
            let _g = MANIFEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap_or_else(|e| panic!("{name}: manifest {} must be created by the caller before the run: {e}", path.display()));
            f.write_all(line.as_bytes()).expect("write skip manifest");
            eprintln!("SKIPPED (NOT exercised, reported ok by cargo): {name}; recorded in {}", path.display());
            false
        }
        Err(e) => panic!("fixture creation failed: {e}"),
    }
}
