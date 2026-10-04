//! C ABI for the Swift app. All handles are opaque pointers owned by the caller and freed
//! with the matching `spz_*_free`. Strings returned to the caller are freed with
//! `spz_string_free`. Every entry point catches panics inside its body (release profile uses panic = "unwind"; a panic
//! can never unwind across the ABI). It comes back as a fallback value or status 5. Allocation failure (OOM) still aborts.
#![allow(clippy::missing_safety_doc)]

use crate::category::CATEGORY_COUNT;
use crate::layout::{hit_test, LayoutOptions, Rect};
use crate::scan::{scan, ScanOptions, ScanProgress};
use crate::tree::{NodeId, Tree};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

pub struct Scan {
    progress: Arc<ScanProgress>,
    result: Arc<Mutex<Option<std::io::Result<Tree>>>>,
    handle: Mutex<Option<std::thread::JoinHandle<()>>>,
}

/// Source of tree generation ids (never 0, so a default/unassigned tree matches nothing).
static NEXT_TREE_UID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// A node id is valid only for the tree that produced it. Every id-taking entry point checks it and
/// returns an empty/zero result instead of indexing out of range (a Rust panic aborts the whole app).
fn valid(t: *const Tree, id: NodeId) -> bool {
    !t.is_null() && (id as usize) < unsafe { (*t).len() }
}

pub struct Layout {
    rects: Vec<Rect>,
    uid: u64,
    version: u64,
}

#[repr(C)]
pub struct SpzProgress {
    pub items: u64,
    pub bytes: u64,
    pub finished: u8,
    pub failed: u8,
}

#[repr(C)]
pub struct SpzNode {
    pub size: u64,
    pub own_bytes: u64,
    pub parent: u32, // u32::MAX = none
    pub child_count: u32,
    pub first_child: u32,
    pub kind: u8,
    pub category: u8,
}

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// Panic guard for the legacy entry points (no status out-parameter): a panic comes back as the fallback value.
/// Only effective with panic = "unwind" (set in the workspace release profile); with abort it could not catch.
unsafe fn legacy<R>(fallback: R, f: impl FnOnce() -> R) -> R {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| { crate::tree::ffi_failpoint(); f() })).unwrap_or_else(|_| { PANICS.fetch_add(1, Ordering::SeqCst); fallback })
}

/// Sticky count of panics caught at any FFI boundary since process start. A legacy call that returns its
/// fallback (0, null, empty) after a panic is indistinguishable from valid data, so callers must compare this
/// counter before and after a publication and treat any change as "result not valid".
static PANICS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
#[no_mangle]
pub extern "C" fn spz_engine_panic_count() -> u64 { PANICS.load(Ordering::SeqCst) }

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

/// Start scanning `root` on a background thread. `excludes` is a newline-separated list of
/// absolute paths (may be null). Returns a handle immediately.
#[no_mangle]
pub unsafe extern "C" fn spz_scan_start(root: *const c_char, excludes: *const c_char) -> *mut Scan {
    legacy(std::ptr::null_mut(), || spz_scan_start_impl(root, excludes))
}

unsafe fn spz_scan_start_impl(root: *const c_char, excludes: *const c_char) -> *mut Scan {
    let root = PathBuf::from(cstr(root));
    let opts = ScanOptions {
        exclude: cstr(excludes).lines().filter(|l| !l.is_empty()).map(PathBuf::from).collect(),
        ..Default::default()
    };
    let progress = Arc::new(ScanProgress::default());
    let result = Arc::new(Mutex::new(None));
    let (p2, r2) = (progress.clone(), result.clone());
    let h = std::thread::spawn(move || {
        // a panic in the scan becomes a failed scan, never a scan that stays 'running' forever
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| scan(&root, &opts, &p2)))
            .unwrap_or_else(|_| { PANICS.fetch_add(1, Ordering::SeqCst); Err(std::io::Error::new(std::io::ErrorKind::Other, "internal error during scan")) });
        *r2.lock().unwrap_or_else(|e| e.into_inner()) = Some(r);
    });
    Box::into_raw(Box::new(Scan { progress, result, handle: Mutex::new(Some(h)) }))
}

#[no_mangle]
pub unsafe extern "C" fn spz_scan_progress(s: *const Scan) -> SpzProgress {
    legacy(SpzProgress { items: 0, bytes: 0, finished: 1, failed: 1 }, || spz_scan_progress_impl(s))
}

