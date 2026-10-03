// Paired baseline/candidate bench: identical source, built once against 8b7d24b and once against the slice-1 branch.
use spacelyzer_engine::*;
use std::time::Instant;
fn med(mut v: Vec<f64>) -> f64 { v.sort_by(|a, b| a.partial_cmp(b).unwrap()); v[v.len() / 2] }
fn rep<F: FnMut()>(k: usize, mut f: F) -> (f64, f64) { let mut v = vec![]; for _ in 0..k { let t = Instant::now(); f(); v.push(t.elapsed().as_secs_f64() * 1e3); } (v[0], med(v)) }
#[test]
#[ignore]
fn paired() {
    for n in [1_000_000usize, 2_000_000, 5_000_000] {
        let t = Tree::synthetic(n);
        let flt = Filter { text: "a".into(), ..Default::default() };
        let o = LayoutOptions { width: 1200.0, height: 800.0, ..Default::default() };
        let (_, f) = rep(7, || { let _ = apply_filter(&t, &flt); });
        let (_, l) = rep(7, || { let _ = layout(&t, 0, &o); });
        let (_, g) = rep(7, || { let _ = t.largest_files(200); });
        // forget: fresh identical tree each iteration; only the forget call is timed
        let id = (1..t.len() as u32).filter(|&i| t.children(i).len() > 3).nth(1000).unwrap();
        let mut fv = vec![];
        for _ in 0..7 { let mut x = Tree::synthetic(n); let s = Instant::now(); x.forget(id); fv.push(s.elapsed().as_secs_f64() * 1e3); }
        let fmed = med(fv.clone());
        println!("n={n} filter {f:.1} layout {l:.2} largest200 {g:.1} forget(fresh each) median {fmed:.2} first {:.2} (ms, medians of 7)", fv[0]);
    }
}
