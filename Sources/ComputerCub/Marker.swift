import AppKit

// "An agent is in here": a glowing outline round the window ComputerCub is working in,
// with the ComputerCub bear peering over its top edge. ComputerCub works on windows in the background, so
// without it Mike can't tell which window not to touch. It follows the window as it
// moves, hides when the window is hidden or on another Space, and fades out a while
// after the last command. Clicking the bear stops agents in that window until one of
// them is told to carry on (`computercub resume`).
final class Marks: NSObject {
    static let shared = Marks()

    // Agents take a while to think between commands, so the mark stays up across the
    // gaps rather than flickering on and off with each one.
    private static let linger: TimeInterval = 15
    // A stop nobody lifts runs out eventually, so a forgotten one can't jam a window.
    private static let stopFor: TimeInterval = 30 * 60
    private static let blue = NSColor(srgbRed: 0.31, green: 0.55, blue: 1, alpha: 1)
    // Room round the window for the glow to spread into.
    private static let pad: CGFloat = 14

    private final class Mark {
        let outline: NSPanel
        let tab: NSPanel
        var last = Date()
        var fading = false
        init(outline: NSPanel, tab: NSPanel) {
            self.outline = outline
            self.tab = tab
        }
    }
    // Main thread only.
    private var marks: [CGWindowID: Mark] = [:]
    private var timer: Timer?
    // Any thread, behind the lock.
    private var stopped: [CGWindowID: Date] = [:]
    private let lock = NSLock()

    // Any thread. Called as a command picks its window; throws if Mike stopped it.
    func use(_ id: CGWindowID, agent: String?) throws {
        guard id != 0 else { return }
        lock.lock()
        let at = stopped[id]
        lock.unlock()
        if let at, Date().timeIntervalSince(at) < Marks.stopFor {
            throw CubError("\(userName) clicked stop on this window, so ComputerCub won't touch it. Ask them before going back in; if they say carry on, run `computercub resume`.")
        }
        DispatchQueue.main.async { self.show(id, agent: agent) }
    }

    // Any thread. Lifts every stop.
    func resume() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = stopped.count
        stopped.removeAll()
        return n
    }

    // Any thread. Takes the mark off, e.g. while the window is handed to Mike.
    func hide(_ id: CGWindowID) {
        DispatchQueue.main.async { self.remove(id) }
    }

    private func show(_ id: CGWindowID, agent: String?) {
        let m = marks[id] ?? make(id)
        marks[id] = m
        m.last = Date()
        m.fading = false
        m.outline.alphaValue = 1
        m.tab.alphaValue = 1
        // The bear is ComputerCub; which agent is driving it goes in the tooltip.
        m.tab.contentView?.toolTip = "\(agent ?? "An agent") is using this window. Click to stop it."
        follow(id, m)
        if timer == nil {
            // Fast enough that the outline keeps up when Mike drags the window about.
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        for (id, m) in marks {
            if !m.fading, Date().timeIntervalSince(m.last) > Marks.linger {
                m.fading = true
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    m.outline.animator().alphaValue = 0
                    m.tab.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    if m.fading { self?.remove(id) }
                })
            }
            follow(id, m)
        }
    }

    private func follow(_ id: CGWindowID, _ m: Mark) {
        // This array holds the window IDs themselves rather than CFNumbers.
        var raw: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
        let ids = CFArrayCreate(nil, &raw, 1, nil)
        let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first
        guard let info else { return remove(id) }  // closed
        let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        guard onscreen,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: b),
              let primary = NSScreen.screens.first else {
            m.outline.orderOut(nil)
            m.tab.orderOut(nil)
            return
        }
        // CoreGraphics measures from the main display's top-left, AppKit from its bottom-left.
        let frame = NSRect(x: cg.minX, y: primary.frame.height - cg.maxY, width: cg.width, height: cg.height)
        let outer = frame.insetBy(dx: -Marks.pad, dy: -Marks.pad)
        if m.outline.frame != outer { m.outline.setFrame(outer, display: true) }

        let size = BearView.size
        // The bear's chin and paws sit on the ring, which runs 3.5 pt outside the window.
        var origin = NSPoint(x: frame.maxX - size.width - 36, y: frame.maxY + 3.5 - BearView.edge)
        // Up against the menu bar there's no room above, so it sits in the title bar.
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? primary
        if origin.y + size.height > screen.visibleFrame.maxY { origin.y = frame.maxY - size.height - 4 }
        let tabFrame = NSRect(origin: origin, size: size)
        if m.tab.frame != tabFrame { m.tab.setFrame(tabFrame, display: true) }

        // Just above the window it marks, not above everything, so windows Mike has in
        // front of it still cover the mark. Clicking the window brings it above the mark,
        // so this runs every tick to put the mark back on top.
        m.outline.order(.above, relativeTo: Int(id))
        m.tab.order(.above, relativeTo: m.outline.windowNumber)
    }

    private func remove(_ id: CGWindowID) {
        guard let m = marks.removeValue(forKey: id) else { return }
        m.outline.orderOut(nil)
        m.tab.orderOut(nil)
        if marks.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    fileprivate func stop(_ tab: NSWindow?) {
        guard let (id, _) = marks.first(where: { $0.value.tab === tab }) else { return }
        lock.lock()
        stopped[id] = Date()
        lock.unlock()
        remove(id)
    }

    private func make(_ id: CGWindowID) -> Mark {
        let outline = Marks.panel()
        outline.ignoresMouseEvents = true
        let glow = NSView()
        glow.wantsLayer = true
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = Marks.blue.cgColor
        ring.lineWidth = 3
        ring.shadowColor = Marks.blue.cgColor
        ring.shadowOpacity = 0.9
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        glow.layer?.addSublayer(ring)
        glow.postsFrameChangedNotifications = true
        // macOS 26 windows have corners of about 24 pt; the ring runs just outside them.
        let reshape = { [weak glow] in
            guard let glow else { return }
            ring.frame = glow.bounds
            let r = glow.bounds.insetBy(dx: Marks.pad - 3.5, dy: Marks.pad - 3.5)
            ring.path = CGPath(roundedRect: r, cornerWidth: 27, cornerHeight: 27, transform: nil)
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: glow, queue: .main) { _ in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            reshape()
            CATransaction.commit()
        }
        outline.contentView = glow

        let tab = Marks.panel()
        tab.contentView = BearView(frame: NSRect(origin: .zero, size: BearView.size))
        return Mark(outline: outline, tab: tab)
    }

    private static func panel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        // It hides itself when the window is on another Space, so it can be on all of them.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        return p
    }
}

