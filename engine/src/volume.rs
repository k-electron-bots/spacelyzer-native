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
    let fr = if s.f_frsize != 0 { s.f_frsize as u64 } else { s.f_bsize as u64 };
    let mut saturated = false;
    let mut mul = |blocks: u64| blocks.checked_mul(fr).unwrap_or_else(|| { saturated = true; u64::MAX });
    let (total_bytes, free_bytes, available_bytes) = (mul(s.f_blocks as u64), mul(s.f_bfree as u64), mul(s.f_bavail as u64));
    Ok(VolumeInfo { total_bytes, free_bytes, available_bytes, block_size: fr, read_only: (s.f_flag as u64) & (libc::ST_RDONLY as u64) != 0, saturated })
}
