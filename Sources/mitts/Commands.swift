import AppKit
import ApplicationServices

struct Reply {
    var ok: Bool
    var out: String
}

struct Args {
    var pos: [String] = []
    var flags: [String: String] = [:]
    static let valued: Set<String> = ["wait", "max"]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let s = argv[i]
            if s.hasPrefix("--") {
                let k = String(s.dropFirst(2))
                if Args.valued.contains(k), i + 1 < argv.count {
                    flags[k] = argv[i + 1]
                    i += 2
                    continue
                }
                flags[k] = ""
            } else {
                pos.append(s)
            }
            i += 1
        }
    }

    func has(_ k: String) -> Bool { flags[k] != nil }

    func at(_ i: Int, _ what: String) throws -> String {
        guard i < pos.count else { throw MittsError("Missing \(what). See `mitts help`.") }
        return pos[i]
    }
}

let helpText = """
mitts: lets agents use the Mac's apps through the Accessibility API.

  mitts apps                            running apps
  mitts windows [app]                   windows, with refs (w3), size and display
  mitts snap <window> [--full] [--all]  what you can click or type in, with refs (e12);
                                        after the first look, only what changed
  mitts read <window|ref>               the words in a window or element
  mitts click <ref> [--mouse] [--double]
  mitts type <ref> <text> [--submit] [--keys]
                                        replaces the field's text; passwords are refused
  mitts press <window|ref> <keys>... [--front]
                                        e.g. cmd+shift+g, return, escape, tab, down. Keys go
                                        to the app in the background; if nothing happens,
                                        --front brings the window forward just for them
  mitts menu <app> [File > New Window]  list an app's menus, or pick an item
  mitts scroll <ref|window> [up|down]   bring an element into view, or page a scroll area
  mitts shot <window|ref> [--max 1600]  window-only PNG; prints the path, deleted after an hour
  mitts handoff <window> <message> [--wait 300]
                                        brings the window up with an "Over to you" panel, for
                                        sign-ins, passkeys and anything else that's Mike's
  mitts doctor                          permissions and displays
  mitts clean                           delete screenshots and saved reads now
  mitts quit                            stop the background app

A window is w3, an app ("Finder"), an app and part of its title ("Chrome:Web Store"),
or "front". Clicks, typing and keys answer with what changed, so there's no need to
snap again after each one.
"""

final class Commands {
    static let shared = Commands()
    let desk = Desktop.shared
    private let work = DispatchQueue(label: "mitts.work")

