//! Random forget() sequences over NESTED nodes (ancestors after descendants and the reverse, repeats), checked against an independent oracle:
//! expected size(n) = 0 if n or any ancestor was forgotten, else own(n) + sum(expected size of children), with own(n) frozen from the scan.
use spacelyzer_engine::scan::{new_progress, scan, ScanOptions};

fn lcg(s: &mut u64) -> u64 { *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); *s >> 33 }

#[test]
fn nested_random_forgets_match_the_oracle_and_never_underflow() {
    let d = std::env::temp_dir().join(format!("spz-nested-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let mut seed = 7u64;
    for a in 0..5 { for b in 0..4 { for c in 0..3 {
        let p = d.join(format!("a{a}/b{b}/c{c}")); std::fs::create_dir_all(&p).unwrap();
        for i in 0..(lcg(&mut seed) % 4) { std::fs::write(p.join(format!("f{i}")), vec![1u8; 1 + (lcg(&mut seed) % 20000) as usize]).unwrap(); }
    } std::fs::write(d.join(format!("a{a}/b{b}/mid")), vec![1u8; 5000]).unwrap(); } }
    let t = scan(&d, &ScanOptions::default(), &new_progress()).unwrap();
    let n = t.len();
    let sizes0 = t.table().sizes.clone();
    let own: Vec<u64> = (0..n as u32).map(|i| t.own_bytes_in(&sizes0, i)).collect();
    let mut dead = vec![false; n];
    for round in 0..300 {
        let id = (lcg(&mut seed) % n as u64) as u32;
        t.forget(id).unwrap();
        dead[id as usize] = true;
        let sz = t.table().sizes.clone();
        // oracle, children always have larger ids than parents (breadth-first), so go in reverse
        let mut exp = vec![0u64; n];
        let mut anc_dead = vec![false; n];
        for i in 0..n { if let Some(p) = t.parent(i as u32) { anc_dead[i] = anc_dead[p as usize] || dead[p as usize]; } }
        for i in (0..n).rev() {
            if dead[i] || anc_dead[i] { exp[i] = 0; continue; }
            let kids: u64 = t.children(i as u32).map(|c| exp[c as usize]).sum();
            exp[i] = own[i] + kids;
        }
        assert_eq!(sz, exp, "round {round} after forgetting {id}");
    }
    let _ = std::fs::remove_dir_all(&d);
}
