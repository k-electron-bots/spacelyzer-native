//! macOS bulk enumeration via getattrlistbulk(2).
//!
//! Requested attributes (packed in ascending bit order within each group):
//!   common: RETURNED_ATTRS, NAME, DEVID, OBJTYPE, FILEID
//!   file:   LINKCOUNT, ALLOCSIZE
//! PACK_INVAL_ATTRS is deliberately NOT set, so only attributes that are valid for an entry
//! are packed, and the returned-attributes set says exactly which. That keeps parsing
//! unambiguous. Cross-check against the portable backend with `spz verify <path>` on a Mac.

use crate::scan::RawEntry;
use crate::tree::Kind;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_DEVID: u32 = 0x0000_0002;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_MODTIME: u32 = 0x0000_0400;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;

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

struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn u32(&mut self) -> Option<u32> {
        let b = self.buf.get(self.pos..self.pos + 4)?;
        self.pos += 4;
        Some(u32::from_ne_bytes(b.try_into().ok()?))
    }
    fn i32(&mut self) -> Option<i32> {
        self.u32().map(|v| v as i32)
    }
    fn i64(&mut self) -> Option<i64> {
        let b = self.buf.get(self.pos..self.pos + 8)?;
        self.pos += 8;
        Some(i64::from_ne_bytes(b.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        self.i64().map(|v| v as u64)
    }
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
        commonattr: ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID,
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

    loop {
        let n = unsafe { getattrlistbulk(fd, &mut al, buf_ptr as *mut _, buf_len, 0) };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if n == 0 {
            break;
        }
        let bytes = unsafe { std::slice::from_raw_parts(buf_ptr, buf_len) };
        let mut off = 0usize;
        for _ in 0..n {
            let rec_len = u32::from_ne_bytes(bytes[off..off + 4].try_into().unwrap()) as usize;
            let rec = &bytes[off..off + rec_len];
            off += rec_len;
            if let Some(e) = parse_record(rec) {
                out.push(e);
            }
        }
    }
    Ok(out)
}

fn parse_record(rec: &[u8]) -> Option<RawEntry> {
    let mut c = Cursor { buf: rec, pos: 4 }; // skip length
    let ret_common = c.u32()?;
    let _ret_vol = c.u32()?;
    let _ret_dir = c.u32()?;
    let ret_file = c.u32()?;
    let _ret_fork = c.u32()?;

    let mut name: Option<Box<str>> = None;
    let mut name_lossy = false;
    let (mut dev, mut ino, mut objtype) = (0u64, 0u64, 0u32);
    let (mut nlink, mut alloc) = (1u32, 0u64);
    let mut mtime = 0i64;

    if ret_common & ATTR_CMN_NAME != 0 {
        let ref_pos = c.pos;
        let off = c.i32()? as isize;
        let len = c.u32()? as usize;
        let start = (ref_pos as isize + off) as usize;
        let raw = rec.get(start..start + len)?;
        let raw = raw.strip_suffix(&[0]).unwrap_or(raw);
        name_lossy = std::str::from_utf8(raw).is_err();
        name = Some(String::from_utf8_lossy(raw).into_owned().into_boxed_str());
    }
    if ret_common & ATTR_CMN_DEVID != 0 {
        dev = c.i32()? as u32 as u64;
    }
    if ret_common & ATTR_CMN_OBJTYPE != 0 {
        objtype = c.u32()?;
    }
    if ret_common & ATTR_CMN_MODTIME != 0 {
        mtime = c.i64()?; // timespec: tv_sec
        let _nsec = c.i64()?;
    }
    if ret_common & ATTR_CMN_FILEID != 0 {
        ino = c.u64()?;
    }
    if ret_file & ATTR_FILE_LINKCOUNT != 0 {
        nlink = c.u32()?;
    }
    if ret_file & ATTR_FILE_ALLOCSIZE != 0 {
        alloc = c.i64()?.max(0) as u64;
    }
    let name = name?;
    let kind = match objtype {
        VDIR => Kind::Directory,
        VLNK => Kind::Symlink,
        VREG => Kind::File,
        _ => Kind::File, // devices, sockets, fifos: recorded as files with whatever size they report
    };
    Some(RawEntry { name, name_lossy, kind, alloc, nlink, dev, ino, mtime })
}
