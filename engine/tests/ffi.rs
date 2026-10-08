//! Engine-only tests for the C ABI boundary contract in `src/ffi.rs`: null handles,
//! out-of-range node ids and foreign filter handles must yield empty/zero results,
//! never a crash (a panic across the boundary aborts the app in release).
//! Linux-verifiable: synthetic trees only, no filesystem, no macOS APIs.

use spacelyzer_engine::category::CATEGORY_COUNT;
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::tree::Tree;
use std::ptr;

/// Synthetic trees default to uid 0 (real uids are assigned when a scanned tree is
/// handed across the FFI), so tests assign distinct non-zero uids explicitly.
fn synthetic_raw(n: usize, uid: u64) -> *mut Tree {
    let mut t = Tree::synthetic(n);
    t.uid = uid;
    Box::into_raw(Box::new(t))
}

fn empty_filter() -> SpzFilter {
    SpzFilter {
        category_mask: 0,
        has_min: 0,
        has_max: 0,
        has_from: 0,
        has_to: 0,
        min_size: 0,
        max_size: 0,
        modified_from: 0,
        modified_to: 0,
    }
}

#[test]
fn null_tree_reads_are_zero_or_empty() {
    unsafe {
        assert_eq!(spz_tree_node_count(ptr::null()), 0);
        assert_eq!(spz_tree_cancelled(ptr::null()), 0);

        let n = spz_tree_node(ptr::null(), 0);
        assert_eq!(n.size, 0);
        assert_eq!(n.own_bytes, 0);
        assert_eq!(n.parent, u32::MAX);
        assert_eq!(n.child_count, 0);
        assert_eq!(n.first_child, u32::MAX);

        let name = spz_tree_name(ptr::null(), 0);
        assert!(!name.is_null());
        assert_eq!(std::ffi::CStr::from_ptr(name).to_bytes(), b"");
        spz_string_free(name);

        let path = spz_tree_path(ptr::null(), 0);
        assert!(!path.is_null());
        assert_eq!(std::ffi::CStr::from_ptr(path).to_bytes(), b"");
        spz_string_free(path);

        assert_eq!(spz_tree_find(ptr::null(), ptr::null()), u32::MAX);

        // category totals: out buffer must be left untouched
        let mut out = [7u64; CATEGORY_COUNT * 2];
        spz_tree_category_totals(ptr::null(), out.as_mut_ptr());
        assert_eq!(out, [7u64; CATEGORY_COUNT * 2]);

        // largest files: no writes, count 0
        let mut ids = [9u32; 4];
        assert_eq!(spz_tree_largest_files(ptr::null(), 4, ids.as_mut_ptr()), 0);
        assert_eq!(ids, [9u32; 4]);

        // outline rows over a null tree
        assert_eq!(
            spz_outline_rows_sorted(ptr::null(), 0, ptr::null(), 0, ptr::null(), 0, ptr::null_mut(), 0),
            0
        );

        // filter apply on a null tree returns a null handle
        assert!(spz_filter_apply(ptr::null(), ptr::null(), ptr::null(), empty_filter()).is_null());

        // filter accessors tolerate a null handle
        assert_eq!(spz_filter_total_bytes(ptr::null()), 0);
        assert_eq!(spz_filter_total_count(ptr::null()), 0);
        assert_eq!(spz_filter_size(ptr::null(), 0), 0);
        assert_eq!(spz_filter_count(ptr::null(), 0), 0);

        // frees tolerate null
        spz_tree_free(ptr::null_mut());
        spz_string_free(ptr::null_mut());
        spz_filter_free(ptr::null_mut());
        spz_scan_free(ptr::null_mut());
        spz_layout_free(ptr::null_mut());
    }
}

#[test]
fn null_out_buffers_are_safe() {
    unsafe {
        let t = synthetic_raw(64, 1);
        // null out pointers must not be written through
        spz_tree_category_totals(t, ptr::null_mut());
        assert_eq!(spz_tree_largest_files(t, 4, ptr::null_mut()), 0);
        spz_tree_free(t);
    }
}

#[test]
fn synthetic_tree_round_trip() {
    unsafe {
        let t = synthetic_raw(200, 1);
        assert_eq!(spz_tree_node_count(t), 200);
        let root = spz_tree_node(t, 0);
        assert_eq!(root.parent, u32::MAX);
        assert!(root.child_count > 0);

        let name = spz_tree_name(t, 0);
        assert!(!name.is_null());
        assert!(!std::ffi::CStr::from_ptr(name).to_bytes().is_empty());
        spz_string_free(name);

        spz_tree_free(t);
    }
}

#[test]
fn out_of_range_ids_return_zero_not_panic() {
    unsafe {
        let t = synthetic_raw(50, 1);
        let len = spz_tree_node_count(t) as u32;

        let n = spz_tree_node(t, len + 1000);
        assert_eq!(n.size, 0);
        assert_eq!(n.parent, u32::MAX);
        assert_eq!(n.first_child, u32::MAX);

        let name = spz_tree_name(t, len + 1000);
        assert_eq!(std::ffi::CStr::from_ptr(name).to_bytes(), b"");
        spz_string_free(name);

        // expanded ids outside the arena are dropped, never indexed
        let foreign = [len + 5, len + 6];
        let rows = spz_outline_rows_sorted(t, 0, foreign.as_ptr(), 2, ptr::null(), 0, ptr::null_mut(), 0);
        assert!(rows > 0, "root children still listed; nothing expanded");

        spz_tree_free(t);
    }
}

#[test]
fn foreign_filter_handle_yields_zero_rows() {
    unsafe {
        let a = synthetic_raw(100, 1);
        let b = synthetic_raw(100, 2);

        let h = spz_filter_apply(a, ptr::null(), ptr::null(), empty_filter());
        assert!(!h.is_null());

        // the handle answers for its own tree
        assert!(spz_outline_rows_sorted(a, 0, ptr::null(), 0, h, 0, ptr::null_mut(), 0) > 0);
        // and is rejected for any other tree (uid mismatch), even of identical shape
        assert_eq!(spz_outline_rows_sorted(b, 0, ptr::null(), 0, h, 0, ptr::null_mut(), 0), 0);

        spz_filter_free(h);
        spz_tree_free(a);
        spz_tree_free(b);
    }
}
