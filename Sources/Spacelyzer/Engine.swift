import CSpacelyzer
import Foundation

/// Thin Swift wrapper over the Rust engine's C ABI. Everything heavy happens in Rust.
enum NodeKind: UInt8 { case file = 0, directory, package, symlink }

enum FileCategory: Int, CaseIterable {
    case folder, image, video, audio, document, archive, code, application, data, font, other
    var label: String {
        switch self {
        case .folder: "Folders"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Documents"
        case .archive: "Archives"
        case .code: "Code"
        case .application: "Applications"
        case .data: "Data"
        case .font: "Fonts"
        case .other: "Other"
        }
    }
}

struct NodeInfo {
    var size: UInt64
    var ownBytes: UInt64
    var parent: UInt32?
    var childCount: Int
    var firstChild: UInt32
    var kind: NodeKind
    var category: FileCategory
}

let noNode = UInt32.max

/// Outline rows with their details, all from one engine table version. `version` is the engine's stamp, never a re-read.
struct OutlineSnapshot {
    var rows: [SpzRow]
    var infos: [NodeInfo]
    /// Size shown for each row: the filter's size when a filter is active, else the node size. Same snapshot as the rows.
    var shown: [UInt64]
    var version: UInt64
    var rootSize: UInt64
    var totalBytes: UInt64
}
struct DerivedSnapshot {
    var ids: [UInt32]
    /// Size of each id, from the same capture as the ids (filter size when filtered).
    var sizes: [UInt64]
    var kinds: [(category: FileCategory, bytes: UInt64, items: UInt64)]
    var version: UInt64
}

/// Engine status codes (spacelyzer.h). A non-ok status is never turned into an empty or zero value.
enum EngineStatus: Int32, Error {
    case ok = 0, stale, mutationFailed, invalid, busy, internalError
    init(raw: Int32) { self = EngineStatus(rawValue: raw) ?? .internalError }
}

