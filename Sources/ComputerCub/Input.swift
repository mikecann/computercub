import AppKit
import ApplicationServices
import ComputerCubCore

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

    // A nil pid posts to the whole system, as a real keyboard would: see toWindow.
    private static func post(_ e: CGEvent, _ pid: pid_t?) {
        if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
    }

    static func key(_ combo: String, pid: pid_t?) throws {
        let (code, flags) = try parse(combo)
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
            throw CubError("Couldn't make a key event. Does ComputerCub have Accessibility?")
        }
        down.flags = flags
        up.flags = flags
        post(down, pid)
        usleep(12_000)
        post(up, pid)
        usleep(30_000)
    }

    static func type(_ text: String, pid: pid_t?) throws {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            if ch == "\n" { try key("return", pid: pid); continue }
            if ch == "\t" { try key("tab", pid: pid); continue }
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(e, pid)
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
    // nothing if they still wouldn't reach it. Returns whether it came forward, which
    // without `front` it only does when the app's already in front.
    //
    // body gets the pid to post keys to. A sheet is often an Open or Save panel run by a
    // separate process (openAndSavePanelService, for every sandboxed app, System Settings
    // included), and keys posted to the app never reach it: cmd+shift+g did nothing. So
    // keys for a sheet go in with the window in front, posted as a real keyboard's (nil).
    // So do all keys once the window's in front: Finder's page for a plugged-in iPhone is
    // drawn by a helper process too, with nothing in Accessibility to give that away.
    @discardableResult
    static func toWindow(_ win: Win, front: Bool, _ body: (pid_t?) throws -> Void) throws -> Bool {
        if (win.el.attr(kAXMinimizedAttribute) as? Bool) == true {
            throw CubError("That window is minimised, so keys would go to another one. Not sending them.")
        }
        // Already aimed (perhaps at a sheet on it): leave focus be, or we'd pull it off the sheet.
        if !aimed(win) {
            focus(win)
            usleep(50_000)
        }
        let sheet = onSheet(win)
        if !front && !sheet && aimed(win) {
            try body(win.pid)
            return false
        }
        // Coming forward takes Mike's focus mid-task, so it's only on the agent's say-so.
        // Unless the app's in front anyway: then there's nothing of his to take.
        if !front && NSWorkspace.shared.frontmostApplication?.processIdentifier != win.pid {
            let why = sheet ? "keys for its sheet only get there with the window in front (its buttons and fields work from the background, so click or type into those instead)"
                : "\(win.appName) sends its keys to another of its windows while it's in the background"
            throw CubError("Not sent: \(why). If it's worth taking \(userName)'s focus, run it again with --front.")
        }
        try inFront(win) {
            // An app that's just come forward can take a moment to settle on a key window.
            if !aimed(win) {
                focus(win)
                usleep(250_000)
            }
            guard aimed(win) else {
                // Some panels (Finder's Go to Folder) take the keys without being in the
                // app's AX window list, so they're invisible to snap; say so.
                let key = AXUIElementCreateApplication(win.pid).element(kAXFocusedWindowAttribute)
                let other = key?.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : "\"\($0)\"" }
                    ?? "a panel or popup that isn't in its window list (Escape usually closes it)"
                throw CubError("\(win.appName)'s keys are going to \(other), not that window. Not sending them.")
            }
            // Posted system-wide, keys go to whatever's in front, so make sure it's us.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid else {
                guard !onSheet(win) else {
                    throw CubError("\(win.appName) wouldn't come to the front, and keys for its sheet only get there from the front. Not sending them.")
                }
                try body(win.pid)
                return
            }
            try body(nil)
        }
        return true
    }

    // True when keys will land in the window or a sheet on it. While a sheet's up (a
    // Save or Open panel, or System Settings' file picker on its Search Privacy sheet)
    // the app's focused window is the sheet, whose parent is the window, or another sheet.
    static func aimed(_ win: Win) -> Bool {
        var key = AXUIElementCreateApplication(win.pid).element(kAXFocusedWindowAttribute)
        for _ in 0..<4 {
            guard let k = key else { return false }
            if CFEqual(k, win.el) { return true }
            guard k.string(kAXRoleAttribute) == kAXSheetRole else { return false }
            key = k.element(kAXParentAttribute)
        }
        return false
    }

    static func onSheet(_ win: Win) -> Bool {
        AXUIElementCreateApplication(win.pid).element(kAXFocusedWindowAttribute)?.string(kAXRoleAttribute) == kAXSheetRole
    }

    // The app's menu item for a shortcut, which can be pressed with the app in the
    // background, unlike the shortcut itself. Skips the Apple menu: its items (Lock
    // Screen, Force Quit) are the Mac's, not the app's.
    static func menuItem(for combo: String, pid: pid_t) throws -> (item: AXUIElement, title: String, enabled: Bool)? {
        let (code, flags) = try parse(combo)
        let key = combo.hasSuffix("++") ? "=" : (combo.lowercased().split(separator: "+").last.map(String.init) ?? "")
        guard let want = MenuShortcut(key: key, keyCode: Int(code), cmd: flags.contains(.maskCommand), shift: flags.contains(.maskShift),
                                      option: flags.contains(.maskAlternate), control: flags.contains(.maskControl)),
              let bar = AXUIElementCreateApplication(pid).element(kAXMenuBarAttribute) else { return nil }
        var queue = Array(bar.elements(kAXChildrenAttribute).dropFirst()), seen = 0
        while !queue.isEmpty, seen < 3000 {
            let el = queue.removeFirst()
            seen += 1
            let v = el.values([kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", kAXChildrenAttribute])
            if want.matches(char: v["AXMenuItemCmdChar"] as? String, modifiers: (v["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue,
                            virtualKey: (v["AXMenuItemCmdVirtualKey"] as? NSNumber)?.intValue) {
                return (el, v[kAXTitleAttribute] as? String ?? combo, (v[kAXEnabledAttribute] as? Bool) != false)
            }
            queue += (v[kAXChildrenAttribute] as? [AXUIElement]) ?? []
        }
        return nil
    }

    // Return and Escape as the focused control's own Confirm and Cancel, or, on a sheet,
    // its default and cancel buttons. Both work in the background, where the keys
    // themselves can't reach a sheet. Nil when neither is there.
    static func confirm(_ combo: String, in win: Win) -> String? {
        let k = combo.lowercased()
        let ok = k == "return" || k == "enter"
        guard ok || k == "escape" || k == "esc" else { return nil }
        let app = AXUIElementCreateApplication(win.pid)
        if let el = app.element(kAXFocusedUIElementAttribute), belongs(el, to: win) {
            let action = ok ? "AXConfirm" : "AXCancel"
            if el.actions.contains(action), el.perform(action) == .success { return action }
        }
        // File pickers run in another process and leave AXCancelButton empty, so for
        // Escape, look for the button by name. Return has nothing as safe to go on.
        if onSheet(win), let sheet = app.element(kAXFocusedWindowAttribute),
           let button = sheet.element(ok ? kAXDefaultButtonAttribute : kAXCancelButtonAttribute) ?? (ok ? nil : cancelButton(in: sheet)),
           (button.attr(kAXEnabledAttribute) as? Bool) != false, button.perform(kAXPressAction) == .success {
            return "the sheet's \(button.string(kAXTitleAttribute).map { "\"\($0)\"" } ?? (ok ? "default" : "cancel")) button"
        }
        return nil
    }

    private static func cancelButton(in sheet: AXUIElement) -> AXUIElement? {
        var queue = sheet.elements(kAXChildrenAttribute), seen = 0
        while !queue.isEmpty, seen < 400 {
            let el = queue.removeFirst()
            seen += 1
            if el.string(kAXRoleAttribute) == kAXButtonRole, el.string(kAXTitleAttribute) == "Cancel" { return el }
            queue += el.elements(kAXChildrenAttribute)
        }
        return nil
    }

    // Whether an element is in the window, or a sheet on it.
    private static func belongs(_ el: AXUIElement, to win: Win) -> Bool {
        var w = el.element(kAXWindowAttribute)
        for _ in 0..<4 {
            guard let k = w else { return false }
            if CFEqual(k, win.el) { return true }
            guard k.string(kAXRoleAttribute) == kAXSheetRole else { return false }
            w = k.element(kAXParentAttribute)
        }
        return false
    }

    // Some keys only work in the active app (Chrome's cmd+w needs a key window, which an
    // app in the background doesn't have). This brings the window forward just for
    // them, then gives Mike back whatever he had in front.
    //
    // While it's borrowed, Mike's own typing would land in that window: a stray letter
    // went into a TextEdit document, and in System Settings a space flips the focused
    // switch. So his keys are held meanwhile and replayed once he has his app back.
    static func inFront<T>(_ win: Win, _ body: () throws -> T) rethrows -> T {
        let previous = NSWorkspace.shared.frontmostApplication
        let hold = KeyHold.start()
        bringForward(win)
        // Usually a third of a second, but a busy Mac took over one for System Settings.
        for i in 0..<15 {
            usleep(100_000)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != win.pid else { break }
            if i == 7 { win.app.activate() }
        }
        usleep(150_000)
        defer {
            usleep(250_000)
            if let previous, previous.processIdentifier != win.pid {
                // AXFrontmost reports success here but macOS often ignores it, leaving
                // the window's app in front. activate() is what actually hands it back.
                AXUIElementCreateApplication(previous.processIdentifier).set(kAXFrontmostAttribute, kCFBooleanTrue)
                previous.activate()
                for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier {
                    usleep(100_000)
                }
            }
            for e in hold?.release() ?? [] { e.post(tap: .cghidEventTap) }
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
            // The bar where there is one. SwiftUI glides to the new spot, so wait for the
            // element to stop before judging, and try again from where it landed.
            if area.element(kAXVerticalScrollBarAttribute) != nil || area.element(kAXHorizontalScrollBarAttribute) != nil {
                for _ in 0..<3 where !inside(el, area) {
                    centre(el, in: area, vertical: true)
                    centre(el, in: area, vertical: false)
                    settle(el)
                }
                continue
            }
            // Page actions only where there's no bar: SwiftUI answers a page down by
            // jumping to the top.
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

    private static func inside(_ el: AXUIElement, _ area: AXUIElement) -> Bool {
        guard let f = el.frame, let a = area.frame else { return false }
        return a.contains(CGPoint(x: f.midX, y: f.midY))
    }

    // Sets the scroll bar so the element sits in the middle of the area. A bar's value runs
    // 0 to 1 over the scrollable distance, the content's length less the visible length.
    // System Settings' SwiftUI lists refuse the page actions but take this.
    private static func centre(_ el: AXUIElement, in area: AXUIElement, vertical: Bool) {
        guard let f = el.frame, let a = area.frame,
              vertical ? (f.midY < a.minY || f.midY > a.maxY) : (f.midX < a.minX || f.midX > a.maxX),
              let bar = area.element(vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
              let now = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue,
              let range = scrollRange(area, vertical: vertical)?.range else { return }
        let off = vertical ? f.midY - a.midY : f.midX - a.midX
        bar.set(kAXValueAttribute, NSNumber(value: min(1, max(0, now + Double(off) / range))))
        usleep(150_000)
    }

    // How much shows and how far there is to scroll, in points. A scroll bar's value
    // covers just the second.
    static func scrollRange(_ area: AXUIElement, vertical: Bool) -> (visible: Double, range: Double)? {
        guard let a = area.frame else { return nil }
        var content = CGSize.zero
        if let v = area.attr("AXContentSize"), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &content)
        } else {
            content = area.elements(kAXChildrenAttribute).compactMap(\.frame).reduce(CGRect.null) { $0.union($1) }.size
        }
        let visible = Double(vertical ? a.height : a.width)
        let range = Double(vertical ? content.height : content.width) - visible
        return range > 0 ? (visible, range) : nil
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

    // A click sent to the window's own process, so Mike's pointer doesn't move and the
    // window stays where it is, behind his. Plain CGEvent.postToPid clicks get dropped
    // (Finder ignored them); what makes AppKit take one is naming the window in fields
    // 91, 92 and 51, giving the point inside it with the private CGEventSetWindowLocation,
    // and posting through SkyLight, as Warp, cua and agent-desktop do. Native hover can't be
    // done this way: tracking areas follow the real cursor, not posted moves.
    static func post(click el: AXUIElement, in win: Win, double: Bool) throws {
        reveal(el, in: win)
        guard let f = el.frame, f.width > 0, f.height > 0, let w = win.el.frame else { throw CubError("Can't tell where that is in its window.") }
        guard shown(el, in: win) else {
            throw CubError("That's scrolled out of view and wouldn't scroll in, so a click would land on something else. Not clicking.")
        }
        let p = CGPoint(x: f.midX, y: f.midY)
        // Other apps' windows on top don't matter, as the click goes straight to this one,
        // but something of its own over the spot (a popover, an overlay) would catch it.
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(win.pid), Float(p.x), Float(p.y), &hit) == .success,
           let hit, hit.pid == win.pid, !lands(on: el, hit: hit) {
            let what = [hit.string(kAXRoleDescriptionAttribute), hit.string(kAXTitleAttribute) ?? hit.string(kAXDescriptionAttribute)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            throw CubError("Something else is at that spot (\(what.isEmpty ? "another element" : what)), so a click would land there. Not clicking.")
        }
        let id = Int64(win.id), local = CGPoint(x: p.x - w.minX, y: p.y - w.minY)
        let src = CGEventSource(stateID: .privateState)
        func send(_ type: CGEventType, _ n: Int64) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: n)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: id)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: id)
            e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(win.pid))
            e.setIntegerValueField(CGEventField(rawValue: 51)!, value: id)
            e.setIntegerValueField(.mouseEventSubtype, value: 3)  // NSEventSubtypeTouch, so it isn't read as a tablet
            e.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseDown ? 1 : 0)
            setWindowLocation?(e, local)
            // SkyLight's own post reaches text views (TextEdit) that CGEvent.postToPid's doesn't.
            if let skyPost { skyPost(win.pid, e) } else { e.postToPid(win.pid) }
        }
        send(.mouseMoved, 0)
        usleep(15_000)
        for n in 1...(double ? 2 : 1) {
            send(.leftMouseDown, Int64(n))
            usleep(10_000)
            send(.leftMouseUp, Int64(n))
            usleep(30_000)
        }
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    // Private, so looked up at run time: a macOS that drops them makes clicks miss rather
    // than ComputerCub fail to start.
    private static let skyLight: Void = { dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY); return () }()
    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        _ = skyLight
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }
    private static let setWindowLocation = symbol("CGEventSetWindowLocation", as: SetWindowLocation.self)
    private static let skyPost = symbol("SLEventPostToPid", as: PostToPid.self)

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

