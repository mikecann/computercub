import AppKit
import ApplicationServices

// Keys and the mouse. Keys go straight to the app's process (CGEvent.postToPid), so they
// land in that app even when Mike is typing somewhere else. The mouse can't do that: a
// real click lands on whatever is on top, so it's the last resort.
enum Input {
    // US layout virtual key codes.
    static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    static func parse(_ combo: String) throws -> (CGKeyCode, CGEventFlags) {
        var parts = combo.lowercased().split(separator: "+").map(String.init)
        if combo.hasSuffix("++") { parts.append("=") }  // cmd++ means cmd and the + key
        guard let key = parts.popLast(), let code = codes[key] else {
            throw CubError("Don't know the key in \"\(combo)\". Try things like cmd+shift+g, return, escape, tab, down, f5.")
        }
        var flags: CGEventFlags = []
        for m in parts {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw CubError("Don't know the modifier \"\(m)\" in \"\(combo)\".")
            }
        }
        return (code, flags)
    }

    static func key(_ combo: String, pid: pid_t) throws {
        let (code, flags) = try parse(combo)
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
            throw CubError("Couldn't make a key event. Does ComputerCub have Accessibility?")
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        usleep(12_000)
        up.postToPid(pid)
        usleep(30_000)
    }

    static func type(_ text: String, pid: pid_t) throws {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            if ch == "\n" { try key("return", pid: pid); continue }
            if ch == "\t" { try key("tab", pid: pid); continue }
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e.postToPid(pid)
            }
            usleep(6_000)
        }
    }

    // Keys and menu items go to the app's key window, which isn't always the one we mean:
    // Chrome's is often a tiny invisible helper. This points the app at our window
    // without bringing the app in front of whatever Mike is doing.
    static func focus(_ win: Win) {
        win.el.set(kAXMainAttribute, kCFBooleanTrue)
        win.el.set(kAXFocusedAttribute, kCFBooleanTrue)
        AXUIElementCreateApplication(win.pid).set(kAXFocusedWindowAttribute, win.el)
    }

    // Keys sent to an app go to its key window, whatever we asked for. Pointing it at ours
    // from the background usually works, but not when ours is minimised or the key window
    // sits on another Space: then cmd+w closed Mike's Downloads window instead. So check
    // where keys will land, bring the window forward if that's what it takes, and send
    // nothing if they still wouldn't reach it. Returns whether it had to come forward.
    @discardableResult
    static func toWindow(_ win: Win, front: Bool, _ body: () throws -> Void) throws -> Bool {
        if (win.el.attr(kAXMinimizedAttribute) as? Bool) == true {
            throw CubError("That window is minimised, so keys would go to another one. Not sending them.")
        }
        focus(win)
        usleep(50_000)
        if !front && aimed(win) {
            try body()
            return false
        }
        try inFront(win) {
            guard aimed(win) else {
                throw CubError("\(win.appName) won't point keys at that window, so they'd land in another one. Not sending them.")
            }
            try body()
        }
        return !front
    }

    static func aimed(_ win: Win) -> Bool {
        guard let key = AXUIElementCreateApplication(win.pid).element(kAXFocusedWindowAttribute) else { return false }
        return CFEqual(key, win.el)
    }

    // Some keys only work in the active app (Chrome's cmd+w needs a key window, which an
    // app in the background doesn't have). This brings the window forward just for
    // them, then gives Mike back whatever he had in front.
    static func inFront<T>(_ win: Win, _ body: () throws -> T) rethrows -> T {
        let previous = NSWorkspace.shared.frontmostApplication
        bringForward(win)
        usleep(350_000)
        defer {
            usleep(250_000)
            if let previous, previous.processIdentifier != win.pid {
                AXUIElementCreateApplication(previous.processIdentifier).set(kAXFrontmostAttribute, kCFBooleanTrue)
            }
        }
        return try body()
    }

    static func bringForward(_ win: Win) {
        // Setting AXFrontmost through AX works from a background app, where
        // NSRunningApplication.activate is often refused since macOS 14.
        AXUIElementCreateApplication(win.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
        win.el.set(kAXMainAttribute, kCFBooleanTrue)
        win.el.perform(kAXRaiseAction)
    }

    // The app whose window is on top at a point on screen.
    static func owner(at p: CGPoint) -> pid_t? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
              let hit else { return nil }
        return hit.pid
    }

    static func drag(from a: CGPoint, to b: CGPoint) {
        let saved = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
            if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
            e.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, a)
        usleep(80_000)
        post(.leftMouseDown, a)
        usleep(150_000)
        // Lots of small steps: Finder and friends only start a drag once the
        // pointer has moved a little with the button held, and a jump looks like a click.
        let steps = 30
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(16_000)
        }
        usleep(200_000)
        post(.leftMouseUp, b)
        if let saved {
            usleep(100_000)
            CGWarpMouseCursorPosition(saved)
        }
    }

    // An element scrolled out of its list still reports a frame, just one off past the
    // edge of the window (or of every display). A click there lands on whatever is on
    // screen instead: System Settings' sidebar, say. So scroll it in first.
    static func reveal(_ el: AXUIElement, in win: Win) {
        if shown(el, in: win) { return }
        defer { settle(el) }
        // Exact where offered, but SwiftUI (System Settings) says unsupported.
        if el.perform("AXScrollToVisible") == .success {
            settle(el)
            if shown(el, in: win) { return }
        }
        // Otherwise move each scroll area it's in, innermost first, until it's inside.
        for area in scrollAreas(around: el) {
            centre(el, in: area, vertical: true)
            centre(el, in: area, vertical: false)
            for _ in 0..<40 {
                guard let f = el.frame, let a = area.frame else { break }
                let action: String
                if f.midY > a.maxY { action = "AXScrollDownByPage" }
                else if f.midY < a.minY { action = "AXScrollUpByPage" }
                else if f.midX > a.maxX { action = "AXScrollRightByPage" }
                else if f.midX < a.minX { action = "AXScrollLeftByPage" }
                else { break }
                guard area.perform(action) == .success else { break }
                usleep(120_000)
                if el.frame == f { break }  // Didn't move, so it won't.
            }
        }
    }

    // Sets the scroll bar so the element sits in the middle of the area. A bar's value runs
    // 0 to 1 over the scrollable distance, the content's length less the visible length.
    // System Settings' SwiftUI lists refuse the page actions but take this.
    private static func centre(_ el: AXUIElement, in area: AXUIElement, vertical: Bool) {
        guard let f = el.frame, let a = area.frame,
              vertical ? (f.midY < a.minY || f.midY > a.maxY) : (f.midX < a.minX || f.midX > a.maxX),
              let bar = area.element(vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
              let now = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue else { return }
        var content = CGSize.zero
        if let v = area.attr("AXContentSize"), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &content)
        } else {
            content = area.elements(kAXChildrenAttribute).compactMap(\.frame).reduce(CGRect.null) { $0.union($1) }.size
        }
        let range = vertical ? content.height - a.height : content.width - a.width
        guard range > 0 else { return }
        let off = vertical ? f.midY - a.midY : f.midX - a.midX
        bar.set(kAXValueAttribute, NSNumber(value: min(1, max(0, now + Double(off / range)))))
        usleep(150_000)
    }

    // Lists animate when scrolled. Some (SwiftUI) report frames mid-glide; others
    // (Finder) report the end straight away but swallow a click until the glide's done.
    private static func settle(_ el: AXUIElement) {
        defer { usleep(350_000) }
        var last = el.frame
        for _ in 0..<10 {
            usleep(100_000)
            let now = el.frame
            if now == last { return }
            last = now
        }
    }

    private static func scrollAreas(around el: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = [], n = el.element(kAXParentAttribute)
        while let p = n, out.count < 10 {
            let role = p.string(kAXRoleAttribute)
            if role == "AXWindow" { break }
            if role == "AXScrollArea" { out.append(p) }
            n = p.element(kAXParentAttribute)
        }
        return out
    }

    // Whether the element's middle is inside its window, every scroll area it's in, and
    // a display. AX frames and CGDisplayBounds share one top-left space across displays.
    static func shown(_ el: AXUIElement, in win: Win) -> Bool {
        guard let f = el.frame, f.width > 0, f.height > 0 else { return false }
        let p = CGPoint(x: f.midX, y: f.midY)
        if let w = win.el.frame, !w.contains(p) { return false }
        for a in scrollAreas(around: el) {
            if let r = a.frame, !r.contains(p) { return false }
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).contains { CGDisplayBounds($0).contains(p) }
    }

    // True when what's on top at a point is the element, something inside it, or one of
    // its containers (some controls don't hit-test themselves, so their group answers).
    // Same app isn't enough: a stale frame once clicked System Settings' own sidebar.
    static func lands(on el: AXUIElement, hit: AXUIElement) -> Bool {
        func chain(_ start: AXUIElement) -> [AXUIElement] {
            var out: [AXUIElement] = [], n: AXUIElement? = start
            while let x = n, out.count < 30, x.string(kAXRoleAttribute) != "AXWindow" {
                out.append(x)
                n = x.element(kAXParentAttribute)
            }
            return out
        }
        return chain(hit).contains { CFEqual($0, el) } || chain(el).contains { CFEqual($0, hit) }
    }

    static func click(_ el: AXUIElement, in win: Win, double: Bool) throws {
        bringForward(win)
        usleep(300_000)
        reveal(el, in: win)
        // Read the frame now, not before: raising and scrolling both move things.
        guard let f = el.frame, f.width > 0, f.height > 0 else { throw CubError("Can't tell where that is on screen.") }
        guard shown(el, in: win) else {
            throw CubError("That's scrolled out of view and wouldn't scroll in, so a click would land on something else. Not clicking.")
        }
        let p = CGPoint(x: f.midX, y: f.midY)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
           let hit, !lands(on: el, hit: hit) {
            if hit.pid != win.pid {
                let other = NSRunningApplication(processIdentifier: hit.pid)?.localizedName ?? "another app"
                throw CubError("\(other) is on top of that spot, so a click would land there. Not clicking.")
            }
            let what = [hit.string(kAXRoleDescriptionAttribute), hit.string(kAXTitleAttribute) ?? hit.string(kAXDescriptionAttribute)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            throw CubError("Something else is at that spot (\(what.isEmpty ? "another element" : what)), so a click would land there. Not clicking.")
        }
        let saved = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        for n in 1...(double ? 2 : 1) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.post(tap: .cghidEventTap)
                usleep(20_000)
            }
        }
        // Put the pointer back where Mike left it.
        if let saved {
            usleep(60_000)
            CGWarpMouseCursorPosition(saved)
        }
    }
}