/// CI-only timing log (SPZ_DEMO): appends "label: value" lines to /tmp/spz-timing.txt.
enum Perf {
    static let on = ProcessInfo.processInfo.environment["SPZ_DEMO"] != nil
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
    static func log(_ line: String) {
        guard on else { return }
        let url = URL(fileURLWithPath: "/tmp/spz-timing.txt")
        let data = (line + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }
}

final class FilterResult: @unchecked Sendable {
    let ptr: OpaquePointer
    /// Table version this result was computed on (stamped by the engine from the same capture as the data).
    let version: UInt64
    init(_ p: OpaquePointer) { ptr = p; version = spz_filter_version(p) }
    deinit { spz_filter_free(ptr) }
    var totalBytes: UInt64 { spz_filter_total_bytes(ptr) }
    var totalCount: UInt64 { spz_filter_total_count(ptr) }
    func size(_ id: UInt32) -> UInt64 { spz_filter_size(ptr, id) }
    /// Match presence is independent of allocated size (empty and sparse files can be zero).
    func count(_ id: UInt32) -> UInt32 { spz_filter_count(ptr, id) }
}

final class Tree: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ p: OpaquePointer) { ptr = p }
    deinit { spz_tree_free(ptr) }

    var wasCancelled: Bool { spz_tree_cancelled(ptr) != 0 }

    func info(_ id: UInt32) -> NodeInfo {
        // Bounds-checked at the FFI edge: a stale id from a previous tree must never reach Rust (a Rust panic aborts the app).
        guard UInt64(id) < nodeCount else {
            return NodeInfo(size: 0, ownBytes: 0, parent: nil, childCount: 0, firstChild: 0, kind: .file, category: .other)
        }
        let n = spz_tree_node(ptr, id)
        return NodeInfo(
            size: n.size, ownBytes: n.own_bytes,
            parent: n.parent == noNode ? nil : n.parent,
            childCount: Int(n.child_count), firstChild: n.first_child,
            kind: NodeKind(rawValue: n.kind) ?? .file,
            category: FileCategory(rawValue: Int(n.category)) ?? .other
        )
    }

    private func take(_ s: UnsafeMutablePointer<CChar>?) -> String {
        guard let s else { return "" }
        defer { spz_string_free(s) }
        return String(cString: s)
    }

    func name(_ id: UInt32) -> String { guard UInt64(id) < nodeCount else { return "" }; return take(spz_tree_name(ptr, id)) }
    func path(_ id: UInt32) -> String { guard UInt64(id) < nodeCount else { return "" }; return take(spz_tree_path(ptr, id)) }
    func find(path: String) -> UInt32? {
        let id = spz_tree_find(ptr, path)
        return id == noNode ? nil : id
    }
    /// Visible outline rows (node, depth), flattened in Rust from the expanded set. No cap.
    func outlineRows(root: UInt32, expanded: Set<UInt32>, filter: FilterResult? = nil, sort: OutlineSort = .sizeDescending) -> [SpzRow] {
        let ex = Array(expanded)
        func call(_ out: UnsafeMutablePointer<SpzRow>?, _ cap: Int, _ e: UnsafeBufferPointer<UInt32>) -> UInt32 {
            spz_outline_rows_sorted(ptr, root, e.baseAddress, UInt32(e.count), filter?.ptr, sort.rawValue, out, UInt32(cap))
        }
        let t0 = Perf.now()
        let n = Int(ex.withUnsafeBufferPointer { call(nil, 0, $0) })
        let t1 = Perf.now()
        var rows = [SpzRow](repeating: SpzRow(node: 0, depth: 0), count: n)
        _ = ex.withUnsafeBufferPointer { e in rows.withUnsafeMutableBufferPointer { call($0.baseAddress, n, e) } }
        Perf.log("outline rows=\(n) expanded=\(ex.count) filtered=\(filter != nil) count_call_ms=\(String(format: "%.2f", Double(t1 - t0) / 1e6)) fill_call_ms=\(String(format: "%.2f", Perf.ms(since: t1)))")
        return rows
    }

    func applyFilter(text: String, kind: FileCategory?, minBytes: UInt64?, maxBytes: UInt64? = nil, modifiedFrom: Int64? = nil, ext: String = "") -> FilterResult {
        let f = SpzFilter(category_mask: kind.map { UInt32(1) << UInt32($0.rawValue) } ?? 0,
                          has_min: minBytes == nil ? 0 : 1, has_max: maxBytes == nil ? 0 : 1,
                          has_from: modifiedFrom == nil ? 0 : 1, has_to: 0,
                          min_size: minBytes ?? 0, max_size: maxBytes ?? 0,
                          modified_from: modifiedFrom ?? 0, modified_to: 0)
        let t0 = Perf.now()
        let h = text.withCString { t in ext.withCString { e in spz_filter_apply(ptr, t, e, f) } }
        Perf.log("filter text='\(text)' ext='\(ext)' kind=\(String(describing: kind)) min=\(String(describing: minBytes)) max=\(String(describing: maxBytes)) from=\(String(describing: modifiedFrom)) rust_ms=\(String(format: "%.2f", Perf.ms(since: t0)))")
        return FilterResult(h!)
    }

    /// Version of the engine's published size table. Changes on every committed removal.
    var version: UInt64 { spz_tree_version(ptr) }

    /// Remove a subtree from the engine's numbers after the filesystem move succeeded. Runs a full table copy
    /// (about 3 ms at 1M nodes, 30 ms at 5M), so call it from the commit lane, never from the main actor.
    /// `.ok`, `.mutationFailed` (tree unchanged) or `.invalid`.
    func forget(_ id: UInt32) -> EngineStatus { EngineStatus(raw: spz_tree_forget(ptr, id)) }

    /// Status API: BUSY, STALE and INVALID come back as errors, never as an empty result.
    func applyFilterChecked(text: String, kind: FileCategory?, minBytes: UInt64?, maxBytes: UInt64? = nil, modifiedFrom: Int64? = nil, ext: String = "") -> Result<FilterResult, EngineStatus> {
        let f = SpzFilter(category_mask: kind.map { UInt32(1) << UInt32($0.rawValue) } ?? 0,
                          has_min: minBytes == nil ? 0 : 1, has_max: maxBytes == nil ? 0 : 1,
                          has_from: modifiedFrom == nil ? 0 : 1, has_to: 0,
                          min_size: minBytes ?? 0, max_size: maxBytes ?? 0,
                          modified_from: modifiedFrom ?? 0, modified_to: 0)
        var status: Int32 = -1
        let h = text.withCString { t in ext.withCString { e in spz_filter_apply_status(ptr, t, e, f, &status) } }
        guard status == 0, let h else { return .failure(status == 0 ? .internalError : EngineStatus(raw: status)) }
        return .success(FilterResult(h))
    }

    /// Is this filter result still computed on the tree's current table? `.ok` or `.stale` (recompute) or `.invalid`.
    func status(of filter: FilterResult) -> EngineStatus { EngineStatus(raw: spz_filter_status(ptr, filter.ptr)) }

    /// Status API layout. The filter result, if any, must be current; otherwise `.stale` (recompute the filter first).
    func layoutChecked(root: UInt32, size: CGSize, filter: FilterResult? = nil) -> Result<TreemapLayout, EngineStatus> {
        var status: Int32 = -1
        let raw = spz_layout_new_status(ptr, root, Float(size.width), Float(size.height), filter?.ptr, &status)
        guard status == 0, let raw else { return .failure(status == 0 ? .internalError : EngineStatus(raw: status)) }
        let l = TreemapLayout(raw, size: size)
        l.treeID = ObjectIdentifier(self)
        return .success(l)
    }

    /// One node read from one engine snapshot. `expected` = a version the caller holds, or nil for any.
    func nodeChecked(_ id: UInt32, expected: UInt64? = nil) -> Result<(info: NodeInfo, version: UInt64), EngineStatus> {
        var n = SpzNode(size: 0, own_bytes: 0, parent: noNode, child_count: 0, first_child: noNode, kind: 0, category: 0)
        var v: UInt64 = 0, st: Int32 = -1
        spz_tree_node_status(ptr, id, &n, expected ?? UInt64.max, &v, &st)
        guard st == 0 else { return .failure(EngineStatus(raw: st)) }
        return .success((NodeInfo(size: n.size, ownBytes: n.own_bytes, parent: n.parent == noNode ? nil : n.parent,
                                  childCount: Int(n.child_count), firstChild: n.first_child,
                                  kind: NodeKind(rawValue: n.kind) ?? .file, category: FileCategory(rawValue: Int(n.category)) ?? .other), v))
    }

    /// Rows, per-row details, shown sizes, root size and tree total from ONE engine capture and ONE table version.
    /// A commit between the count call and the fill call returns STALE and the read restarts (bounded). Every status is
    /// preserved: BUSY stays BUSY, INVALID stays INVALID, STALE with a filter means the filter result is old.
    func outlineSnapshot(root: UInt32, expanded: Set<UInt32>, filter: FilterResult?, sort: OutlineSort) -> Result<OutlineSnapshot, EngineStatus> {
        let ex = Array(expanded)
        for _ in 0..<3 {
            var v: UInt64 = 0, rs: UInt64 = 0, tot: UInt64 = 0, st: Int32 = -1
            let n = Int(ex.withUnsafeBufferPointer { e in spz_outline_snapshot_status(ptr, root, e.baseAddress, UInt32(e.count), filter?.ptr, sort.rawValue, nil, nil, 0, UInt64.max, &v, &rs, &tot, &st) })
            guard st == 0 else { return .failure(EngineStatus(raw: st)) }
            var rows = [SpzRow](repeating: SpzRow(node: 0, depth: 0), count: n)
            var raw = [SpzRowInfo](repeating: SpzRowInfo(node: SpzNode(size: 0, own_bytes: 0, parent: noNode, child_count: 0, first_child: noNode, kind: 0, category: 0), shown: 0), count: n)
            var v2: UInt64 = 0, rs2: UInt64 = 0, tot2: UInt64 = 0, st2: Int32 = -1
            let got = Int(ex.withUnsafeBufferPointer { e in rows.withUnsafeMutableBufferPointer { rb in raw.withUnsafeMutableBufferPointer { ib in
                spz_outline_snapshot_status(ptr, root, e.baseAddress, UInt32(e.count), filter?.ptr, sort.rawValue, rb.baseAddress, ib.baseAddress, UInt32(n), v, &v2, &rs2, &tot2, &st2) } } })
            if st2 == 1 && filter == nil { continue }          // a commit landed between count and fill: read again
            guard st2 == 0 else { return .failure(EngineStatus(raw: st2)) }
            guard got == n, v2 == v else { return .failure(.internalError) }
            let infos = raw.map { r in NodeInfo(size: r.node.size, ownBytes: r.node.own_bytes, parent: r.node.parent == noNode ? nil : r.node.parent,
                                              childCount: Int(r.node.child_count), firstChild: r.node.first_child,
                                              kind: NodeKind(rawValue: r.node.kind) ?? .file, category: FileCategory(rawValue: Int(r.node.category)) ?? .other) }
            return .success(OutlineSnapshot(rows: rows, infos: infos, shown: raw.map { $0.shown }, version: v, rootSize: rs2, totalBytes: tot2))
        }
        return .failure(.stale)
    }

    /// Largest files and per-kind totals read at one table version.
    func derivedSnapshot(filter: FilterResult?, count: Int) -> Result<DerivedSnapshot, EngineStatus> {
        for _ in 0..<3 {
            var ids = [UInt32](repeating: 0, count: count)
            var sizes = [UInt64](repeating: 0, count: count)
            var v: UInt64 = 0, st: Int32 = -1
            let c = ids.withUnsafeMutableBufferPointer { b in sizes.withUnsafeMutableBufferPointer { sb in spz_largest_sized_status(ptr, filter?.ptr, UInt32(count), b.baseAddress, sb.baseAddress, UInt64.max, &v, &st) } }
            guard st == 0 else { return .failure(EngineStatus(raw: st)) }
            var out = [UInt64](repeating: 0, count: 22)
            var v2: UInt64 = 0, st2: Int32 = -1
            out.withUnsafeMutableBufferPointer { b in spz_category_totals_status(ptr, filter?.ptr, b.baseAddress, v, &v2, &st2) }
            if st2 == 1 && filter == nil { continue }
            guard st2 == 0 else { return .failure(EngineStatus(raw: st2)) }
            let kinds = FileCategory.allCases.map { (category: $0, bytes: out[$0.rawValue * 2], items: out[$0.rawValue * 2 + 1]) }
            return .success(DerivedSnapshot(ids: Array(ids.prefix(Int(c))), sizes: Array(sizes.prefix(Int(c))), kinds: kinds, version: v))
        }
        return .failure(.stale)
    }

    /// True when `node` is `ancestor` or lies inside its subtree. Parent links are never changed by a removal.
    func isInside(_ node: UInt32, subtreeOf ancestor: UInt32) -> Bool {
        var cur: UInt32? = node
        var hops = 0
        while let c = cur, UInt64(hops) <= nodeCount {
            if c == ancestor { return true }
            cur = info(c).parent
            hops += 1
        }
        return false
    }

    func children(_ id: UInt32) -> Range<UInt32> {
        let n = info(id)
        guard n.childCount > 0 else { return 0..<0 }
        return n.firstChild..<(n.firstChild + UInt32(n.childCount))
    }

    func categoryTotals(filter: FilterResult? = nil) -> [(category: FileCategory, bytes: UInt64, items: UInt64)] {
        var out = [UInt64](repeating: 0, count: 22)
        out.withUnsafeMutableBufferPointer { b in
            if let f = filter { spz_filter_category_totals(ptr, f.ptr, b.baseAddress) } else { spz_tree_category_totals(ptr, b.baseAddress) }
        }
        return FileCategory.allCases.map { (category: $0, bytes: out[$0.rawValue * 2], items: out[$0.rawValue * 2 + 1]) }
    }

    func largestFiles(_ n: Int, filter: FilterResult? = nil) -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: n)
        let c = ids.withUnsafeMutableBufferPointer { b in
            filter.map { spz_filter_largest_files(ptr, $0.ptr, UInt32(n), b.baseAddress) } ?? spz_tree_largest_files(ptr, UInt32(n), b.baseAddress)
        }
        return Array(ids.prefix(Int(c)))
    }

    /// Count only: footer rendering must not copy every unreadable path.
    var skippedCount: Int { Int(spz_tree_skipped_count(ptr)) }

    var skipped: [(path: String, reason: Int)] {
        (0..<spz_tree_skipped_count(ptr)).map { (take(spz_tree_skipped_path(ptr, $0)), Int(spz_tree_skipped_reason(ptr, $0))) }
    }

    func layout(root: UInt32, size: CGSize, filter: FilterResult? = nil) -> TreemapLayout {
        let t0 = Perf.now()
        let raw = filter.map { spz_layout_new_filtered(ptr, root, Float(size.width), Float(size.height), $0.ptr) } ?? spz_layout_new(ptr, root, Float(size.width), Float(size.height))
        let rustMs = Perf.ms(since: t0)
        let t1 = Perf.now()
        let l = TreemapLayout(raw, size: size)
        l.treeID = ObjectIdentifier(self)
        Perf.log("layout rects=\(l.rects.count) filtered=\(filter != nil) rust_ms=\(String(format: "%.2f", rustMs)) swift_copy_ms=\(String(format: "%.2f", Perf.ms(since: t1)))")
        return l
    }
}

