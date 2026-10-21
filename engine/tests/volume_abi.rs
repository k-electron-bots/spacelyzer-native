//! The coreutils-oracle test is Linux-only; the invariant-only test runs everywhere. The oracle is coreutils `stat -f`, an independent implementation of the same statvfs call, so this checks the ABI plumbing, unit
//! conversion and error mapping, not that statvfs figures mean "space used by files".
use spacelyzer_engine::ffi::*;
use std::ffi::CString;

#[cfg(target_os = "linux")]
fn stat_f(path: &str) -> (u64, u64, u64, u64) {
    let o = std::process::Command::new("stat").args(["-f", "-c", "%S %b %f %a", path]).output().expect("stat -f");
    assert!(o.status.success(), "{:?}", o);
    let v: Vec<u64> = String::from_utf8(o.stdout).unwrap().split_whitespace().map(|x| x.parse().unwrap()).collect();
    (v[0], v[1], v[2], v[3])
}
fn call(path: &str) -> (SpzVolume, i32) {
    let c = CString::new(path).unwrap(); let mut v = SpzVolume::default(); let mut st = -1;
    unsafe { spz_volume_info_status(c.as_ptr(), &mut v, &mut st) }; (v, st)
}

// Linux only: the oracle is GNU coreutils `stat -f -c`. Off Linux this test does not exist (it is absent from the run, not skipped-as-ok).
#[cfg(target_os = "linux")]
#[test]
fn real_filesystems_match_stat_f_and_are_internally_consistent() {
    let mut checked = 0;
    for p in ["/", "/tmp", "/proc", "/dev/shm"] {
        if !std::path::Path::new(p).exists() { continue; }
        let (v, st) = call(p); assert_eq!(st, 0, "{p}");
        let (bs, blocks, free, avail) = stat_f(p);
        // Free counts can legitimately change between the two reads on a live filesystem; total and unit cannot.
        assert_eq!((v.block_size, v.total_bytes), (bs, blocks * bs), "{p}");
        assert!(v.free_bytes % bs == 0 && v.available_bytes % bs == 0);
        assert!(v.available_bytes <= v.free_bytes && v.free_bytes <= v.total_bytes || v.total_bytes == 0, "{p}: {:?}", (v.total_bytes, v.free_bytes, v.available_bytes));
        let _ = (free, avail);
        assert_eq!(v.os_errno, 0);
        if v.total_bytes > 0 { checked += 1; }
    }
    assert!(checked >= 1, "precondition: at least one filesystem with nonzero capacity was compared");
}

#[test]
fn a_file_path_works_and_errors_are_distinct_with_errno() {
    let f = std::env::temp_dir().join(format!("vol-{}", std::process::id())); std::fs::write(&f, b"x").unwrap();
    let (v, st) = call(f.to_str().unwrap()); assert_eq!(st, 0); assert!(v.total_bytes > 0);
    let (v, st) = call("/definitely/not/here-xyz"); assert_eq!(st, 6); assert_eq!(v.os_errno, 2); assert_eq!((v.total_bytes, v.free_bytes, v.flags), (0, 0, 0));
    let mut v = SpzVolume { total_bytes: 77, ..Default::default() }; let mut st = -1;
    unsafe { spz_volume_info_status(std::ptr::null(), &mut v, &mut st) }; assert_eq!((st, v.total_bytes), (3, 77), "null path leaves out untouched");
    let c = CString::new("/").unwrap(); st = -1;
    unsafe { spz_volume_info_status(c.as_ptr(), std::ptr::null_mut(), &mut st) }; assert_eq!(st, 3);
    let _ = std::fs::remove_file(f);
}

#[test]
fn struct_layout_matches_the_header_static_assert() {
    use std::mem::{offset_of, size_of};
    assert_eq!((size_of::<SpzVolume>(), offset_of!(SpzVolume, block_size), offset_of!(SpzVolume, os_errno), offset_of!(SpzVolume, flags)), (40, 24, 32, 36));
}

/// Runs everywhere. INVARIANT-ONLY: no independent oracle, so it cannot catch a wrong number, only an impossible one.
#[test]
fn real_filesystems_satisfy_internal_invariants_only() {
    let mut checked = 0;
    for p in ["/", "/tmp"] {
        let (v, st) = call(p); assert_eq!(st, 0, "{p}");
        assert!(v.block_size > 0 || v.total_bytes == 0, "{p}");
        let bs = v.block_size.max(1);
        assert!(v.total_bytes % bs == 0 && v.free_bytes % bs == 0 && v.available_bytes % bs == 0, "{p}");
        assert!(v.available_bytes <= v.free_bytes && v.free_bytes <= v.total_bytes, "{p}: {:?}", (v.total_bytes, v.free_bytes, v.available_bytes));
        assert_eq!(v.os_errno, 0);
        if v.total_bytes > 0 { checked += 1; }
    }
    assert!(checked >= 1, "precondition: at least one filesystem with nonzero capacity");
}
