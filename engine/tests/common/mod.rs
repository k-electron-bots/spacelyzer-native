//! Shared test helpers. Not a test binary (it lives in a subdirectory).
//!
//! `made` wraps fixture creation that a platform may legitimately refuse (APFS rejects non-UTF-8 names with EILSEQ).
//! Rust has no runtime "skipped" state, so a bare early `return` would be reported as `ok`. To keep that from reading as a pass:
//!  * Linux: any creation failure panics. A fixture that cannot be built is a failure, never a skip.
//!  * Elsewhere, EILSEQ panics UNLESS `SPZ_ALLOW_PLATFORM_SKIP=1`. With it, the test returns early (cargo still prints `ok`),
//!    prints a SKIPPED line (visible only with `--nocapture`), and appends `<test name>\t<reason>` to the file named by
//!    `SPZ_SKIP_MANIFEST` (default: skipped-tests.txt in the system temp dir). That manifest is the record of what was NOT exercised;
//!    a run's "N passed" must be read together with it.
#![allow(dead_code)]
use std::io::Write;

pub fn made(r: std::io::Result<()>) -> bool {
    match r {
        Ok(()) => true,
        Err(e) if e.raw_os_error() == Some(92) && !cfg!(target_os = "linux") => {
            let name = std::thread::current().name().unwrap_or("?").to_string();
            if std::env::var("SPZ_ALLOW_PLATFORM_SKIP").ok().as_deref() != Some("1") {
                panic!("{name}: this filesystem refuses non-UTF-8 names (EILSEQ), so the case cannot run here. Set SPZ_ALLOW_PLATFORM_SKIP=1 to record it as not exercised instead of failing.");
            }
            let path = std::env::var("SPZ_SKIP_MANIFEST").map(std::path::PathBuf::from).unwrap_or_else(|_| std::env::temp_dir().join("skipped-tests.txt"));
            let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&path).expect("open skip manifest");
            writeln!(f, "{name}\tNOT EXERCISED: non-UTF-8 name refused (EILSEQ)").expect("write skip manifest");
            eprintln!("SKIPPED (NOT exercised, reported ok by cargo): {name}; recorded in {}", path.display());
            false
        }
        Err(e) => panic!("fixture creation failed: {e}"),
    }
}