struct TreemapRect: Identifiable {
    var id: Int
    var rect: CGRect
    var node: UInt32
    var depth: Int
    var branch: Int
    var isRemainder: Bool
    var isDirectoryFrame: Bool
    var size: UInt64
}

final class TreemapLayout: @unchecked Sendable {
    private let ptr: OpaquePointer?
    let size: CGSize
    let rects: [TreemapRect]
    /// Identity of the tree these rects (and their node ids) belong to.
    var treeID: ObjectIdentifier?
    /// Table version these rects were computed on (stamped by the engine from the same capture as the data).
    let version: UInt64

    init(_ p: OpaquePointer?, size: CGSize) {
        ptr = p
        self.size = size
        version = p.map { spz_layout_version($0) } ?? 0
        guard let p else { rects = []; return }
        let n = Int(spz_layout_count(p))
        let base = spz_layout_rects(p)
        var out: [TreemapRect] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let r = base![i]
            out.append(TreemapRect(
                id: i, rect: CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h)),
                node: r.node, depth: Int(r.depth), branch: Int(r.branch),
                isRemainder: r.flags == 2, isDirectoryFrame: r.flags == 0, size: r.size))
        }
        rects = out
    }
    deinit { if let ptr { spz_layout_free(ptr) } }

    /// Deepest rectangle under the point, resolved in Rust.
    func hit(_ p: CGPoint) -> TreemapRect? {
        guard let ptr else { return nil }
        let i = spz_layout_hit(ptr, Float(p.x), Float(p.y))
        return i == UInt32.max ? nil : rects[Int(i)]
    }
}

