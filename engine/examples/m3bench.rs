// Ad-hoc M3 stall-candidate measurements (Linux sandbox). NOT shipped; run locally only.
use spacelyzer_engine::*;
use std::collections::HashSet;
use std::path::Path;
use std::time::Instant;

fn ms(t: Instant) -> f64 { t.elapsed().as_secs_f64() * 1e3 }

fn main() {
    let root = std::env::args().nth(1).expect("fixture root");
    let root = Path::new(&root);
    let opts = ScanOptions::default();
    let progress = ScanProgress::default();
    let t = Instant::now();
    let tree = scan(root, &opts, &progress).unwrap();
    println!("scan: {} nodes in {:.1}ms, root size={}", tree.len(), ms(t), tree.size(0));

    // Huge-folder expansion: root expanded, sibling order native (SizeDesc) vs NameAsc.
    let mut ex = HashSet::new();
    ex.insert(0u32);
    for mode in [outline::SortMode::SizeDesc, outline::SortMode::NameAsc] {
        let t = Instant::now();
        let rows = outline::visible_rows_sorted(&tree, 0, &ex, None, mode);
        println!("expand {mode:?}: {} rows in {:.1}ms", rows.len(), ms(t));
    }

    // Typing: full-tree text filter (what the debounced Rust pass pays per keystroke batch).
    let f = Filter { text: "invoice".into(), ..Default::default() };
    let t = Instant::now();
    let r = apply_filter(&tree, &f);
    println!("filter text=invoice: {} matches in {:.1}ms", r.total_count, ms(t));

    // Treemap relayout at a real window size.
    // This sandbox fs reports st_blocks=0 for every file, so scanned sizes are all 0
    // and `layout` bails on a zero total. Synthesize per-node sizes (subtree sums of a
    // deterministic per-file pseudo size) and measure through `layout_with` instead.
    let n = tree.len();
    let mut sizes = vec![0u64; n];
    for id in (0..n as u32).rev() {
        let own = if matches!(tree.kind(id), Kind::File) { 4096 + (id as u64 % 97) * 512 } else { 0 };
        sizes[id as usize] += own;
        if id != 0 { /* parent unknown here; accumulate below */ }
    }
    // Post-order accumulation needs parents; children ranges are contiguous, so do it
    // with an explicit stack from the root.
    let mut order: Vec<u32> = Vec::with_capacity(n);
    let mut stack = vec![0u32];
    while let Some(id) = stack.pop() {
        order.push(id);
        stack.extend(tree.children(id));
    }
    for &id in order.iter().rev() {
        for c in tree.children(id) { sizes[id as usize] += sizes[c as usize]; }
    }
    let lo = LayoutOptions { width: 1920.0, height: 1080.0, ..Default::default() };
    let t = Instant::now();
    let rects = layout_with(&tree, 0, &lo, Some(&sizes));
    println!("layout (synthesized sizes, st_blocks=0 on this fs): {} rects in {:.1}ms", rects.len(), ms(t));
}
