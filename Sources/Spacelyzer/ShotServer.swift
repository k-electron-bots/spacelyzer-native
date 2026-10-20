#if SPZ_CI_TESTS   // test/development builds only: never compiled into the shipped app
import AppKit

/// Experimental render-derived 2x window capture (env SPZ_SHOT_DIR). An external script writes `<name>.req` into the
/// directory; the app draws the main window's content view into a bitmap with twice the pixels per point
/// (NSView.cacheDisplay) and writes `<name>.png` plus `<name>.txt` describing exactly how it was produced.
/// This is a re-render of the live view, NOT a native Retina display capture, and it can omit or alter layers that a
/// real screen capture would show (title bar, shadow, some layer-backed content). Every image must be inspected against
/// the real 1x capture before any docs use. It never changes app state.
@MainActor enum ShotServer {
    static func start(dir: String) {
        Task { @MainActor in
            let fm = FileManager.default
            while true {
                if let names = try? fm.contentsOfDirectory(atPath: dir) {
                    for f in names where f.hasSuffix(".req") {
                        let name = String(f.dropLast(4))
                        try? fm.removeItem(atPath: dir + "/" + f)
                        render(name: name, dir: dir)
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private static func render(name: String, dir: String) {
        let note = dir + "/" + name + ".txt", png = dir + "/" + name + ".png"
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else {
            try? "FAILED: no visible window with a content view\n".write(toFile: note, atomically: true, encoding: .utf8); return
        }
        let scale = 2, size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            try? "FAILED: could not allocate bitmap\n".write(toFile: note, atomically: true, encoding: .utf8); return
        }
        rep.size = size   // fewer points than pixels: the view is drawn at 2 pixels per point
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            try? "FAILED: PNG encoding\n".write(toFile: note, atomically: true, encoding: .utf8); return
        }
        let text = "render-derived 2x via NSView.cacheDisplay of the window content view, from the TEST-ONLY build (SPZ_CI_TESTS), not the shipped app; no title bar, no shadow; not a native Retina capture\n"
            + "view_points=\(Int(size.width))x\(Int(size.height)) bitmap_pixels=\(rep.pixelsWide)x\(rep.pixelsHigh) window_backing_scale=\(window.backingScaleFactor) appearance=\(view.effectiveAppearance.name.rawValue)\n"
        // Note first, then the PNG atomically (temp file, then rename), so a waiter that sees the PNG always sees a complete file and its note.
        try? text.write(toFile: note, atomically: true, encoding: .utf8)
        try? data.write(to: URL(fileURLWithPath: png + ".tmp"))
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: png), withItemAt: URL(fileURLWithPath: png + ".tmp"))
    }
}
#endif
