//! Pure parser for the buffers `getattrlistbulk(2)` fills. It touches no syscall, so it is compiled (and unit tested) on every platform; only `scan_macos` calls it for real.
//!
//! Requested attributes, in the order the kernel packs them after the 4-byte record length:
//!   RETURNED_ATTRS (5 x u32), then ERROR (u32, present only when the returned set says so; the kernel packs it right after RETURNED_ATTRS),
//!   then common NAME (attrreference), DEVID, OBJTYPE, MODTIME (timespec), FILEID, then file LINKCOUNT, ALLOCSIZE.
//! PACK_INVAL_ATTRS is NOT set, so the returned set says exactly which attributes follow.
//!
//! Nothing is dropped silently and nothing is guessed:
//!  * a record that carries a per-entry error, or whose fields cannot be read, but whose NAME was recovered becomes a `failed` entry with that name;
//!  * a record whose name cannot be recovered (or is empty) cannot be named, so it is reported as ONE directory-level unreadable entry (empty name, the existing contract:
//!    the skipped path is the directory itself, the other entries of the directory stay in the tree);
//!  * a record length that is too short or runs past the buffer stops the batch (the next record cannot be located) and is reported the same way;
//!  * an entry whose error is ENOENT vanished mid-scan and is not emitted, exactly like the portable backend.
#![allow(dead_code)]

use crate::scan::RawEntry;
use crate::tree::Kind;

pub(crate) const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
pub(crate) const ATTR_CMN_ERROR: u32 = 0x2000_0000;
pub(crate) const ATTR_CMN_NAME: u32 = 0x0000_0001;
pub(crate) const ATTR_CMN_DEVID: u32 = 0x0000_0002;
pub(crate) const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
pub(crate) const ATTR_CMN_MODTIME: u32 = 0x0000_0400;
pub(crate) const ATTR_CMN_FILEID: u32 = 0x0200_0000;
pub(crate) const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
pub(crate) const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;
const ENOENT: u32 = 2;
const EPERM: u32 = 1;
const EACCES: u32 = 13;

struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn u32(&mut self) -> Option<u32> {
        let end = self.pos.checked_add(4)?;
        let b = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(u32::from_ne_bytes(b.try_into().ok()?))
    }
    fn i32(&mut self) -> Option<i32> {
        self.u32().map(|v| v as i32)
    }
    fn i64(&mut self) -> Option<i64> {
        let end = self.pos.checked_add(8)?;
        let b = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(i64::from_ne_bytes(b.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        self.i64().map(|v| v as u64)
    }
}

enum Rec {
    Entry(RawEntry),
    /// ENOENT: the entry vanished while the directory was being read.
    Gone,
    /// Unusable record. `name` is `(lossy-rendered name, name was not valid UTF-8)` when it could be recovered.
    Bad { name: Option<(Box<str>, bool)>, failed: u8 },
}

fn failed_raw(name: Box<str>, lossy: bool, failed: u8) -> RawEntry {
    RawEntry { name, name_lossy: lossy, failed, kind: Kind::File, alloc: 0, nlink: 1, dev: 0, ino: 0, mtime: 0 }
}

/// The directory-level marker: empty name, see `walk` in scan.rs.
pub(crate) fn dir_marker() -> RawEntry {
    failed_raw("".into(), false, 2)
}

fn reason_for(errno: u32) -> u8 {
    if errno == EACCES || errno == EPERM { 1 } else { 2 }
}

fn read_name(c: &mut Cursor, rec: &[u8]) -> Option<(Box<str>, bool)> {
    let ref_pos = c.pos;
    let off = c.i32()? as i64;
    let len = c.u32()? as usize;
    let start = usize::try_from((ref_pos as i64).checked_add(off)?).ok()?;
    let end = start.checked_add(len)?;
    let raw = rec.get(start..end)?;
    let raw = raw.strip_suffix(&[0]).unwrap_or(raw);
    let lossy = std::str::from_utf8(raw).is_err();
    Some((String::from_utf8_lossy(raw).into_owned().into_boxed_str(), lossy))
}

fn parse_record(rec: &[u8]) -> Rec {
    let bad = |name: Option<(Box<str>, bool)>| Rec::Bad { name, failed: 2 };
    let mut c = Cursor { buf: rec, pos: 4 }; // skip length
    let (Some(ret_common), Some(_vol), Some(_dir), Some(ret_file), Some(_fork)) = (c.u32(), c.u32(), c.u32(), c.u32(), c.u32()) else { return bad(None) };

    let mut error = 0u32;
    if ret_common & ATTR_CMN_ERROR != 0 {
        match c.u32() { Some(e) => error = e, None => return bad(None) }
    }
    let mut name: Option<(Box<str>, bool)> = None;
    if ret_common & ATTR_CMN_NAME != 0 {
        match read_name(&mut c, rec) { Some(n) => name = Some(n), None => return bad(None) }
    }
    // An empty name would be indistinguishable from the directory-level marker, so it is unusable.
    if name.as_ref().map_or(false, |(n, _)| n.is_empty()) { return bad(None); }
    if error != 0 {
        if error == ENOENT { return Rec::Gone; }
        return Rec::Bad { name, failed: reason_for(error) };
    }

    let (mut dev, mut ino, mut objtype) = (0u64, 0u64, 0u32);
    let (mut nlink, mut alloc) = (1u32, 0u64);
    let mut mtime = 0i64;
    let ok = (|| -> Option<()> {
        if ret_common & ATTR_CMN_DEVID != 0 { dev = c.i32()? as u32 as u64; }
        if ret_common & ATTR_CMN_OBJTYPE != 0 { objtype = c.u32()?; }
        if ret_common & ATTR_CMN_MODTIME != 0 {
            mtime = c.i64()?; // timespec: tv_sec
            let _nsec = c.i64()?;
        }
        if ret_common & ATTR_CMN_FILEID != 0 { ino = c.u64()?; }
        if ret_file & ATTR_FILE_LINKCOUNT != 0 { nlink = c.u32()?; }
        if ret_file & ATTR_FILE_ALLOCSIZE != 0 { alloc = c.i64()?.max(0) as u64; }
        Some(())
    })();
    let Some((name, name_lossy)) = name else { return bad(None) };
    if ok.is_none() { return bad(Some((name, name_lossy))); }
    let kind = match objtype {
        VDIR => Kind::Directory,
        VLNK => Kind::Symlink,
        VREG => Kind::File,
        _ => Kind::File, // devices, sockets, fifos: recorded as files with whatever size they report
    };
    Rec::Entry(RawEntry { name, name_lossy, failed: 0, kind, alloc, nlink, dev, ino, mtime })
}

/// Parse the `n` records of one `getattrlistbulk` batch from `buf`. Returns true when some part of the batch could not be attributed to a name, so the caller
/// must record the directory itself as unreadable (once per directory).
pub(crate) fn parse_batch(buf: &[u8], n: usize, out: &mut Vec<RawEntry>) -> bool {
    let mut dir_failed = false;
    let mut off = 0usize;
    for _ in 0..n {
        let Some(lb) = off.checked_add(4).and_then(|e| buf.get(off..e)) else { return true };
        let rec_len = u32::from_ne_bytes(lb.try_into().unwrap()) as usize;
        let end = match off.checked_add(rec_len) {
            Some(e) if rec_len >= 4 && e <= buf.len() => e,
            _ => return true, // the next record cannot be located
        };
        match parse_record(&buf[off..end]) {
            Rec::Entry(e) => out.push(e),
            Rec::Gone => {}
            Rec::Bad { name: Some((nm, lossy)), failed } => out.push(failed_raw(nm, lossy, failed)),
            Rec::Bad { name: None, .. } => dir_failed = true,
        }
        off = end;
    }
    dir_failed
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build one record: length, returned attrs, optional error, name, then the fixed fields. `fields` toggles which optional parts are present.
    fn rec(name: &[u8], error: Option<u32>, with_tail: bool) -> Vec<u8> {
        let mut common = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME;
        if error.is_some() { common |= ATTR_CMN_ERROR; }
        if with_tail { common |= ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID; }
        let file = if with_tail { ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE } else { 0 };
        let mut b = vec![0u8; 4];
        for v in [common, 0, 0, file, 0] { b.extend_from_slice(&v.to_ne_bytes()); }
        if let Some(e) = error { b.extend_from_slice(&e.to_ne_bytes()); }
        // attrreference: offset is relative to the reference's own position; the name data follows the fixed fields.
        let ref_pos = b.len();
        let tail_len = if with_tail { 4 + 4 + 16 + 8 + 4 + 8 } else { 0 };
        let off = 8 + tail_len;
        b.extend_from_slice(&(off as i32).to_ne_bytes());
        b.extend_from_slice(&((name.len() + 1) as u32).to_ne_bytes());
        if with_tail {
            b.extend_from_slice(&7i32.to_ne_bytes()); // dev
            b.extend_from_slice(&VDIR.to_ne_bytes()); // objtype
            b.extend_from_slice(&1234i64.to_ne_bytes()); b.extend_from_slice(&0i64.to_ne_bytes()); // mtime
            b.extend_from_slice(&99u64.to_ne_bytes()); // fileid
            b.extend_from_slice(&3u32.to_ne_bytes()); // nlink
            b.extend_from_slice(&4096i64.to_ne_bytes()); // alloc
        }
        assert_eq!(b.len(), ref_pos + off);
        b.extend_from_slice(name); b.push(0);
        while b.len() % 8 != 0 { b.push(0); }
        let l = b.len() as u32; b[0..4].copy_from_slice(&l.to_ne_bytes());
        b
    }
    fn batch(recs: &[Vec<u8>]) -> Vec<u8> { recs.concat() }

    #[test]
    fn a_complete_record_parses_with_every_field() {
        let mut out = Vec::new();
        assert!(!parse_batch(&batch(&[rec(b"dir", None, true)]), 1, &mut out));
        let e = &out[0];
        assert_eq!((&*e.name, e.failed, e.kind, e.dev, e.ino, e.nlink, e.alloc, e.mtime, e.name_lossy), ("dir", 0, Kind::Directory, 7, 99, 3, 4096, 1234, false));
    }

    #[test]
    fn a_per_entry_error_keeps_the_name_and_picks_the_reason_without_a_size() {
        let mut out = Vec::new();
        let b = batch(&[rec(b"locked", Some(EACCES), false), rec(b"odd", Some(5), false), rec(b"gone", Some(ENOENT), false), rec(b"ok", None, true)]);
        assert!(!parse_batch(&b, 4, &mut out));
        let got: Vec<_> = out.iter().map(|e| (e.name.to_string(), e.failed, e.alloc)).collect();
        assert_eq!(got, vec![("locked".to_string(), 1, 0), ("odd".to_string(), 2, 0), ("ok".to_string(), 0, 4096)]); // ENOENT vanished: not emitted
    }

    #[test]
    fn declared_fields_that_run_out_of_record_are_a_named_failure_not_a_zero_size_file() {
        // The name sits right after its reference (offset 8) but the returned set declares fields that do not fit in the rest of the record.
        let mut r = rec(b"cut", None, false);
        let common = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID;
        r[4..8].copy_from_slice(&common.to_ne_bytes());
        r[16..20].copy_from_slice(&(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE).to_ne_bytes());
        let mut out = Vec::new();
        assert!(!parse_batch(&r, 1, &mut out), "the name was recovered, so no directory-level marker is needed");
        assert_eq!(out.len(), 1);
        assert_eq!((&*out[0].name, out[0].failed, out[0].alloc, out[0].kind), ("cut", 2, 0, Kind::File));
    }

    #[test]
    fn a_record_whose_name_cannot_be_read_is_reported_at_directory_level_and_neighbours_survive() {
        let mut bad_name = rec(b"x", None, true);
        bad_name[4 + 20 + 0..4 + 20 + 4].copy_from_slice(&0x7fff_0000i32.to_ne_bytes()); // name offset points far outside the record
        let b = batch(&[rec(b"before", None, true), bad_name, rec(b"after", None, true)]);
        let mut out = Vec::new();
        assert!(parse_batch(&b, 3, &mut out));
        assert_eq!(out.iter().map(|e| e.name.to_string()).collect::<Vec<_>>(), vec!["before".to_string(), "after".to_string()]);
    }

    #[test]
    fn a_negative_name_offset_and_an_overflowing_length_cannot_panic() {
        let mut r = rec(b"x", None, true);
        r[24..28].copy_from_slice(&i32::MIN.to_ne_bytes());
        let mut r2 = rec(b"x", None, true);
        r2[28..32].copy_from_slice(&u32::MAX.to_ne_bytes());
        for r in [r, r2] {
            let mut out = Vec::new();
            assert!(parse_batch(&r, 1, &mut out) && out.is_empty());
        }
    }

    #[test]
    fn an_empty_name_is_not_accepted_as_a_normal_entry() {
        let mut out = Vec::new();
        assert!(parse_batch(&batch(&[rec(b"", None, true)]), 1, &mut out));
        assert!(out.is_empty());
    }

    #[test]
    fn a_bad_record_length_stops_the_batch_and_reports_the_directory() {
        for bad_len in [0u32, 3, u32::MAX, 1 << 30] {
            let mut first = rec(b"a", None, true);
            first[0..4].copy_from_slice(&bad_len.to_ne_bytes());
            let mut out = Vec::new();
            assert!(parse_batch(&batch(&[first, rec(b"b", None, true)]), 2, &mut out), "length {bad_len}");
            assert!(out.is_empty());
        }
        // More records declared than the buffer holds.
        let mut out = Vec::new();
        assert!(parse_batch(&batch(&[rec(b"a", None, true)]), 2, &mut out));
        assert_eq!(out.len(), 1);
        // Buffer shorter than a length field.
        assert!(parse_batch(&[1, 2], 1, &mut Vec::new()));
    }

    #[test]
    fn a_non_utf8_name_keeps_its_lossy_flag() {
        let mut out = Vec::new();
        assert!(!parse_batch(&batch(&[rec(b"a\xff", None, true)]), 1, &mut out));
        assert!(out[0].name_lossy);
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        // Deterministic xorshift fuzz over buffers of assorted sizes, with a plausible header prefix half the time.
        let mut s = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = || { s ^= s << 13; s ^= s >> 7; s ^= s << 17; s };
        for i in 0..20_000 {
            let len = (next() % 200) as usize;
            let mut b: Vec<u8> = (0..len).map(|_| next() as u8).collect();
            if i % 2 == 0 && b.len() >= 8 { let l = (b.len() as u32).to_ne_bytes(); b[0..4].copy_from_slice(&l); }
            let mut out = Vec::new();
            let _ = parse_batch(&b, (next() % 6) as usize, &mut out);
        }
    }
}
