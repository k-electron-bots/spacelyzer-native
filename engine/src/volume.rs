//! Raw filesystem capacity for the volume containing a path, from statvfs(3). These are the kernel's numbers for that one filesystem: they do NOT include
//! APFS purgeable space, local snapshots or container sharing between volumes (Mac-only concepts this module cannot see), so `total - free` must not be
//! presented as "used by files" or as space that deleting something would free.
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VolumeInfo {
    /// f_blocks * f_frsize.
    pub total_bytes: u64,
    /// f_bfree * f_frsize: free blocks including any reserved for the superuser.
    pub free_bytes: u64,
    /// f_bavail * f_frsize: free blocks available to an unprivileged process. Never above `free_bytes` in a consistent report.
    pub available_bytes: u64,
    /// f_frsize, the unit of the three figures above.
    pub block_size: u64,
    /// ST_RDONLY was set.
    pub read_only: bool,
    /// A multiplication overflowed and the figure was clamped to u64::MAX.
    pub saturated: bool,
}

pub fn volume_info(path: &Path) -> Result<VolumeInfo, i32> {
    let c = std::ffi::CString::new(OsStr::as_bytes(path.as_os_str())).map_err(|_| libc::EINVAL)?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(libc::EIO));
    }
    Ok(convert(s.f_frsize as u64, s.f_bsize as u64, s.f_blocks as u64, s.f_bfree as u64, s.f_bavail as u64, s.f_flag as u64))
}

/// Pure statvfs-field conversion, split out so overflow, the f_frsize==0 fallback and the read-only flag can be tested without a special filesystem.
pub(crate) fn convert(frsize: u64, bsize: u64, blocks: u64, bfree: u64, bavail: u64, flag: u64) -> VolumeInfo {
    let fr = if frsize != 0 { frsize } else { bsize };
    let mut saturated = false;
    let mut mul = |b: u64| b.checked_mul(fr).unwrap_or_else(|| { saturated = true; u64::MAX });
    let (total_bytes, free_bytes, available_bytes) = (mul(blocks), mul(bfree), mul(bavail));
    VolumeInfo { total_bytes, free_bytes, available_bytes, block_size: fr, read_only: flag & (libc::ST_RDONLY as u64) != 0, saturated }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn converts_units_falls_back_to_bsize_and_flags_overflow_and_readonly() {
        let v = convert(4096, 512, 10, 4, 3, 0);
        assert_eq!((v.total_bytes, v.free_bytes, v.available_bytes, v.block_size, v.read_only, v.saturated), (40960, 16384, 12288, 4096, false, false));
        let v = convert(0, 512, 10, 4, 3, 0);
        assert_eq!((v.total_bytes, v.block_size), (5120, 512), "f_frsize 0 falls back to f_bsize");
        let v = convert(4096, 4096, u64::MAX / 2, 1, 1, libc::ST_RDONLY as u64);
        assert!(v.saturated && v.total_bytes == u64::MAX && v.free_bytes == 4096 && v.read_only);
        let v = convert(1, 1, u64::MAX, 0, 0, 0);
        assert!(!v.saturated && v.total_bytes == u64::MAX, "exactly u64::MAX does not overflow");
    }
}
