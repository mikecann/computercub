import AppKit

// The first name of whoever is signed in to the Mac: "Over to you, Mike".
let userName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "you"

// "Over to you": a small floating panel on the window that needs Mike (a sign-in, a
// passkey, a 2FA code, anything that's his), with a Done button. The agent can wait on
// it, then carries on with a diff of what changed while he was in there.
final class Handoffs: NSObject {
    static let shared = Handoffs()

    private final class Entry {
        var panel: NSPanel?
        var finished = false
    }
    private var entries: [CGWindowID: Entry] = [:]
    private let lock = NSLock()

    // Main thread only.
    func show(window id: CGWindowID, message: String, near frame: CGRect?) {
        lock.lock()
        if let e = entries[id], !e.finished, let panel = e.panel {
            lock.unlock()
            panel.orderFrontRegardless()
            return
        }
        lock.unlock()

        let title = NSTextField(labelWithString: "Over to you, \(userName)")
        title.font = .boldSystemFont(ofSize: 15)
        let body = NSTextField(wrappingLabelWithString: message)
        body.preferredMaxLayoutWidth = 300
        let button = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        button.tag = Int(id)
        let stack = NSStackView(views: [title, body, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        let size = stack.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Mr Clicky"
        panel.contentView = stack
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Bottom right of the window, where it's least likely to cover a sign-in form.
        if let frame, let primary = NSScreen.screens.first {
            let outer = panel.frame.size
            let x = frame.maxX - outer.width - 24
            let y = primary.frame.height - frame.maxY + 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()

        let e = Entry()
        e.panel = panel
        lock.lock()
        entries[id] = e
        lock.unlock()
    }

    @objc private func done(_ sender: NSButton) {
        let id = CGWindowID(sender.tag)
        lock.lock()
        let e = entries[id]
        e?.finished = true
        lock.unlock()
        e?.panel?.close()
    }

    // Any thread but main. True once Mike clicks Done.
    func wait(window id: CGWindowID, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock()
            let finished = entries[id]?.finished ?? true
            lock.unlock()
            if finished { return true }
            usleep(250_000)
        }
        return false
    }
}
