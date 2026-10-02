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
    init(_ p: OpaquePointer) { ptr = p }
    deinit { spz_filter_free(ptr) }
    var totalBytes: UInt64 { spz_filter_total_bytes(ptr) }
    var totalCount: UInt64 { spz_filter_total_count(ptr) }
    func size(_ id: UInt32) -> UInt64 { spz_filter_size(ptr, id) }
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
    func outlineRows(root: UInt32, expanded: Set<UInt32>, filter: FilterResult? = nil) -> [SpzRow] {
        let ex = Array(expanded)
        func call(_ out: UnsafeMutablePointer<SpzRow>?, _ cap: Int, _ e: UnsafeBufferPointer<UInt32>) -> UInt32 {
            if let f = filter {
                return spz_outline_rows_filtered(ptr, root, e.baseAddress, UInt32(e.count), f.ptr, out, UInt32(cap))
            }
            return spz_outline_rows(ptr, root, e.baseAddress, UInt32(e.count), out, UInt32(cap))
        }
        let t0 = Perf.now()
        let n = Int(ex.withUnsafeBufferPointer { call(nil, 0, $0) })
        let t1 = Perf.now()
        var rows = [SpzRow](repeating: SpzRow(node: 0, depth: 0), count: n)
        _ = ex.withUnsafeBufferPointer { e in rows.withUnsafeMutableBufferPointer { call($0.baseAddress, n, e) } }
        Perf.log("outline rows=\(n) expanded=\(ex.count) filtered=\(filter != nil) count_call_ms=\(String(format: "%.2f", Double(t1 - t0) / 1e6)) fill_call_ms=\(String(format: "%.2f", Perf.ms(since: t1)))")
        return rows
    }

    func applyFilter(text: String, kind: FileCategory?, minBytes: UInt64?) -> FilterResult {
        var f = SpzFilter(category_mask: kind.map { UInt32(1) << UInt32($0.rawValue) } ?? 0,
                          has_min: minBytes == nil ? 0 : 1, has_max: 0, has_from: 0, has_to: 0,
                          min_size: minBytes ?? 0, max_size: 0, modified_from: 0, modified_to: 0)
        let t0 = Perf.now()
        let h = text.withCString { spz_filter_apply(ptr, $0, nil, f) }
        f.has_min = 0
        Perf.log("filter text='\(text)' kind=\(String(describing: kind)) min=\(String(describing: minBytes)) rust_ms=\(String(format: "%.2f", Perf.ms(since: t0)))")
        return FilterResult(h!)
    }

    func forget(_ id: UInt32) { spz_tree_forget(ptr, id) }

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

    init(_ p: OpaquePointer?, size: CGSize) {
        ptr = p
        self.size = size
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

final class ScanSession: @unchecked Sendable {
    private let handle: OpaquePointer
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