unsafe fn spz_scan_progress_impl(s: *const Scan) -> SpzProgress {
    if s.is_null() { return SpzProgress { items: 0, bytes: 0, finished: 0, failed: 1 }; }
    let s = &*s;
    let guard = s.result.lock().unwrap_or_else(|e| e.into_inner());
    SpzProgress {
        items: s.progress.items.load(Ordering::Relaxed),
        bytes: s.progress.bytes.load(Ordering::Relaxed),
        finished: guard.is_some() as u8,
        failed: matches!(&*guard, Some(Err(_))) as u8,
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_scan_cancel(s: *const Scan) {
    legacy((), || spz_scan_cancel_impl(s))
}

unsafe fn spz_scan_cancel_impl(s: *const Scan) {
    if s.is_null() { return; }
    (*s).progress.cancel();
}

/// Take the finished tree out of the scan handle. Null if not finished, failed, or already taken.
#[no_mangle]
pub unsafe extern "C" fn spz_scan_take_tree(s: *mut Scan) -> *mut Tree {
    legacy(std::ptr::null_mut(), || spz_scan_take_tree_impl(s))
}

unsafe fn spz_scan_take_tree_impl(s: *mut Scan) -> *mut Tree {
    if s.is_null() { return std::ptr::null_mut(); }
    let s = &*s;
    let h = s.handle.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(h) = h {
        let _ = h.join();
    }
    let r = s.result.lock().unwrap_or_else(|e| e.into_inner()).take();
    match r {
        Some(Ok(mut t)) => {
            t.uid = NEXT_TREE_UID.fetch_add(1, Ordering::Relaxed);
            Box::into_raw(Box::new(t))
        }
        _ => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_scan_free(s: *mut Scan) {
    if s.is_null() {
        return;
    }
    let s = Box::from_raw(s);
    s.progress.cancel();
    let h = s.handle.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(h) = h {
        let _ = h.join();
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_free(t: *mut Tree) {
    if !t.is_null() {
        drop(Box::from_raw(t));
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_node_count(t: *const Tree) -> u64 {
    legacy(0, || spz_tree_node_count_impl(t))
}

unsafe fn spz_tree_node_count_impl(t: *const Tree) -> u64 {
    if t.is_null() { return 0; }
    (*t).len() as u64
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_cancelled(t: *const Tree) -> u8 {
    legacy(0, || spz_tree_cancelled_impl(t))
}

unsafe fn spz_tree_cancelled_impl(t: *const Tree) -> u8 {
    if t.is_null() { return 0; }
    (*t).cancelled as u8
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_node(t: *const Tree, id: NodeId) -> SpzNode {
    legacy(SpzNode { size: 0, own_bytes: 0, parent: u32::MAX, child_count: 0, first_child: u32::MAX, kind: 0, category: 0 }, || spz_tree_node_impl(t, id))
}

unsafe fn spz_tree_node_impl(t: *const Tree, id: NodeId) -> SpzNode {
    if !valid(t, id) {
        return SpzNode { size: 0, own_bytes: 0, parent: u32::MAX, child_count: 0, first_child: u32::MAX, kind: 0, category: 0 };
    }
    let t = &*t;
    let r = t.children(id);
    let tab = t.table(); // one snapshot for both numbers
    SpzNode {
        size: tab.sizes[id as usize],
        own_bytes: t.own_bytes_in(&tab.sizes, id),
        parent: t.parent(id).unwrap_or(u32::MAX),
        child_count: t.live_child_count_in(&tab, id),
        first_child: if r.is_empty() { u32::MAX } else { r.start },
        kind: t.kind(id) as u8,
        category: t.category(id) as u8,
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_name(t: *const Tree, id: NodeId) -> *mut c_char {
    legacy(std::ptr::null_mut(), || spz_tree_name_impl(t, id))
}

unsafe fn spz_tree_name_impl(t: *const Tree, id: NodeId) -> *mut c_char {
    if !valid(t, id) { return to_c(String::new()); }
    let t = &*t;
    to_c(if id == 0 { t.root_path().to_string() } else { t.name(id).to_string() })
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_path(t: *const Tree, id: NodeId) -> *mut c_char {
    legacy(std::ptr::null_mut(), || spz_tree_path_impl(t, id))
}

unsafe fn spz_tree_path_impl(t: *const Tree, id: NodeId) -> *mut c_char {
    if !valid(t, id) { return to_c(String::new()); }
    to_c((*t).path(id))
}

/// Node for an absolute path under the scanned root, or u32::MAX.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_find(t: *const Tree, path: *const c_char) -> NodeId {
    legacy(u32::MAX, || spz_tree_find_impl(t, path))
}

unsafe fn spz_tree_find_impl(t: *const Tree, path: *const c_char) -> NodeId {
    if t.is_null() { return u32::MAX; }
    (*t).find(&cstr(path)).unwrap_or(u32::MAX)
}

/// Remove a subtree from the result after it was moved to the Trash.
/// Returns 0 OK, 2 MUTATION_FAILED (tree unchanged), 3 INVALID. Never panics across the ABI.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_forget(t: *mut Tree, id: NodeId) -> i32 {
    legacy(5, || spz_tree_forget_impl(t, id))
}

unsafe fn spz_tree_forget_impl(t: *mut Tree, id: NodeId) -> i32 {
    if !valid(t, id) { return 3; }
    match (*t).forget(id) {
        Ok(_) => 0,
        Err(crate::tree::MutationError::Invalid) => 3,
        Err(_) => 2,
    }
}

/// Version of the currently published size table (increments on every successful mutation).
#[no_mangle]
pub unsafe extern "C" fn spz_tree_version(t: *const Tree) -> u64 {
    legacy(0, || spz_tree_version_impl(t))
}

unsafe fn spz_tree_version_impl(t: *const Tree) -> u64 {
    if t.is_null() { return 0; }
    (*t).table().version
}

/// Writes (bytes, items) pairs for each category into `out` (CATEGORY_COUNT * 2 u64s).
#[no_mangle]
pub unsafe extern "C" fn spz_tree_category_totals(t: *const Tree, out: *mut u64) {
    legacy((), || spz_tree_category_totals_impl(t, out))
}

unsafe fn spz_tree_category_totals_impl(t: *const Tree, out: *mut u64) {
    if t.is_null() || out.is_null() { return; }
    let totals = (*t).category_totals();
    for (i, (b, n)) in totals.iter().enumerate().take(CATEGORY_COUNT) {
        *out.add(i * 2) = *b;
        *out.add(i * 2 + 1) = *n;
    }
}

/// Fill `out` with up to `cap` ids of the largest files; returns the count written.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_largest_files(t: *const Tree, cap: u32, out: *mut NodeId) -> u32 {
    legacy(0, || spz_tree_largest_files_impl(t, cap, out))
}

unsafe fn spz_tree_largest_files_impl(t: *const Tree, cap: u32, out: *mut NodeId) -> u32 {
    if t.is_null() || (out.is_null() && cap > 0) { return 0; }
    let v = (*t).largest_files(cap as usize);
    for (i, id) in v.iter().enumerate() {
        *out.add(i) = *id;
    }
    v.len() as u32
}

/// Number of skipped locations, and accessors for them.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_skipped_count(t: *const Tree) -> u32 {
    legacy(0, || spz_tree_skipped_count_impl(t))
}

unsafe fn spz_tree_skipped_count_impl(t: *const Tree) -> u32 {
    if t.is_null() { return 0; }
    (*t).skipped.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_skipped_path(t: *const Tree, i: u32) -> *mut c_char {
    legacy(std::ptr::null_mut(), || spz_tree_skipped_path_impl(t, i))
}

unsafe fn spz_tree_skipped_path_impl(t: *const Tree, i: u32) -> *mut c_char {
    if t.is_null() { return to_c(String::new()); }
    to_c((&*t).skipped.get(i as usize).map(|s| s.path.clone()).unwrap_or_default())
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_skipped_reason(t: *const Tree, i: u32) -> u8 {
    legacy(0, || spz_tree_skipped_reason_impl(t, i))
}

unsafe fn spz_tree_skipped_reason_impl(t: *const Tree, i: u32) -> u8 {
    if t.is_null() { return 1; }
    (&*t).skipped.get(i as usize).map(|s| s.reason as u8).unwrap_or(1)
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_new(t: *const Tree, root: NodeId, width: f32, height: f32) -> *mut Layout {
    legacy(std::ptr::null_mut(), || spz_layout_new_impl(t, root, width, height))
}

unsafe fn spz_layout_new_impl(t: *const Tree, root: NodeId, width: f32, height: f32) -> *mut Layout {
    let opts = LayoutOptions { width, height, ..Default::default() };
    if !valid(t, root) { return Box::into_raw(Box::new(Layout { rects: Vec::new(), uid: 0, version: 0 })); }
    Box::into_raw(Box::new({ let tab = (*t).table(); Layout { rects: crate::layout::layout_in(&*t, &tab, root, &opts, None), uid: (*t).uid, version: tab.version } }))
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_free(l: *mut Layout) {
    if !l.is_null() {
        drop(Box::from_raw(l));
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_count(l: *const Layout) -> u32 {
    legacy(0, || spz_layout_count_impl(l))
}

unsafe fn spz_layout_count_impl(l: *const Layout) -> u32 {
    if l.is_null() { return 0; }
    (&*l).rects.len() as u32
}

/// Pointer to the contiguous `Rect` array (valid until `spz_layout_free`).
#[no_mangle]
pub unsafe extern "C" fn spz_layout_rects(l: *const Layout) -> *const Rect {
    legacy(std::ptr::null(), || spz_layout_rects_impl(l))
}

unsafe fn spz_layout_rects_impl(l: *const Layout) -> *const Rect {
    if l.is_null() { return std::ptr::null(); }
    (&*l).rects.as_ptr()
}

/// Index of the rect under the point, or u32::MAX.
#[no_mangle]
pub unsafe extern "C" fn spz_layout_hit(l: *const Layout, x: f32, y: f32) -> u32 {
    legacy(0, || spz_layout_hit_impl(l, x, y))
}

unsafe fn spz_layout_hit_impl(l: *const Layout, x: f32, y: f32) -> u32 {
    if l.is_null() { return u32::MAX; }
    hit_test(&(&*l).rects, x, y).map(|i| i as u32).unwrap_or(u32::MAX)
}

#[no_mangle]
pub unsafe extern "C" fn spz_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Visible outline rows under `root` given the expanded node ids. Pass `out == null` to get
/// the count, then call again with a buffer of that many `Row`s (two u32s each).
#[no_mangle]
pub unsafe extern "C" fn spz_outline_rows(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    legacy(0, || spz_outline_rows_impl(t, root, expanded, n_expanded, out, cap))
}

unsafe fn spz_outline_rows_impl(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    if !valid(t, root) { return 0; }
    let set = expanded_set(t, expanded, n_expanded);
    let rows = crate::outline::visible_rows(&*t, root, &set, None);
    if !out.is_null() {
        let n = rows.len().min(cap as usize);
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out, n);
    }
    rows.len() as u32
}

#[repr(C)]
pub struct SpzFilter {
    pub category_mask: u32,
    pub has_min: u8,
    pub has_max: u8,
    pub has_from: u8,
    pub has_to: u8,
    pub min_size: u64,
    pub max_size: u64,
    pub modified_from: i64,
    pub modified_to: i64,
}

pub struct FilterHandle(crate::filter::FilterResult, u64, u64);

/// A filter result is sized for one tree; it must never be applied to another.
fn handle_ok(t: *const Tree, h: *const FilterHandle) -> bool {
    !t.is_null() && !h.is_null() && unsafe { (*h).1 == (*t).uid && (*h).0.sizes.len() == (*t).len() }
}

/// Expanded ids from the caller, dropping any that are not nodes of this tree.
unsafe fn expanded_set(t: *const Tree, expanded: *const NodeId, n: u32) -> std::collections::HashSet<NodeId> {
    if expanded.is_null() {
        return Default::default();
    }
    let len = (*t).len();
    std::slice::from_raw_parts(expanded, n as usize).iter().copied().filter(|&e| (e as usize) < len).collect()
}

/// Run a filter over the whole tree in Rust. `text` and `ext` may be null.
#[no_mangle]
pub unsafe extern "C" fn spz_filter_apply(t: *const Tree, text: *const c_char, ext: *const c_char, f: SpzFilter) -> *mut FilterHandle {
    legacy(std::ptr::null_mut(), || spz_filter_apply_impl(t, text, ext, f))
}

unsafe fn spz_filter_apply_impl(t: *const Tree, text: *const c_char, ext: *const c_char, f: SpzFilter) -> *mut FilterHandle {
    if t.is_null() { return std::ptr::null_mut(); }
    let flt = crate::filter::Filter {
        text: cstr(text),
        category_mask: f.category_mask,
        extension: cstr(ext),
        min_size: (f.has_min != 0).then_some(f.min_size),
        max_size: (f.has_max != 0).then_some(f.max_size),
        modified_from: (f.has_from != 0).then_some(f.modified_from),
        modified_to: (f.has_to != 0).then_some(f.modified_to),
    };
    let tab = (*t).table(); // one snapshot: result and stamp share it
    Box::into_raw(Box::new(FilterHandle(crate::filter::apply_in(&*t, &tab, &flt), (*t).uid, tab.version)))
}

#[no_mangle]
pub unsafe extern "C" fn spz_filter_free(h: *mut FilterHandle) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_filter_total_bytes(h: *const FilterHandle) -> u64 { if h.is_null() { 0 } else { (*h).0.total_bytes } }

#[no_mangle]
pub unsafe extern "C" fn spz_filter_total_count(h: *const FilterHandle) -> u64 { if h.is_null() { 0 } else { (*h).0.total_count } }

/// Filtered size of one node (sum of matching descendants).
#[no_mangle]
pub unsafe extern "C" fn spz_filter_size(h: *const FilterHandle, id: NodeId) -> u64 {
    legacy(0, || spz_filter_size_impl(h, id))
}

unsafe fn spz_filter_size_impl(h: *const FilterHandle, id: NodeId) -> u64 { if h.is_null() { return 0; } (&(*h).0.sizes).get(id as usize).copied().unwrap_or(0) }

/// Matching file count under one node.
#[no_mangle]
pub unsafe extern "C" fn spz_filter_count(h: *const FilterHandle, id: NodeId) -> u32 {
    legacy(0, || spz_filter_count_impl(h, id))
}

unsafe fn spz_filter_count_impl(h: *const FilterHandle, id: NodeId) -> u32 { if h.is_null() { return 0; } (&(*h).0.counts).get(id as usize).copied().unwrap_or(0) }

/// Like `spz_outline_rows`, but hides nodes with no matching bytes. Pass the handle from `spz_filter_apply`.
#[no_mangle]
pub unsafe extern "C" fn spz_outline_rows_filtered(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle,
    out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    legacy(0, || spz_outline_rows_filtered_impl(t, root, expanded, n_expanded, h, out, cap))
}

unsafe fn spz_outline_rows_filtered_impl(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle,
    out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    if !valid(t, root) || !handle_ok(t, h) { return 0; }
    let set = expanded_set(t, expanded, n_expanded);
    let rows = crate::outline::visible_rows(&*t, root, &set, Some(&(*h).0));
    if !out.is_null() {
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap as usize));
    }
    rows.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_new_filtered(t: *const Tree, root: NodeId, width: f32, height: f32, h: *const FilterHandle) -> *mut Layout {
    legacy(std::ptr::null_mut(), || spz_layout_new_filtered_impl(t, root, width, height, h))
}

unsafe fn spz_layout_new_filtered_impl(t: *const Tree, root: NodeId, width: f32, height: f32, h: *const FilterHandle) -> *mut Layout {
    let opts = LayoutOptions { width, height, ..Default::default() };
    if !valid(t, root) || !handle_ok(t, h) { return Box::into_raw(Box::new(Layout { rects: Vec::new(), uid: 0, version: 0 })); }
    // every size used comes from the handle's own sizes, so the layout is stamped with the handle's version:
    // a handle computed on an old table gives a layout stamped old (STALE on status check), never old data under a new stamp
    Box::into_raw(Box::new(Layout { rects: crate::layout::layout_in(&*t, &(*t).table(), root, &opts, Some(&(*h).0.sizes)), uid: (*t).uid, version: (*h).2 }))
}

/// Largest matching files under a filter; returns the count written (up to `cap`).
#[no_mangle]
pub unsafe extern "C" fn spz_filter_largest_files(t: *const Tree, h: *const FilterHandle, cap: u32, out: *mut NodeId) -> u32 {
    legacy(0, || spz_filter_largest_files_impl(t, h, cap, out))
}

unsafe fn spz_filter_largest_files_impl(t: *const Tree, h: *const FilterHandle, cap: u32, out: *mut NodeId) -> u32 {
    if out.is_null() && cap > 0 { return 0; }
    if !handle_ok(t, h) { return 0; }
    let v = crate::filter::largest_files(&*t, &(*h).0, cap as usize);
    for (i, id) in v.iter().enumerate() {
        *out.add(i) = *id;
    }
    v.len() as u32
}

/// Per-category (bytes, items) over the filtered set, CATEGORY_COUNT * 2 u64s.
#[no_mangle]
pub unsafe extern "C" fn spz_filter_category_totals(t: *const Tree, h: *const FilterHandle, out: *mut u64) {
    legacy((), || spz_filter_category_totals_impl(t, h, out))
}

unsafe fn spz_filter_category_totals_impl(t: *const Tree, h: *const FilterHandle, out: *mut u64) {
    if out.is_null() { return; }
    if !handle_ok(t, h) { for i in 0..CATEGORY_COUNT * 2 { *out.add(i) = 0; } return; }
    let totals = crate::filter::category_totals(&*t, &(*h).0);
    for (i, (b, n)) in totals.iter().enumerate().take(CATEGORY_COUNT) {
        *out.add(i * 2) = *b;
        *out.add(i * 2 + 1) = *n;
    }
}

/// Outline rows with a sibling sort (0 size desc, 1 size asc, 2 name, 3 items desc, 4 modified desc).
/// `h` may be null for no filter. Invalid or foreign handles return 0 rows.
#[no_mangle]
pub unsafe extern "C" fn spz_outline_rows_sorted(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle, sort: u32,
    out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    legacy(0, || spz_outline_rows_sorted_impl(t, root, expanded, n_expanded, h, sort, out, cap))
}

unsafe fn spz_outline_rows_sorted_impl(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle, sort: u32,
    out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    if !valid(t, root) || (!h.is_null() && !handle_ok(t, h)) { return 0; }
    let set = expanded_set(t, expanded, n_expanded);
    let filter = if h.is_null() { None } else { Some(&(*h).0) };
    let rows = crate::outline::visible_rows_sorted(&*t, root, &set, filter, crate::outline::SortMode::from_u32(sort));
    if !out.is_null() {
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap as usize));
    }
    rows.len() as u32
}

// ---- Status-returning entry points. Statuses: 0 OK, 1 STALE, 2 MUTATION_FAILED, 3 INVALID, 4 BUSY. ----
// BUSY and INVALID never come back as a valid empty result: the handle is null and the status says why.

fn filter_from(f: &SpzFilter, text: *const c_char, ext: *const c_char) -> crate::filter::Filter {
    crate::filter::Filter {
        text: unsafe { cstr(text) },
        category_mask: f.category_mask,
        extension: unsafe { cstr(ext) },
        min_size: (f.has_min != 0).then_some(f.min_size),
        max_size: (f.has_max != 0).then_some(f.max_size),
        modified_from: (f.has_from != 0).then_some(f.modified_from),
        modified_to: (f.has_to != 0).then_some(f.modified_to),
    }
}

/// Filter on one captured snapshot; the handle is stamped with that snapshot's (uid, version).
unsafe fn filter_apply_status_inner(t: *const Tree, text: *const c_char, ext: *const c_char, f: SpzFilter, status: *mut i32) -> *mut FilterHandle {
    let set = |s: i32| if !status.is_null() { *status = s };
    if t.is_null() { set(3); return std::ptr::null_mut(); }
    let Some(c) = (*t).capture() else { set(4); return std::ptr::null_mut() };
    let flt = filter_from(&f, text, ext);
    let r = crate::filter::apply_in(&*t, &c.table, &flt);
    set(0);
    Box::into_raw(Box::new(FilterHandle(r, (*t).uid, c.table.version)))
}

/// 0 OK (same tree, same version), 1 STALE (same tree, table changed), 3 INVALID (null or other tree).
#[no_mangle]
pub unsafe extern "C" fn spz_filter_status(t: *const Tree, h: *const FilterHandle) -> i32 {
    legacy(5, || spz_filter_status_impl(t, h))
}

unsafe fn spz_filter_status_impl(t: *const Tree, h: *const FilterHandle) -> i32 {
    if t.is_null() || h.is_null() || (*h).1 != (*t).uid { return 3; }
    if (*h).2 != (*t).table().version || (*h).0.sizes.len() != (*t).len() { 1 } else { 0 }
}

/// Layout on one captured snapshot (optionally filtered). Null plus status on STALE/INVALID/BUSY.
unsafe fn layout_new_status_inner(t: *const Tree, root: NodeId, width: f32, height: f32, h: *const FilterHandle, status: *mut i32) -> *mut Layout {
    let set = |s: i32| if !status.is_null() { *status = s };
    if !valid(t, root) { set(3); return std::ptr::null_mut(); }
    if !h.is_null() {
        let st = spz_filter_status(t, h);
        if st != 0 { set(st); return std::ptr::null_mut(); }
    }
    let Some(c) = (*t).capture() else { set(4); return std::ptr::null_mut() };
    if !h.is_null() && (*h).2 != c.table.version { set(1); return std::ptr::null_mut(); }
    let opts = LayoutOptions { width, height, ..Default::default() };
    let sizes = if h.is_null() { None } else { Some((*h).0.sizes.as_slice()) };
    let rects = crate::layout::layout_in(&*t, &c.table, root, &opts, sizes);
    set(0);
    Box::into_raw(Box::new(Layout { rects, uid: (*t).uid, version: c.table.version }))
}

/// 0 OK, 1 STALE, 3 INVALID.
#[no_mangle]
pub unsafe extern "C" fn spz_layout_status(t: *const Tree, l: *const Layout) -> i32 {
    legacy(5, || spz_layout_status_impl(t, l))
}

unsafe fn spz_layout_status_impl(t: *const Tree, l: *const Layout) -> i32 {
    if t.is_null() || l.is_null() || (*l).uid != (*t).uid { return 3; }
    if (*l).version != (*t).table().version { 1 } else { 0 }
}

/// Panics inside the status entry points never cross the ABI: they come back as null plus status 5 (INTERNAL).
#[no_mangle]
pub unsafe extern "C" fn spz_filter_apply_status(t: *const Tree, text: *const c_char, ext: *const c_char, f: SpzFilter, status: *mut i32) -> *mut FilterHandle {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| filter_apply_status_inner(t, text, ext, f, status)))
        .unwrap_or_else(|_| { if !status.is_null() { *status = 5; } std::ptr::null_mut() })
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_new_status(t: *const Tree, root: NodeId, width: f32, height: f32, h: *const FilterHandle, status: *mut i32) -> *mut Layout {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| layout_new_status_inner(t, root, width, height, h, status)))
        .unwrap_or_else(|_| { if !status.is_null() { *status = 5; } std::ptr::null_mut() })
}

// ---- Snapshot read entry points. One capture per call; the result carries the table version it was read from. ----
// `expected` is a table version the caller already holds (for a count-then-fill pair, or to match a filter/outline it
// published) or u64::MAX for "any". A different version returns STALE with nothing written. A filter handle must be
// from the same version as the captured table, otherwise STALE. BUSY and INVALID are never an empty result.

const ANY_VERSION: u64 = u64::MAX;

unsafe fn snapshot<'a>(t: *const Tree, h: *const FilterHandle, expected: u64, status: *mut i32, version: *mut u64) -> Option<crate::tree::Captured<'a>> {
    let set = |s: i32| if !status.is_null() { *status = s };
    if t.is_null() { set(3); return None; }
    let Some(c) = (*t).capture() else { set(4); return None };
    if expected != ANY_VERSION && c.table.version != expected { set(1); return None; }
    if !h.is_null() {
        if (*h).1 != (*t).uid { set(3); return None; }
        if (*h).2 != c.table.version || (*h).0.sizes.len() != (*t).len() { set(1); return None; }
    }
    if !version.is_null() { *version = c.table.version; }
    set(0);
    Some(c)
}

unsafe fn guarded<R>(status: *mut i32, fallback: R, f: impl FnOnce() -> R) -> R {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| { crate::tree::ffi_failpoint(); f() })).unwrap_or_else(|_| { PANICS.fetch_add(1, Ordering::SeqCst); if !status.is_null() { *status = 5; } fallback })
}

/// Rows of the outline. Returns the total row count; writes up to `cap` rows when `out` is not null.
#[no_mangle]
pub unsafe extern "C" fn spz_outline_rows_status(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle, sort: u32,
    out: *mut crate::outline::Row, cap: u32, expected: u64, version: *mut u64, status: *mut i32,
) -> u32 {
    guarded(status, 0, || {
        if t.is_null() || !valid(t, root) { if !status.is_null() { *status = 3; } return 0; }
        let Some(c) = snapshot(t, h, expected, status, version) else { return 0 };
        let set = expanded_set(t, expanded, n_expanded);
        let filter = if h.is_null() { None } else { Some(&(*h).0) };
        let rows = crate::outline::visible_rows_sorted_in(&*t, &c.table, root, &set, filter, crate::outline::SortMode::from_u32(sort));
        if !out.is_null() { std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap as usize)); }
        rows.len() as u32
    })
}

/// Largest files (filtered when `h` is not null). Returns the count written.
#[no_mangle]
pub unsafe extern "C" fn spz_largest_status(t: *const Tree, h: *const FilterHandle, cap: u32, out: *mut NodeId, expected: u64, version: *mut u64, status: *mut i32) -> u32 {
    guarded(status, 0, || {
        if out.is_null() && cap > 0 { if !status.is_null() { *status = 3; } return 0; }
        let Some(c) = snapshot(t, h, expected, status, version) else { return 0 };
        let v = if h.is_null() { (*t).largest_files_in(&c.table, cap as usize) } else { crate::filter::largest_files(&*t, &(*h).0, cap as usize) };
        for (i, id) in v.iter().enumerate() { *out.add(i) = *id; }
        v.len() as u32
    })
}

/// Like `spz_largest_status`, and also writes each file's size (the filter's size when `h` is not null, else the table
/// size) into `sizes_out` from the SAME capture, so a list never mixes ids from one table with sizes from another.
#[no_mangle]
pub unsafe extern "C" fn spz_largest_sized_status(t: *const Tree, h: *const FilterHandle, cap: u32, out: *mut NodeId, sizes_out: *mut u64, expected: u64, version: *mut u64, status: *mut i32) -> u32 {
    guarded(status, 0, || {
        if (out.is_null() || sizes_out.is_null()) && cap > 0 { if !status.is_null() { *status = 3; } return 0; }
        let Some(c) = snapshot(t, h, expected, status, version) else { return 0 };
        let v = if h.is_null() { (*t).largest_files_in(&c.table, cap as usize) } else { crate::filter::largest_files(&*t, &(*h).0, cap as usize) };
        for (i, id) in v.iter().enumerate() {
            *out.add(i) = *id;
            *sizes_out.add(i) = if h.is_null() { c.table.sizes[*id as usize] } else { let fs = &(*h).0.sizes; fs[*id as usize] };
        }
        v.len() as u32
    })
}

/// Category totals into `out` (CATEGORY_COUNT * 2 u64s). Untouched on a non-OK status.
#[no_mangle]
pub unsafe extern "C" fn spz_category_totals_status(t: *const Tree, h: *const FilterHandle, out: *mut u64, expected: u64, version: *mut u64, status: *mut i32) {
    guarded(status, (), || {
        if out.is_null() { if !status.is_null() { *status = 3; } return; }
        let Some(c) = snapshot(t, h, expected, status, version) else { return };
        let totals = if h.is_null() { (*t).category_totals_in(&c.table) } else { crate::filter::category_totals(&*t, &(*h).0) };
        for (i, (b, n)) in totals.iter().enumerate().take(CATEGORY_COUNT) { *out.add(i * 2) = *b; *out.add(i * 2 + 1) = *n; }
    })
}

/// Node details read from one snapshot. Untouched on a non-OK status.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_node_status(t: *const Tree, id: NodeId, out: *mut SpzNode, expected: u64, version: *mut u64, status: *mut i32) {
    guarded(status, (), || {
        if t.is_null() || out.is_null() || !valid(t, id) { if !status.is_null() { *status = 3; } return; }
        let Some(c) = snapshot(t, std::ptr::null(), expected, status, version) else { return };
        let tr = &*t;
        let r = tr.children(id);
        *out = SpzNode {
            size: c.table.sizes[id as usize],
            own_bytes: tr.own_bytes_in(&c.table.sizes, id),
            parent: tr.parent(id).unwrap_or(u32::MAX),
            child_count: tr.live_child_count_in(&c.table, id),
            first_child: if r.is_empty() { u32::MAX } else { r.start },
            kind: tr.kind(id) as u8,
            category: tr.category(id) as u8,
        };
    })
}

/// Table version a filter result was computed on (0 for null).
#[no_mangle]
pub unsafe extern "C" fn spz_filter_version(h: *const FilterHandle) -> u64 { if h.is_null() { 0 } else { (*h).2 } }

/// Table version a layout was computed on (0 for null).
#[no_mangle]
pub unsafe extern "C" fn spz_layout_version(l: *const Layout) -> u64 { if l.is_null() { 0 } else { (*l).version } }

/// Per-row details for an outline snapshot: node fields plus the size shown for the row (the filter's size when a filter
/// is active, otherwise the node size), all read from the same captured table as the rows.
#[repr(C)]
pub struct SpzRowInfo {
    pub node: SpzNode,
    pub shown: u64,
    /// Direct children the row shows when expanded (see `outline::visible_child_count_in`); equals `node.child_count` with no filter.
    pub visible_children: u32,
}

/// Layout of `SpzRowInfo` as Rust sees it: [size, align, offset of node, offset of shown, offset of visible_children]. The Swift test
/// binary compares it with the imported C struct, so a header/Rust drift fails loudly instead of misreading rows.
#[no_mangle]
pub unsafe extern "C" fn spz_row_info_layout(out: *mut u64) {
    if out.is_null() { return; }
    let v = [std::mem::size_of::<SpzRowInfo>() as u64, std::mem::align_of::<SpzRowInfo>() as u64,
             std::mem::offset_of!(SpzRowInfo, node) as u64, std::mem::offset_of!(SpzRowInfo, shown) as u64, std::mem::offset_of!(SpzRowInfo, visible_children) as u64];
    for (i, x) in v.iter().enumerate() { *out.add(i) = *x; }
}

/// Rows, per-row details, the displayed root's shown size and the whole tree's total in ONE capture. Returns the row
/// count; writes rows and infos (up to `cap`) when both outputs are non-null. Non-OK status writes nothing.
#[no_mangle]
pub unsafe extern "C" fn spz_outline_snapshot_status(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle, sort: u32,
    rows_out: *mut crate::outline::Row, infos_out: *mut SpzRowInfo, cap: u32,
    expected: u64, version: *mut u64, root_shown: *mut u64, total_bytes: *mut u64, status: *mut i32,
) -> u32 {
    guarded(status, 0, || {
        if t.is_null() || !valid(t, root) { if !status.is_null() { *status = 3; } return 0; }
        let Some(c) = snapshot(t, h, expected, status, version) else { return 0 };
        let tr = &*t;
        let set = expanded_set(t, expanded, n_expanded);
        let filter = if h.is_null() { None } else { Some(&(*h).0) };
        let rows = crate::outline::visible_rows_sorted_in(tr, &c.table, root, &set, filter, crate::outline::SortMode::from_u32(sort));
        let sizes = &c.table.sizes;
        let shown = |n: NodeId| -> u64 { filter.map(|f| f.sizes[n as usize]).unwrap_or(sizes[n as usize]) };
        if !root_shown.is_null() { *root_shown = shown(root); }
        if !total_bytes.is_null() { *total_bytes = sizes[0]; }
        if !rows_out.is_null() && !infos_out.is_null() {
            for (i, r) in rows.iter().enumerate().take(cap as usize) {
                *rows_out.add(i) = *r;
                let ch = tr.children(r.node);
                *infos_out.add(i) = SpzRowInfo {
                    node: SpzNode {
                        size: sizes[r.node as usize], own_bytes: tr.own_bytes_in(sizes, r.node),
                        parent: tr.parent(r.node).unwrap_or(u32::MAX), child_count: tr.live_child_count_in(&c.table, r.node),
                        first_child: if ch.is_empty() { u32::MAX } else { ch.start },
                        kind: tr.kind(r.node) as u8, category: tr.category(r.node) as u8,
                    },
                    shown: shown(r.node),
                    visible_children: crate::outline::visible_child_count_in(tr, &c.table, r.node, filter),
                };
            }
        }
        rows.len() as u32
    })
}
