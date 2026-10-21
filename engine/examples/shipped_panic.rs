//! Runs against the SHIPPED release profile (cargo test always unwinds, so it cannot show this). Injects a panic inside
//! FFI entry bodies and checks the process survives and the fallback or status 5 comes back.
//! Run: cargo run --release --locked --features failpoints --example shipped_panic
use spacelyzer_engine::ffi::*;
use spacelyzer_engine::tree::{set_failpoint, Tree};

fn main() {
    assert!(cfg!(panic = "unwind"), "this build is not panic=unwind: the guards cannot work");
    let mut fails = 0;
    let mut check = |name: &str, ok: bool| { println!("{} {}", if ok { "PASS" } else { "FAIL" }, name); if !ok { fails += 1; } };
    let t = Box::into_raw(Box::new(Tree::synthetic(1000)));
    unsafe {
        let n = spz_tree_node_count(t);
        check("baseline node_count > 0", n > 0);
        set_failpoint(9);
        check("legacy export: panic in body returns fallback 0", spz_tree_node_count(t) == 0);
        check("legacy export works again after the caught panic", spz_tree_node_count(t) == n);
        set_failpoint(9);
        let (mut node, mut v, mut st) = (std::mem::zeroed::<SpzNode>(), 0u64, -1i32);
        spz_tree_node_status(t, 1, &mut node, u64::MAX, &mut v, &mut st);
        check("status export: panic in body gives status 5", st == 5);
        spz_tree_node_status(t, 1, &mut node, u64::MAX, &mut v, &mut st);
        check("status export OK after the caught panic", st == 0);
        let ver = spz_tree_version(t);
        set_failpoint(3);
        let r = spz_tree_forget(t, 1);
        check("forget: panic before swap returns MUTATION_FAILED (2) and keeps the table", r == 2 && spz_tree_version(t) == ver);
        check("forget works after that", spz_tree_forget(t, 1) == 0);
        spz_tree_free(t);
    }
    if fails > 0 { std::process::exit(1); }
    println!("all shipped-profile panic checks passed");
}
