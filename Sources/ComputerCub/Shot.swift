import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/ComputerCub")
    static let socket = support.appendingPathComponent("computercub.sock").path
    static let cache = home.appendingPathComponent("Library/Caches/ComputerCub")
    static let shots = cache.appendingPathComponent("shots")
    static let reads = cache.appendingPathComponent("reads")
}

// Window-only screenshots. Never the whole screen: ScreenCaptureKit's single-window
// filter captures just that window, even when it's behind others.
enum Shot {
    static func capture(_ win: Win, crop: CGRect?, maxSide: Int) throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CubError("ComputerCub needs Screen Recording for screenshots: System Settings › Privacy & Security › Screen & System Audio Recording, turn on ComputerCub. Everything else works without it.")
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
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == id }) else {
                    throw CubError("ScreenCaptureKit can't see that window (minimised?).")
                }
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                var size = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
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
            let s = CGFloat(image.width) / wf.width
            let r = CGRect(x: (crop.minX - wf.minX) * s, y: (crop.minY - wf.minY) * s, width: crop.width * s, height: crop.height * s).integral
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
        return "\(url.path) (\(image.width)×\(image.height))"
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
