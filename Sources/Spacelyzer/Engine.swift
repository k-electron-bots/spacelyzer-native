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

final class Tree: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ p: OpaquePointer) { ptr = p }
    deinit { spz_tree_free(ptr) }

    var wasCancelled: Bool { spz_tree_cancelled(ptr) != 0 }

    func info(_ id: UInt32) -> NodeInfo {
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

    func name(_ id: UInt32) -> String { take(spz_tree_name(ptr, id)) }
    func path(_ id: UInt32) -> String { take(spz_tree_path(ptr, id)) }
    func find(path: String) -> UInt32? {
        let id = spz_tree_find(ptr, path)
        return id == noNode ? nil : id
    }
    /// Visible outline rows (node, depth), flattened in Rust from the expanded set. No cap.
    func outlineRows(root: UInt32, expanded: Set<UInt32>) -> [SpzRow] {
        let ex = Array(expanded)
        let n = Int(ex.withUnsafeBufferPointer { spz_outline_rows(ptr, root, $0.baseAddress, UInt32($0.count), nil, 0) })
        var rows = [SpzRow](repeating: SpzRow(node: 0, depth: 0), count: n)
        _ = ex.withUnsafeBufferPointer { e in
            rows.withUnsafeMutableBufferPointer { spz_outline_rows(ptr, root, e.baseAddress, UInt32(e.count), $0.baseAddress, UInt32(n)) }
        }
        return rows
    }

    func forget(_ id: UInt32) { spz_tree_forget(ptr, id) }

    func children(_ id: UInt32) -> Range<UInt32> {
        let n = info(id)
        guard n.childCount > 0 else { return 0..<0 }
        return n.firstChild..<(n.firstChild + UInt32(n.childCount))
    }

    func categoryTotals() -> [(category: FileCategory, bytes: UInt64, items: UInt64)] {
        var out = [UInt64](repeating: 0, count: 22)
        out.withUnsafeMutableBufferPointer { spz_tree_category_totals(ptr, $0.baseAddress) }
        return FileCategory.allCases.map { (category: $0, bytes: out[$0.rawValue * 2], items: out[$0.rawValue * 2 + 1]) }
    }

    func largestFiles(_ n: Int) -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: n)
        let c = ids.withUnsafeMutableBufferPointer { spz_tree_largest_files(ptr, UInt32(n), $0.baseAddress) }
        return Array(ids.prefix(Int(c)))
    }

    var skipped: [(path: String, reason: Int)] {
        (0..<spz_tree_skipped_count(ptr)).map { (take(spz_tree_skipped_path(ptr, $0)), Int(spz_tree_skipped_reason(ptr, $0))) }
    }

    func layout(root: UInt32, size: CGSize) -> TreemapLayout {
        TreemapLayout(spz_layout_new(ptr, root, Float(size.width), Float(size.height)), size: size)
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
