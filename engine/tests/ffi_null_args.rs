//! C-ABI calls with null/garbage arguments must return the documented failure value, never crash or panic across the boundary.
use spacelyzer_engine::ffi::*;
use std::ptr::{null, null_mut};

#[test]
fn null_and_garbage_arguments_fail_closed() {
    unsafe {
        let before = spz_engine_panic_count();
        assert_eq!(spz_outline_rows(null(), 0, null(), 0, null_mut(), 0), 0);
        assert_eq!(spz_outline_rows(null(), 7, null(), u32::MAX, null_mut(), u32::MAX), 0);
        assert_eq!(spz_tree_node_count(null()), 0);
        assert_eq!(spz_tree_forget(null_mut(), 0), 3);
        assert_eq!(spz_tree_find(null(), null()), u32::MAX);
        assert_eq!(spz_layout_count(null()), 0);
        assert_eq!(spz_layout_hit(null(), 1.0, 1.0), u32::MAX);
        assert_eq!(spz_inspect_path(null(), null_mut()), -1);
        spz_scan_cancel(null());
        spz_scan_free(null_mut());
        spz_tree_free(null_mut());
        spz_layout_free(null_mut());
        spz_filter_free(null_mut());
        spz_string_free(null_mut());
        assert!(spz_scan_take_tree(null_mut()).is_null());
        assert_eq!(spz_engine_panic_count(), before, "a null argument must be rejected, not caught as a panic");
    }
}