// Holds the keyboard's events for a moment, so Mike's typing doesn't land in a window
// ComputerCub has borrowed. Only events from elsewhere are held (his keyboard, his
// dictation app); ComputerCub's own keys pass. The tap gives up after 5 s whatever
// happens, and if macOS disables it, keys just flow as normal.
final class KeyHold {
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var held: [CGEvent] = []
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)

    static func start() -> KeyHold? {
        let h = KeyHold()
        Thread { h.run() }.start()
        h.ready.wait()
        return h.tap == nil ? nil : h
    }

    private func run() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, e, refcon in
                                    Unmanaged<KeyHold>.fromOpaque(refcon!).takeUnretainedValue().handle(type, e)
                                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { ready.signal(); return }
        loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()
        CFRunLoopRunInMode(.defaultMode, 5, false)
        stopTap()
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged,
              e.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
              let copy = e.copy() else { return Unmanaged.passUnretained(e) }
        lock.lock()
        held.append(copy)
        lock.unlock()
        return nil
    }

    private func stopTap() {
        lock.lock()
        defer { lock.unlock() }
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
    }

    // Lets the keyboard go and hands back what was typed meanwhile, to post again.
    func release() -> [CGEvent] {
        stopTap()
        if let loop { CFRunLoopStop(loop) }
        lock.lock()
        defer { lock.unlock() }
        let out = held
        held = []
        return out
    }
}
