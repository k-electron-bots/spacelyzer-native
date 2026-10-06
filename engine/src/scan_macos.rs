//! macOS bulk enumeration via getattrlistbulk(2).
//!
//! Requested attributes (packed in ascending bit order within each group):
//!   common: RETURNED_ATTRS, ERROR, NAME, DEVID, OBJTYPE, MODTIME, FILEID
//!   file:   LINKCOUNT, ALLOCSIZE
//! ERROR is requested so a per-entry failure is reported by the kernel instead of leaving an entry without attributes. Record parsing lives in `bulk_record`
//! (pure, bounds-checked, unit tested on every platform); this file only makes the syscalls.
//! PACK_INVAL_ATTRS is deliberately NOT set, so only attributes that are valid for an entry
//! are packed, and the returned-attributes set says exactly which. That keeps parsing
//! unambiguous. Cross-check against the portable backend with `spz verify <path>` on a Mac.

use crate::bulk_record::*;
use crate::scan::RawEntry;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

const ATTR_BIT_MAP_COUNT: u16 = 5;

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

extern "C" {
    fn getattrlistbulk(
        dirfd: libc::c_int,
        alist: *mut AttrList,
        attribute_buffer: *mut libc::c_void,
        buffer_size: libc::size_t,
        options: u64,
    ) -> libc::c_int;
}

pub(crate) fn enumerate_bulk(dir: &Path) -> std::io::Result<Vec<RawEntry>> {
    let c = CString::new(dir.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from_raw_os_error(libc::EINVAL))?;
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    struct Fd(libc::c_int);
    impl Drop for Fd {
        fn drop(&mut self) {
            unsafe { libc::close(self.0) };
        }
    }
    let _guard = Fd(fd);

    let mut al = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID,
        volattr: 0,
        dirattr: 0,
        fileattr: ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
        forkattr: 0,
    };
    // 8-byte aligned buffer, 128 KiB: a few thousand entries per syscall.
    let mut storage = vec![0u64; 16 * 1024];
    let buf_ptr = storage.as_mut_ptr() as *mut u8;
    let buf_len = storage.len() * 8;
    let mut out = Vec::new();
    let mut dir_failed = false;

    loop {
        let n = unsafe { getattrlistbulk(fd, &mut al, buf_ptr as *mut _, buf_len, 0) };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if n == 0 {
            break;
        }
        let bytes = unsafe { std::slice::from_raw_parts(buf_ptr, buf_len) };
        if parse_batch(&bytes[..buf_len], n as usize, &mut out) {
            dir_failed = true;
        }
    }
    if dir_failed {
        // Some record could not be attributed to a name (or the batch could not be walked): one directory-level entry, never an invented file name.
        out.push(dir_marker());
    }
    Ok(out)
}
