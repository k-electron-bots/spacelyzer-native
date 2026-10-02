//! C ABI for the Swift app. All handles are opaque pointers owned by the caller and freed
//! with the matching `spz_*_free`. Strings returned to the caller are freed with
//! `spz_string_free`. Functions never panic across the boundary (panic = abort in release).
#![allow(clippy::missing_safety_doc)]

use crate::category::CATEGORY_COUNT;
use crate::layout::{hit_test, layout, LayoutOptions, Rect};
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

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

/// Start scanning `root` on a background thread. `excludes` is a newline-separated list of
/// absolute paths (may be null). Returns a handle immediately.
#[no_mangle]
pub unsafe extern "C" fn spz_scan_start(root: *const c_char, excludes: *const c_char) -> *mut Scan {
    let root = PathBuf::from(cstr(root));
    let opts = ScanOptions {
        exclude: cstr(excludes).lines().filter(|l| !l.is_empty()).map(PathBuf::from).collect(),
        ..Default::default()
    };
    let progress = Arc::new(ScanProgress::default());
    let result = Arc::new(Mutex::new(None));
    let (p2, r2) = (progress.clone(), result.clone());
    let h = std::thread::spawn(move || {
        let r = scan(&root, &opts, &p2);
        *r2.lock().unwrap() = Some(r);
    });
    Box::into_raw(Box::new(Scan { progress, result, handle: Mutex::new(Some(h)) }))
}

