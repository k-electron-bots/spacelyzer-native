// Candidate hot-path timings through the real accessors. Run: cargo test --release --test hotpath_bench -- --ignored --nocapture
use spacelyzer_engine::*;
use spacelyzer_engine::ffi::*;
use std::time::Instant;
fn med(mut v: Vec<f64>) -> f64 { v.sort_by(|a, b| a.partial_cmp(b).unwrap()); v[v.len() / 2] }
fn time<F: FnMut()>(mut f: F) -> (f64, f64) { let mut v = vec![]; for _ in 0..5 { let t = Instant::now(); f(); v.push(t.elapsed().as_secs_f64() * 1e3); } (v[0], med(v)) }
#[test]
#[ignore]
fn hotpaths() {
    for n in [1_000_000usize, 2_000_000, 5_000_000] {
        let mut t = Tree::synthetic(n); t.uid = 1;
        let tp = &t as *const Tree;
        let flt = Filter { text: "a".into(), ..Default::default() };
        let (c1, m1) = time(|| { let c = t.capture().unwrap(); let _ = filter::apply_in(&t, &c.table, &flt); });
        let (c2, m2) = time(|| { let c = t.capture().unwrap(); let _ = layout::layout_in(&t, &c.table, 0, &LayoutOptions { width: 1200.0, height: 800.0, ..Default::default() }, None); });
        let (c3, m3) = time(|| { let _ = t.largest_files(200); });
        let (c4, m4) = time(|| unsafe { let mut s = 0; let h = spz_filter_apply_status(tp, std::ptr::null(), std::ptr::null(), std::mem::zeroed(), &mut s); assert!(s == 0); spz_filter_free(h); });
        let ids: Vec<u32> = (1..t.len() as u32).filter(|&i| !t.children(i).is_empty()).step_by(50_000).take(5).collect();
        let mut k = 0; let (c5, m5) = time(|| { let _ = t.forget(ids[k % ids.len()]); k += 1; });
        let (c6, m6) = time(|| unsafe { for i in 0..1000u32 { let _ = spz_tree_node(tp, i); } });
        println!("n={n}: filter {c1:.1}/{m1:.1}ms layout {c2:.1}/{m2:.1} largest200 {c3:.1}/{m3:.1} ffi_filter_status {c4:.1}/{m4:.1} forget {c5:.2}/{m5:.2} node x1000 {c6:.3}/{m6:.3} (cold/median)");
    }
}
