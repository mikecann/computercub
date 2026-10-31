import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    // COMPUTERCUB_HOME lets a dev build serve beside the installed app, with its own socket
    // and saved refs, so testing a change doesn't stop ComputerCub for every other agent.
    static let support = ProcessInfo.processInfo.environment["COMPUTERCUB_HOME"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent("Library/Application Support/ComputerCub")
    static let isDev = ProcessInfo.processInfo.environment["COMPUTERCUB_HOME"] != nil
    static let socket = support.appendingPathComponent("computercub.sock").path
    static let cache = home.appendingPathComponent("Library/Caches/ComputerCub")
    static let shots = cache.appendingPathComponent("shots")
    static let reads = cache.appendingPathComponent("reads")
}

// Window-only screenshots. Never the whole screen: ScreenCaptureKit's single-window
// filter captures just that window, even when it's behind others.
enum Shot {
    // overlays: the window's open menus and popovers (Desktop.overlays), which are windows
    // of their own and so would be left out of a single-window capture.
    static func capture(_ win: Win, crop: CGRect?, maxSide: Int, overlays: [(id: CGWindowID, frame: CGRect, layer: Int)] = []) throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CubError("ComputerCub needs Screen Recording for screenshots: System Settings › Privacy & Security › Screen & System Audio Recording, turn on ComputerCub. Everything else works without it.", restart: true)
        }
        guard win.id != 0 else { throw CubError("Can't find that window's id, so can't capture it.") }

        final class Box: @unchecked Sendable {
            var image: CGImage?
            var error: Error?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let id = win.id
        let shrink = crop == nil
        let extra = Set(overlays.map(\.id))
        // Where the picture's top-left is on screen, for cropping to an element.
        var origin = win.el.frame?.origin ?? .zero
        let area = overlays.reduce(win.el.frame ?? .null) { $0.union($1.frame) }
        if !overlays.isEmpty { origin = area.origin }
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == id }) else {
                    throw CubError("ScreenCaptureKit can't see that window (minimised?).")
                }
                let filter: SCContentFilter
                let cfg = SCStreamConfiguration()
                let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) })
                if !extra.isEmpty, let display {
                    // Just these windows, composited as they are on screen, nothing else's.
                    let these = content.windows.filter { $0.windowID == id || extra.contains($0.windowID) }
                    filter = SCContentFilter(display: display, including: these)
                    cfg.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    cfg.ignoreShadowsDisplay = true
                } else {
                    filter = SCContentFilter(desktopIndependentWindow: w)
                }
                let scale = CGFloat(filter.pointPixelScale)
                let rect = extra.isEmpty || display == nil ? filter.contentRect : area
                var size = CGSize(width: rect.width * scale, height: rect.height * scale)
                let long = max(size.width, size.height)
                // Big captures cost tokens for nothing; 1600 px is plenty to read a window.
                if shrink, long > CGFloat(maxSide) {
                    size = CGSize(width: size.width * CGFloat(maxSide) / long, height: size.height * CGFloat(maxSide) / long)
                }
                cfg.width = Int(size.width)
                cfg.height = Int(size.height)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                box.image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            } catch {
                box.error = error
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 15) == .timedOut { throw CubError("The screenshot timed out.") }
        if let e = box.error { throw e }
        guard var image = box.image else { throw CubError("The screenshot came back empty.") }

        if let crop, let wf = win.el.frame, wf.width > 0 {
            let s = CGFloat(image.width) / (overlays.isEmpty ? wf.width : area.width)
            let r = CGRect(x: (crop.minX - origin.x) * s, y: (crop.minY - origin.y) * s, width: crop.width * s, height: crop.height * s).integral
            if let c = image.cropping(to: r) { image = c }
        }

        sweep()
        try FileManager.default.createDirectory(at: Paths.shots, withIntermediateDirectories: true)
        let url = Paths.shots.appendingPathComponent("\(safeName(win.appName))-\(stamp()).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CubError("Couldn't write \(url.path).")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CubError("Couldn't write \(url.path).") }
        let open = overlays.contains { $0.layer >= 101 } ? "an open menu" : "what's open over it"
        return "\(url.path) (\(image.width)×\(image.height))" + (overlays.isEmpty ? "" : ", with \(open)")
    }

    // Screenshots and long reads can hold anything that was on screen, so they don't
    // hang around: an hour, or `computercub clean` for right now.
    static func sweep(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        for dir in [Paths.shots, Paths.reads] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                if Date().timeIntervalSince(modified) >= age { try? fm.removeItem(at: url) }
            }
        }
    }

    static func safeName(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss-SSS"
        return f.string(from: Date())
    }
}
