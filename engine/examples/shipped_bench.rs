//! Shipped-profile timing of FFI calls on a synthetic in-memory tree (median of 9 per call). Not a parity claim.
//! Build twice (panic=unwind vs panic=abort via CARGO_PROFILE_RELEASE_PANIC) and alternate processes.
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::tree::Tree;
use std::time::Instant;
fn med(mut v: Vec<f64>) -> f64 { v.sort_by(|a, b| a.partial_cmp(b).unwrap()); v[v.len() / 2] }
fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1_000_000);
    let t = Box::into_raw(Box::new(Tree::synthetic(n)));
    let (mut lay, mut big, mut node, mut forget) = (vec![], vec![], vec![], vec![]);
    unsafe {
        for _ in 0..9 {
            let mut st = -1i32;
            let s = Instant::now(); let l = spz_layout_new_status(t, 0, 1000.0, 800.0, std::ptr::null(), &mut st); lay.push(s.elapsed().as_secs_f64() * 1e3); spz_layout_free(l);
            let mut ids = vec![0u32; 200]; let mut v = 0u64;
            let s = Instant::now(); spz_largest_status(t, std::ptr::null(), 200, ids.as_mut_ptr(), u64::MAX, &mut v, &mut st); big.push(s.elapsed().as_secs_f64() * 1e3);
            let mut nd = std::mem::zeroed::<SpzNode>();
            let s = Instant::now(); for i in 0..10_000u32 { spz_tree_node_status(t, i % 1000, &mut nd, u64::MAX, &mut v, &mut st); } node.push(s.elapsed().as_secs_f64() * 1e3 / 10_000.0 * 1e3); // microseconds per call
            let f = Box::into_raw(Box::new(Tree::synthetic(n)));
            let s = Instant::now(); spz_tree_forget(f, 1); forget.push(s.elapsed().as_secs_f64() * 1e3); spz_tree_free(f);
        }
    }
    println!("layout_ms {:.2} largest_ms {:.2} node_status_us {:.3} forget_ms {:.2}", med(lay), med(big), med(node), med(forget));
}