struct ScanSnapshot { var items: UInt64; var bytes: UInt64 }

/// Sticky count of panics the engine caught at its FFI boundary. A legacy read that returns 0/empty after a caught panic
/// looks like valid data, so the app compares this against a per-loaded-tree baseline before trusting or acting on it.
enum EnginePanics { static var count: UInt64 { spz_engine_panic_count() } }

final class ScanSession: @unchecked Sendable {
    private let handle: OpaquePointer
    private let panicsAtStart = EnginePanics.count
    init?(root: String, excludes: [String]) {
        guard let h = spz_scan_start(root, excludes.joined(separator: "\n")) else { return nil }
        handle = h
    }
    deinit { spz_scan_free(handle) }

    func cancel() { spz_scan_cancel(handle) }

    /// Poll until finished, reporting progress ~10x per second.
    func run(progress: @escaping @Sendable (ScanSnapshot) -> Void) async -> Tree? {
        while true {
            let p = spz_scan_progress(handle)
            progress(ScanSnapshot(items: p.items, bytes: p.bytes))
            if p.finished != 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // A panic caught anywhere while this scan ran means its result cannot be trusted: report it as a failed scan.
        if EnginePanics.count != panicsAtStart { if let t = spz_scan_take_tree(handle) { spz_tree_free(t) }; return nil }
        guard let t = spz_scan_take_tree(handle) else { return nil }
        return Tree(t)
    }
}

extension Tree {
    var nodeCount: UInt64 { spz_tree_node_count(ptr) }
}


/// CI-only (SPZ_DEMO): pings the main queue every 5 ms from a background thread and records how late each ping runs.
/// A late ping means the main thread was busy, which is exactly what the user sees as a hitch.
final class MainStall: @unchecked Sendable {
    static let shared = MainStall()
    private let lock = NSLock()
    private var maxMs = 0.0, over16 = 0, over50 = 0, over100 = 0, n = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let t = Thread { [self] in
            while true {
                let t0 = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { [self] in
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    lock.lock(); n += 1; maxMs = Swift.max(maxMs, ms)
                    if ms > 16 { over16 += 1 }; if ms > 50 { over50 += 1 }; if ms > 100 { over100 += 1 }
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        t.qualityOfService = QualityOfService.userInteractive
        t.start()
    }
    func reset() { lock.lock(); maxMs = 0; over16 = 0; over50 = 0; over100 = 0; n = 0; lock.unlock() }
    var peak: Double { lock.lock(); defer { lock.unlock() }; return maxMs }
    func summary(_ label: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return "stall \(label): max=\(String(format: "%.1f", maxMs))ms pings=\(n) over16=\(over16) over50=\(over50) over100=\(over100)"
    }
}

/// Sibling order of the outline. Raw values match the Rust engine's sort modes.
enum OutlineSort: UInt32, CaseIterable, Identifiable {
    case sizeDescending = 0, sizeAscending = 1, name = 2, items = 3, modified = 4
    var id: UInt32 { rawValue }
    var label: String {
        switch self {
        case .sizeDescending: "Size, largest first"
        case .sizeAscending: "Size, smallest first"
        case .name: "Name"
        case .items: "Most items"
        case .modified: "Recently modified"
        }
    }
}