#[no_mangle]
pub unsafe extern "C" fn spz_scan_progress(s: *const Scan) -> SpzProgress {
    let s = &*s;
    let guard = s.result.lock().unwrap();
    SpzProgress {
        items: s.progress.items.load(Ordering::Relaxed),
        bytes: s.progress.bytes.load(Ordering::Relaxed),
        finished: guard.is_some() as u8,
        failed: matches!(&*guard, Some(Err(_))) as u8,
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_scan_cancel(s: *const Scan) {
    (*s).progress.cancel();
}

/// Take the finished tree out of the scan handle. Null if not finished, failed, or already taken.
#[no_mangle]
pub unsafe extern "C" fn spz_scan_take_tree(s: *mut Scan) -> *mut Tree {
    let s = &*s;
    let h = s.handle.lock().unwrap().take();
    if let Some(h) = h {
        let _ = h.join();
    }
    let r = s.result.lock().unwrap().take();
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
    let h = s.handle.lock().unwrap().take();
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
    if t.is_null() { return 0; }
    (*t).len() as u64
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_cancelled(t: *const Tree) -> u8 {
    (*t).cancelled as u8
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_node(t: *const Tree, id: NodeId) -> SpzNode {
    if !valid(t, id) {
        return SpzNode { size: 0, own_bytes: 0, parent: u32::MAX, child_count: 0, first_child: u32::MAX, kind: 0, category: 0 };
    }
    let t = &*t;
    let r = t.children(id);
    SpzNode {
        size: t.size(id),
        own_bytes: t.own_bytes(id),
        parent: t.parent(id).unwrap_or(u32::MAX),
        child_count: t.child_count(id),
        first_child: if r.is_empty() { u32::MAX } else { r.start },
        kind: t.kind(id) as u8,
        category: t.category(id) as u8,
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_name(t: *const Tree, id: NodeId) -> *mut c_char {
    if !valid(t, id) { return to_c(String::new()); }
    let t = &*t;
    to_c(if id == 0 { t.root_path().to_string() } else { t.name(id).to_string() })
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_path(t: *const Tree, id: NodeId) -> *mut c_char {
    if !valid(t, id) { return to_c(String::new()); }
    to_c((*t).path(id))
}

/// Node for an absolute path under the scanned root, or u32::MAX.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_find(t: *const Tree, path: *const c_char) -> NodeId {
    (*t).find(&cstr(path)).unwrap_or(u32::MAX)
}

/// Remove a subtree from the result after it was moved to the Trash.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_forget(t: *mut Tree, id: NodeId) {
    if !valid(t, id) { return; }
    (*t).forget(id);
}

/// Writes (bytes, items) pairs for each category into `out` (CATEGORY_COUNT * 2 u64s).
#[no_mangle]
pub unsafe extern "C" fn spz_tree_category_totals(t: *const Tree, out: *mut u64) {
    let totals = (*t).category_totals();
    for (i, (b, n)) in totals.iter().enumerate().take(CATEGORY_COUNT) {
        *out.add(i * 2) = *b;
        *out.add(i * 2 + 1) = *n;
    }
}

/// Fill `out` with up to `cap` ids of the largest files; returns the count written.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_largest_files(t: *const Tree, cap: u32, out: *mut NodeId) -> u32 {
    let v = (*t).largest_files(cap as usize);
    for (i, id) in v.iter().enumerate() {
        *out.add(i) = *id;
    }
    v.len() as u32
}

/// Number of skipped locations, and accessors for them.
#[no_mangle]
pub unsafe extern "C" fn spz_tree_skipped_count(t: *const Tree) -> u32 {
    (*t).skipped.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_skipped_path(t: *const Tree, i: u32) -> *mut c_char {
    to_c((&*t).skipped.get(i as usize).map(|s| s.path.clone()).unwrap_or_default())
}

#[no_mangle]
pub unsafe extern "C" fn spz_tree_skipped_reason(t: *const Tree, i: u32) -> u8 {
    (&*t).skipped.get(i as usize).map(|s| s.reason as u8).unwrap_or(1)
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_new(t: *const Tree, root: NodeId, width: f32, height: f32) -> *mut Layout {
    let opts = LayoutOptions { width, height, ..Default::default() };
    if !valid(t, root) { return Box::into_raw(Box::new(Layout { rects: Vec::new() })); }
    Box::into_raw(Box::new(Layout { rects: layout(&*t, root, &opts) }))
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_free(l: *mut Layout) {
    if !l.is_null() {
        drop(Box::from_raw(l));
    }
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_count(l: *const Layout) -> u32 {
    (&*l).rects.len() as u32
}

/// Pointer to the contiguous `Rect` array (valid until `spz_layout_free`).
#[no_mangle]
pub unsafe extern "C" fn spz_layout_rects(l: *const Layout) -> *const Rect {
    (&*l).rects.as_ptr()
}

/// Index of the rect under the point, or u32::MAX.
#[no_mangle]
pub unsafe extern "C" fn spz_layout_hit(l: *const Layout, x: f32, y: f32) -> u32 {
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

pub struct FilterHandle(crate::filter::FilterResult, u64);

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
    let flt = crate::filter::Filter {
        text: cstr(text),
        category_mask: f.category_mask,
        extension: cstr(ext),
        min_size: (f.has_min != 0).then_some(f.min_size),
        max_size: (f.has_max != 0).then_some(f.max_size),
        modified_from: (f.has_from != 0).then_some(f.modified_from),
        modified_to: (f.has_to != 0).then_some(f.modified_to),
    };
    Box::into_raw(Box::new(FilterHandle(crate::filter::apply(&*t, &flt), (*t).uid)))
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
pub unsafe extern "C" fn spz_filter_size(h: *const FilterHandle, id: NodeId) -> u64 { if h.is_null() { return 0; } (&(*h).0.sizes).get(id as usize).copied().unwrap_or(0) }

/// Matching file count under one node.
#[no_mangle]
pub unsafe extern "C" fn spz_filter_count(h: *const FilterHandle, id: NodeId) -> u32 { if h.is_null() { return 0; } (&(*h).0.counts).get(id as usize).copied().unwrap_or(0) }

/// Like `spz_outline_rows`, but hides nodes with no matching bytes. Pass the handle from `spz_filter_apply`.
#[no_mangle]
pub unsafe extern "C" fn spz_outline_rows_filtered(
    t: *const Tree, root: NodeId, expanded: *const NodeId, n_expanded: u32, h: *const FilterHandle,
    out: *mut crate::outline::Row, cap: u32,
) -> u32 {
    if !valid(t, root) || !handle_ok(t, h) { return 0; }
    let set = expanded_set(t, expanded, n_expanded);
    let rows = crate::outline::visible_rows(&*t, root, &set, Some(&(*h).0.sizes));
    if !out.is_null() {
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap as usize));
    }
    rows.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn spz_layout_new_filtered(t: *const Tree, root: NodeId, width: f32, height: f32, h: *const FilterHandle) -> *mut Layout {
    let opts = LayoutOptions { width, height, ..Default::default() };
    if !valid(t, root) || !handle_ok(t, h) { return Box::into_raw(Box::new(Layout { rects: Vec::new() })); }
    Box::into_raw(Box::new(Layout { rects: crate::layout::layout_with(&*t, root, &opts, Some(&(*h).0.sizes)) }))
}

/// Largest matching files under a filter; returns the count written (up to `cap`).
#[no_mangle]
pub unsafe extern "C" fn spz_filter_largest_files(t: *const Tree, h: *const FilterHandle, cap: u32, out: *mut NodeId) -> u32 {
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
    if !valid(t, root) || (!h.is_null() && !handle_ok(t, h)) { return 0; }
    let set = expanded_set(t, expanded, n_expanded);
    let sizes = if h.is_null() { None } else { Some((*h).0.sizes.as_slice()) };
    let rows = crate::outline::visible_rows_sorted(&*t, root, &set, sizes, crate::outline::SortMode::from_u32(sort));
    if !out.is_null() {
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out, rows.len().min(cap as usize));
    }
    rows.len() as u32
}