    func run(_ argv: [String]) -> Reply {
        guard let cmd = argv.first else { return Reply(ok: true, out: helpText) }
        let a = Args(Array(argv.dropFirst()))
        do {
            switch cmd {
            case "help", "-h", "--help": return Reply(ok: true, out: helpText)
            // Waits for Mike outside the work queue, so other commands still run meanwhile.
            case "handoff": return Reply(ok: true, out: try handoff(a))
            case "quit":
                // Hand Chrome back its normal accessibility mode before going.
                work.sync { desk.relaxWeb(idleFor: 0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return Reply(ok: true, out: "Mitts stopped.")
            default:
                return Reply(ok: true, out: try work.sync { try dispatch(cmd, a) })
            }
        } catch {
            return Reply(ok: false, out: "\(error)")
        }
    }

    // Called from the service's timer.
    func tick() {
        work.async { self.desk.relaxWeb(idleFor: 120) }
    }

    private func dispatch(_ cmd: String, _ a: Args) throws -> String {
        if cmd == "doctor" { return doctor() }
        if cmd == "clean" {
            Shot.sweep(olderThan: 0)
            return "Deleted Mitts' screenshots and saved reads."
        }
        guard AXIsProcessTrusted() else {
            throw MittsError("Mitts doesn't have Accessibility yet. System Settings › Privacy & Security › Accessibility, turn on Mitts, then try again.")
        }
        switch cmd {
        case "apps": return apps()
        case "windows": return try windows(a.pos.first)
        case "snap": return try snap(try a.at(0, "a window"), full: a.has("full"), all: a.has("all"))
        case "read": return try read(try a.at(0, "a window or ref"))
        case "click": return try click(try a.at(0, "a ref"), mouse: a.has("mouse"), double: a.has("double"))
        case "type": return try type(try a.at(0, "a ref"), try a.at(1, "the text"), submit: a.has("submit"), keys: a.has("keys"))
        case "press": return try press(try a.at(0, "a window or ref"), Array(a.pos.dropFirst()), front: a.has("front"))
        case "menu": return try menu(try a.at(0, "an app"), a.pos.count > 1 ? a.pos[1] : nil)
        case "scroll": return try scroll(try a.at(0, "a ref or window"), a.pos.count > 1 ? a.pos[1] : nil)
        case "shot": return try shot(try a.at(0, "a window or ref"), max: Int(a.flags["max"] ?? "") ?? 1600)
        default: throw MittsError("No command \"\(cmd)\". See `mitts help`.")
        }
    }

    // MARK: Looking

    private func doctor() -> String {
        var out = [
            "Accessibility: " + (AXIsProcessTrusted() ? "on" : "off. System Settings › Privacy & Security › Accessibility, turn on Mitts"),
            "Screen Recording: " + (CGPreflightScreenCaptureAccess() ? "on" : "off, only needed for `mitts shot`. System Settings › Privacy & Security › Screen & System Audio Recording, turn on Mitts"),
            "Running from: \(Bundle.main.bundlePath) (pid \(getpid()))",
            "Displays:",
        ]
        for (i, s) in NSScreen.screens.enumerated() {
            let f = s.frame
            out.append("  \(s.localizedName) \(Int(f.width))×\(Int(f.height)) @\(Int(s.backingScaleFactor))x\(i == 0 ? " (main)" : "")")
        }
        return out.joined(separator: "\n")
    }

    private func apps() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return desk.apps().map { app in
            var s = app.localizedName ?? "pid \(app.processIdentifier)"
            if app.processIdentifier == front { s += " [frontmost]" }
            if app.isHidden { s += " [hidden]" }
            let n = desk.windows(of: app).count
            return s + (n == 1 ? ", 1 window" : ", \(n) windows")
        }.joined(separator: "\n")
    }

    private func windows(_ query: String?) throws -> String {
        let list = try query.map { [try desk.findApp($0)] } ?? desk.apps()
        var out: [String] = []
        for app in list {
            let wins = desk.windows(of: app)
            if wins.isEmpty && query == nil { continue }
            out.append(app.localizedName ?? "pid \(app.processIdentifier)")
            let focused = AXUIElementCreateApplication(app.processIdentifier).element(kAXFocusedWindowAttribute)
            for w in wins { out.append("  " + desk.describe(w, focused: focused)) }
            if wins.isEmpty { out.append("  (no windows on this Space)") }
        }
        return out.joined(separator: "\n")
    }

    private func snap(_ target: String, full: Bool, all: Bool) throws -> String {
        let win = try desk.window(target)
        let lines = Snapshot.lines(win, desk, all: all)
        let before = desk.lastLines[win.id]
        desk.lastLines[win.id] = lines
        let d = Snapshot.diff(full ? nil : before, lines)
        return desk.header(win) + (d.full ? "" : " (changes since the last look)") + "\n" + d.text
    }

    private func read(_ target: String) throws -> String {
        let root: AXUIElement, win: Win
        if target.range(of: #"^e\d+$"#, options: .regularExpression) != nil {
            (root, win) = try desk.lookup(target)
        } else {
            win = try desk.window(target)
            root = win.el
            _ = desk.ensureWeb(win.app)
        }
        var out: [String] = []
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 12000, depth < 120 else { return }
            let v = el.values([kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
            let role = v[kAXRoleAttribute] as? String ?? ""
            var text: String?
            switch role {
            case "AXStaticText": text = v[kAXValueAttribute] as? String
            case "AXHeading":
                if let t = (v[kAXTitleAttribute] as? String) ?? (v[kAXDescriptionAttribute] as? String), !t.isEmpty {
                    out.append("## \(t)")
                    return
                }
            case "AXTextField", "AXTextArea":
                if (v[kAXSubroleAttribute] as? String) != "AXSecureTextField" { text = v[kAXValueAttribute] as? String }
            case "AXSecureTextField", "AXColumn", "AXScrollBar": return
            default: break
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, out.last != t { out.append(t) }
            for k in v[kAXChildrenAttribute] as? [AXUIElement] ?? [] { walk(k, depth + 1) }
        }
        walk(root, 0)
        let text = out.joined(separator: "\n")
        let header = desk.header(win)
        // Long pages go to a file, so the agent can grep them instead of reading it all.
        if text.count > 6000 {
            Shot.sweep()
            try FileManager.default.createDirectory(at: Paths.reads, withIntermediateDirectories: true)
            let url = Paths.reads.appendingPathComponent("\(Shot.safeName(win.appName))-\(Shot.stamp()).txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "\(header)\n\(text.prefix(1500))\n… \(text.count) characters in all, saved to \(url.path) (deleted after an hour)"
        }
        return "\(header)\n\(text)"
    }

    // MARK: Doing

    // Runs an action, waits for the window to settle, and answers with what changed,
    // plus any new windows the app opened (a Save sheet, a Go to Folder box).
    private func acting(_ win: Win, _ body: () throws -> String) throws -> String {
        let before = Set(desk.windows(of: win.app).map(\.id))
        if desk.lastLines[win.id] == nil { desk.lastLines[win.id] = Snapshot.lines(win, desk) }
        var out = [try body()]
        usleep(250_000)
        if win.el.isAlive {
            var lines = Snapshot.lines(win, desk)
            for _ in 0..<3 {
                usleep(250_000)
                guard win.el.isAlive else { break }
                let again = Snapshot.lines(win, desk)
                if again == lines { break }
                lines = again
            }
            let d = Snapshot.diff(desk.lastLines[win.id], lines)
            desk.lastLines[win.id] = lines
            out.append(desk.header(win) + (d.full ? "" : " (changes)") + "\n" + d.text)
        } else {
            out.append("\(desk.ref(for: win)) closed.")
        }
        for w in desk.windows(of: win.app) where w.id != 0 && !before.contains(w.id) {
            let lines = Snapshot.lines(w, desk)
            desk.lastLines[w.id] = lines
            out.append("New window: \(desk.header(w))\n" + lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    private func click(_ ref: String, mouse: Bool, double: Bool) throws -> String {
        let (el, win) = try desk.lookup(ref)
        return try acting(win) {
            if mouse || double {
                try Input.click(el, in: win, double: double)
                return double ? "Double-clicked \(ref) with the mouse." : "Clicked \(ref) with the mouse."
            }
            let role = el.string(kAXRoleAttribute) ?? ""
            let actions = el.actions
            if actions.contains(kAXPressAction) {
                let r = el.perform(kAXPressAction)
                guard r == .success else { throw MittsError("Pressing \(ref) failed (AX error \(r.rawValue)). Try --mouse.") }
                return "Pressed \(ref)."
            }
            if ["AXRow", "AXCell", "AXOutlineRow"].contains(role), el.set(kAXSelectedAttribute, kCFBooleanTrue) == .success {
                return "Selected \(ref)."
            }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role), el.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
                return "Focused \(ref)."
            }
            for alt in ["AXPick", "AXConfirm", "AXOpen"] where actions.contains(alt) {
                if el.perform(alt) == .success { return "Did \(alt) on \(ref)." }
            }
            throw MittsError("\(ref) has nothing to press (it offers: \(actions.joined(separator: ", "))). Try --mouse.")
        }
    }

    private func type(_ ref: String, _ text: String, submit: Bool, keys: Bool) throws -> String {
        let (el, win) = try desk.lookup(ref)
        let role = el.string(kAXRoleAttribute) ?? ""
        if role == "AXSecureTextField" || el.string(kAXSubroleAttribute) == "AXSecureTextField" {
            throw MittsError("\(ref) is a password field. Passwords stay with Mike: use `mitts handoff \(desk.ref(for: win)) \"…\"`.")
        }
        return try acting(win) {
            el.set(kAXFocusedAttribute, kCFBooleanTrue)
            var how = ""
            // Setting the value is instant and doesn't depend on focus; real keys are
            // for fields that only listen to key events.
            if keys || el.set(kAXValueAttribute, text as CFString) != .success {
                Input.focus(win)
                try Input.key("cmd+a", pid: win.pid)
                try Input.type(text, pid: win.pid)
                how = " with keys"
            }
            if submit { try Input.key("return", pid: win.pid) }
            return "Typed into \(ref)\(how)\(submit ? " and pressed Return" : "")."
        }
    }

    private func press(_ target: String, _ combos: [String], front: Bool) throws -> String {
        guard !combos.isEmpty else { throw MittsError("Which keys? e.g. `mitts press Finder cmd+shift+g`.") }
        let win: Win
        if target.range(of: #"^e\d+$"#, options: .regularExpression) != nil {
            let (el, w) = try desk.lookup(target)
            el.set(kAXFocusedAttribute, kCFBooleanTrue)
            win = w
        } else {
            win = try desk.window(target)
        }
        for c in combos { _ = try Input.parse(c) }  // fail before sending any of them
        return try acting(win) {
            Input.focus(win)
            let send = { for c in combos { try Input.key(c, pid: win.pid) } }
            if front { try Input.inFront(win, send) } else { try send() }
            return "Pressed \(combos.joined(separator: " "))\(front ? " with the window in front" : "")."
        }
    }

    private func menu(_ appQuery: String, _ path: String?) throws -> String {
        let app = try desk.findApp(appQuery)
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = ax.element(kAXMenuBarAttribute) else { throw MittsError("\(app.localizedName ?? appQuery) has no menu bar.") }
        let parts = (path ?? "").split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces) }
        var items = bar.elements(kAXChildrenAttribute)
        var trail: [String] = []
        for (i, part) in parts.enumerated() {
            let titled = items.map { ($0, $0.string(kAXTitleAttribute) ?? "") }
            guard let (item, title) = titled.first(where: { norm($0.1) == norm(part) }) ?? titled.first(where: { norm($0.1).hasPrefix(norm(part)) }) else {
                let have = titled.map(\.1).filter { !$0.isEmpty }.joined(separator: ", ")
                throw MittsError("No \"\(part)\" in \(trail.isEmpty ? "the menu bar" : trail.joined(separator: " > ")). There's: \(have)")
            }
            trail.append(title)
            let submenu = item.elements(kAXChildrenAttribute).first
            if i == parts.count - 1 && submenu == nil {
                if (item.attr(kAXEnabledAttribute) as? Bool) == false { throw MittsError("\(trail.joined(separator: " > ")) is greyed out.") }
                // Menu items press fine without opening the menu.
                if let win = try? desk.window(app.localizedName ?? appQuery) {
                    return try acting(win) {
                        Input.focus(win)
                        item.perform(kAXPressAction)
                        return "Picked \(trail.joined(separator: " > "))."
                    }
                }
                item.perform(kAXPressAction)
                return "Picked \(trail.joined(separator: " > "))."
            }
            items = submenu?.elements(kAXChildrenAttribute) ?? []
        }
        // Listing: a whole menu, or the menu bar.
        var out: [String] = []
        for item in items {
            let v = item.values([kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemMarkChar", kAXChildrenAttribute])
            guard let title = v[kAXTitleAttribute] as? String, !title.isEmpty else { continue }
            var s = title
            if let ch = v["AXMenuItemCmdChar"] as? String, !ch.isEmpty, ch != "\u{0}" {
                let m = (v["AXMenuItemCmdModifiers"] as? NSNumber)?.intValue ?? 0
                var keys: [String] = []
                if m & 4 != 0 { keys.append("ctrl") }
                if m & 2 != 0 { keys.append("alt") }
                if m & 1 != 0 { keys.append("shift") }
                if m & 8 == 0 { keys.append("cmd") }
                s += "  (\((keys + [ch.lowercased()]).joined(separator: "+")))"
            }
            if !((v[kAXChildrenAttribute] as? [AXUIElement]) ?? []).isEmpty, !parts.isEmpty { s += " >" }
            if let mark = v["AXMenuItemMarkChar"] as? String, !mark.isEmpty { s += " [checked]" }
            if (v[kAXEnabledAttribute] as? Bool) == false { s += " [disabled]" }
            out.append(s)
        }
        return (trail.isEmpty ? "\(app.localizedName ?? appQuery) menus" : trail.joined(separator: " > ")) + "\n" + out.joined(separator: "\n")
    }

    private func scroll(_ target: String, _ direction: String?) throws -> String {
        let isRef = target.range(of: #"^e\d+$"#, options: .regularExpression) != nil
        let el: AXUIElement, win: Win
        if isRef {
            (el, win) = try desk.lookup(target)
        } else {
            win = try desk.window(target)
            el = win.el
        }
        guard let direction else {
            guard isRef else { throw MittsError("Say up or down, e.g. `mitts scroll \(target) down`.") }
            return try acting(win) {
                el.perform("AXScrollToVisible")
                return "Scrolled \(target) into view."
            }
        }
        guard direction == "up" || direction == "down" else { throw MittsError("Scroll up or down.") }
        guard let area = scrollArea(around: el) else { throw MittsError("Nothing scrolls there.") }
        return try acting(win) {
            let action = direction == "up" ? "AXScrollUpByPage" : "AXScrollDownByPage"
            if area.actions.contains(action), area.perform(action) == .success { return "Scrolled \(direction) a page." }
            if let bar = area.element(kAXVerticalScrollBarAttribute), let now = bar.attr(kAXValueAttribute) as? NSNumber {
                let next = min(1, max(0, now.doubleValue + (direction == "up" ? -0.25 : 0.25)))
                if bar.set(kAXValueAttribute, NSNumber(value: next)) == .success { return "Scrolled \(direction)." }
            }
            Input.focus(win)
            try Input.key(direction == "up" ? "pageup" : "pagedown", pid: win.pid)
            return "Pressed \(direction == "up" ? "Page Up" : "Page Down")."
        }
    }

    // The element's own scroll area if it's in one, otherwise the window's biggest.
    private func scrollArea(around el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        while let c = cur {
            let role = c.string(kAXRoleAttribute)
            if role == "AXScrollArea" { return c }
            if role == "AXWindow" { break }
            cur = c.element(kAXParentAttribute)
        }
        var best: (AXUIElement, CGFloat)?
        var queue = [el], seen = 0
        while !queue.isEmpty, seen < 3000 {
            let n = queue.removeFirst()
            seen += 1
            if n.string(kAXRoleAttribute) == "AXScrollArea", let f = n.frame, f.width * f.height > (best?.1 ?? 0) {
                best = (n, f.width * f.height)
                continue
            }
            queue += n.elements(kAXChildrenAttribute)
        }
        return best?.0
    }

    private func shot(_ target: String, max: Int) throws -> String {
        if target.range(of: #"^e\d+$"#, options: .regularExpression) != nil {
            let (el, win) = try desk.lookup(target)
            return try Shot.capture(win, crop: el.frame, maxSide: max)
        }
        return try Shot.capture(try desk.window(target), crop: nil, maxSide: max)
    }

    private func handoff(_ a: Args) throws -> String {
        let target = try a.at(0, "a window")
        let message = try a.at(1, "what Mike needs to do")
        guard !Thread.isMainThread else { throw MittsError("handoff needs the Mitts app; run the installed `mitts`.") }
        let (win, label) = try work.sync { () throws -> (Win, String) in
            let w = try desk.window(target)
            Input.bringForward(w)
            if desk.lastLines[w.id] == nil { desk.lastLines[w.id] = Snapshot.lines(w, desk) }
            return (w, desk.header(w))
        }
        let frame = win.el.frame
        DispatchQueue.main.sync { Handoffs.shared.show(window: win.id, message: message, near: frame) }
        guard let wait = a.flags["wait"].flatMap(Double.init) else {
            return "Over to Mike in \(label): \(message)\nThe panel stays up until he clicks Done. `--wait 300` waits for that."
        }
        guard Handoffs.shared.wait(window: win.id, timeout: wait) else {
            return "Still with Mike after \(Int(wait)) s. Run the same command to keep waiting."
        }
        return try work.sync {
            guard win.el.isAlive else { return "Mike's done; \(label) has closed." }
            let lines = Snapshot.lines(win, desk)
            let d = Snapshot.diff(desk.lastLines[win.id], lines)
            desk.lastLines[win.id] = lines
            return "Mike's done.\n\(label)\(d.full ? "" : " (changes)")\n\(d.text)"
        }
    }
}