// The ComputerCub bear (icons/computercub.svg) peering over the top of the window, paws
// hooked over the edge. Drawn on a 64 × 44 grid, y down, with the edge at y = 34: the
// head is clipped there, so only the part above it shows. Cream outlines keep it
// readable on dark windows and wallpapers.
private final class BearView: NSView {
    static let scale: CGFloat = 1.25
    static let size = NSSize(width: 64 * scale, height: 44 * scale)
    // How far up from the bottom of the view the edge it peers over is.
    static let edge: CGFloat = (44 - 34) * scale

    private static let fur = NSColor(srgbRed: 0x2B / 255.0, green: 0x27 / 255.0, blue: 0x22 / 255.0, alpha: 1)
    private static let cream = NSColor(srgbRed: 0xF4 / 255.0, green: 0xEF / 255.0, blue: 0xE6 / 255.0, alpha: 1)

    override var isFlipped: Bool { true }

    // ComputerCub is never the active app, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { Marks.shared.stop(window) }

    override func draw(_ dirty: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        g.scaleBy(x: Self.scale, y: Self.scale)
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect { CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2) }
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect { CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2) }
        func blob(_ r: CGRect, fill: NSColor, line: Bool) {
            g.setFillColor(fill.cgColor)
            g.fillEllipse(in: r)
            if line {
                g.setStrokeColor(Self.cream.cgColor)
                g.setLineWidth(1.5)
                g.strokeEllipse(in: r)
            }
        }

        g.saveGState()
        g.clip(to: CGRect(x: 0, y: 0, width: 64, height: 34))
        for x: CGFloat in [20, 44] {
            blob(circle(x, 17, 6), fill: Self.fur, line: true)
            blob(circle(x, 17, 2.6), fill: Self.cream, line: false)
        }
        blob(circle(32, 31, 15), fill: Self.fur, line: true)
        // Fur over the inner half of the ears' outlines, so the head reads as one shape.
        blob(circle(32, 31, 14.25), fill: Self.fur, line: false)
        blob(circle(26.5, 27, 2), fill: Self.cream, line: false)
        blob(circle(37.5, 27, 2), fill: Self.cream, line: false)
        blob(oval(32, 35.5, 6.5, 4.8), fill: Self.cream, line: false)
        blob(oval(32, 32.6, 2.3, 1.6), fill: Self.fur, line: false)
        g.restoreGState()

        for x: CGFloat in [17.5, 46.5] { blob(oval(x, 34.5, 6.5, 4.6), fill: Self.fur, line: true) }
        g.setStrokeColor(Self.cream.cgColor)
        g.setLineWidth(1.3)
        g.setLineCap(.round)
        for x: CGFloat in [15.3, 19.7, 44.3, 48.7] {
            g.move(to: CGPoint(x: x, y: 31.6))
            g.addLine(to: CGPoint(x: x, y: 34))
        }
        g.strokePath()
    }
}

// Which agent ran a command, for the tab: the nearest ancestor process we know by name.
// Threadbear runs Claude Code and Codex as children, so they're found above the shell.
enum Agent {
    private static let known = [("claude", "Claude"), ("codex", "Codex"), ("grok", "Grok"), ("muse", "Muse"), ("cursor", "Cursor")]

    static func current() -> String? {
        var pid = getppid()
        for _ in 0..<16 where pid > 1 {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                // Claude Code's binary is named for its version, as in
                // ~/.local/share/claude/versions/2.1.314, so the folders count too.
                for part in String(cString: buf).split(separator: "/").reversed() {
                    let name = part.lowercased()
                    if let hit = known.first(where: { name.hasPrefix($0.0) }) { return hit.1 }
                }
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }
}
