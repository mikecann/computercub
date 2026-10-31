import AppKit
import ApplicationServices
import ComputerCubCore

struct Reply {
    var ok: Bool
    var out: String
    var restart = false
}

struct Args {
    var pos: [String] = []
    var flags: [String: String] = [:]
    static let valued: Set<String> = ["wait", "max", "find"]

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
        guard i < pos.count else { throw CubError("Missing \(what). See `computercub help`.") }
        return pos[i]
    }
}

let helpText = """
ComputerCub: computer use for your Mac. Agents use its apps through the Accessibility API.

  computercub apps                            running apps
  computercub windows [app]                   windows, with refs (w3), size and display
  computercub snap <window> [--full] [--all]  what you can click or type in, with refs
                                              (e12); after the first look, only what changed
  computercub snap <window> --find <text>     just the controls whose line has that text,
                                              searching the whole window
  computercub read <window|ref>               the words in a window or element
  computercub click <ref> [--double] [--mouse] [--pointer]
                                              --mouse sends a click to the window, pointer
                                              untouched; --pointer uses the real one
  computercub click <window> <x> <y> [--double] [--pointer]
                                              for windows with no refs: a spot in the window's
                                              last shot, in that picture's pixels
  computercub swipe <window> <x> <y> <x2> <y2> [--pointer]
                                              press, drag and let go, same pixels
  computercub type <window> <text> [--submit] [--front]
                                              for windows with no refs: keys for whatever's
                                              focused, so click the field first
  computercub type <ref> <text> [--submit] [--keys] [--front]
                                              replaces the field's text; passwords are refused.
                                              Alone it just sets the value; --submit and --keys
                                              use real keys, for when the app has to notice.
                                              If keys can't reach it, --front brings it up
  computercub press <window|ref> <keys>... [--front]
                                              e.g. cmd+shift+g, return, escape, tab, down. The
                                              window stays in the background: cmd shortcuts
                                              press their menu item. Where keys can't reach it,
                                              it says so; --front brings it forward
  computercub menu <app> [File > New Window]  list an app's menus, or pick an item
  computercub scroll <ref|window> [up|down]   bring an element into view, or page a scroll area
  computercub drag <ref> <ref|window>         a real mouse drag, e.g. a file onto a folder
  computercub move <window> <x> <y> [w h]     move (and resize) a window, in points from the
                                              main display's top-left corner
  computercub shot <window|ref> [--max 1600]  window-only PNG; prints the path, deleted after
                                              an hour
  computercub handoff <window> <message> [--wait 300]
                                              brings the window up with an "Over to you" panel,
                                              for sign-ins, passkeys and anything else that only
                                              the person at the Mac should do
  computercub resume                          after \(userName) clicks stop on a window's
                                              marker, carry on there; only when they say so
  computercub doctor                          permissions and displays
  computercub setup                           the window that walks through the permissions
  computercub clean                           delete screenshots and saved reads now
  computercub quit                            stop the background app

A window is w3, an app ("Finder"), an app and part of its title ("Chrome:Web Store"),
or "front". Clicks, typing and keys answer with what changed, so there's no need to
snap again after each one.
"""

final class Commands {
    static let shared = Commands()
    let desk = Desktop.shared
    private let work = DispatchQueue(label: "computercub.work")

    func run(_ argv: [String], agent: String? = nil) -> Reply {
        guard let cmd = argv.first else { return Reply(ok: true, out: helpText) }
        let a = Args(Array(argv.dropFirst()))
        do {
            switch cmd {
            case "help", "-h", "--help": return Reply(ok: true, out: helpText)
            // Waits for Mike outside the work queue, so other commands still run meanwhile.
            case "handoff": return Reply(ok: true, out: try handoff(a, agent: agent))
            case "setup":
                guard !Thread.isMainThread else { throw CubError("setup needs the ComputerCub app; run the installed `computercub`.") }
                DispatchQueue.main.async { SetupWindowController.shared.show() }
                return Reply(ok: true, out: "Opened ComputerCub's setup window.")
            case "quit":
                // Hand Chrome back its normal accessibility mode before going.
                work.sync { desk.relaxWeb(idleFor: 0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return Reply(ok: true, out: "ComputerCub stopped.")
            case "resume":
                let n = Marks.shared.resume()
                return Reply(ok: true, out: n == 0 ? "Nothing was stopped." : "Lifted \(userName)'s stop on \(n == 1 ? "1 window" : "\(n) windows").")
            default:
                return Reply(ok: true, out: try work.sync {
                    desk.agent = agent
                    return try dispatch(cmd, a)
                })
            }
        } catch let e as CubError {
            return Reply(ok: false, out: e.description, restart: e.restart)
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
            return "Deleted ComputerCub's screenshots and saved reads."
        }
        guard AXIsProcessTrusted() else {
            throw CubError("ComputerCub doesn't have Accessibility yet. System Settings › Privacy & Security › Accessibility, turn on ComputerCub, then try again.")
        }
        // Without this they'd all report the windows as closed, and keys meant for a window
        // could end up on the lock screen. apps and menu don't need windows.
        if !["apps", "menu"].contains(cmd), screenLocked { throw CubError(ScreenLock.refusal(user: userName)) }
        switch cmd {
        case "apps": return apps()
        case "windows": return try windows(a.pos.first)
        case "snap":
            if let text = a.flags["find"] { return try find(try a.at(0, "a window"), text) }
            return try snap(try a.at(0, "a window"), full: a.has("full"), all: a.has("all"))
        case "read": return try read(try a.at(0, "a window or ref"))
        case "click":
            if a.pos.count > 1 { return try click(try a.at(0, "a window"), Array(a.pos.dropFirst()), double: a.has("double"), pointer: a.has("pointer")) }
            return try click(try a.at(0, "a ref"), mouse: a.has("mouse"), double: a.has("double"), pointer: a.has("pointer"))
        case "swipe": return try swipe(try a.at(0, "a window"), Array(a.pos.dropFirst()), pointer: a.has("pointer"))
        case "type":
            let target = try a.at(0, "a ref or window")
            if target.range(of: #"^e\d+$"#, options: .regularExpression) == nil {
                return try type(window: target, try a.at(1, "the text"), submit: a.has("submit"), front: a.has("front"))
            }
            return try type(target, try a.at(1, "the text"), submit: a.has("submit"), keys: a.has("keys"), front: a.has("front"))
        case "press": return try press(try a.at(0, "a window or ref"), Array(a.pos.dropFirst()), front: a.has("front"))
        case "menu": return try menu(try a.at(0, "an app"), a.pos.count > 1 ? a.pos[1] : nil)
        case "scroll": return try scroll(try a.at(0, "a ref or window"), a.pos.count > 1 ? a.pos[1] : nil, front: a.has("front"))
        case "shot": return try shot(try a.at(0, "a window or ref"), max: Int(a.flags["max"] ?? "") ?? 1600)
        case "drag": return try drag(try a.at(0, "what to drag"), try a.at(1, "where to drop it"))
        case "move": return try move(try a.at(0, "a window"), Array(a.pos.dropFirst()))
        default: throw CubError("No command \"\(cmd)\". See `computercub help`.")
        }
    }

    // MARK: Looking

    private var screenLocked: Bool {
        ScreenLock.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    private func doctor() -> String {
        var out = [
            "Accessibility: " + (AXIsProcessTrusted() ? "on" : "off. System Settings › Privacy & Security › Accessibility, turn on ComputerCub"),
            "Screen Recording: " + (CGPreflightScreenCaptureAccess() ? "on" : "off, only needed for `computercub shot`. System Settings › Privacy & Security › Screen & System Audio Recording, turn on ComputerCub"),
            "Screen: " + (screenLocked ? "locked, so no windows can be seen or used until \(userName) unlocks" : "unlocked"),
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
        let locked = screenLocked
        let list = desk.apps().map { app in
            var s = app.localizedName ?? "pid \(app.processIdentifier)"
            if app.processIdentifier == front { s += " [frontmost]" }
            if app.isHidden { s += " [hidden]" }
            // Every app would say 0 windows while locked, which isn't true.
            if locked { return s }
            let n = desk.windows(of: app).count
            return s + (n == 1 ? ", 1 window" : ", \(n) windows")
        }.joined(separator: "\n")
        return locked ? "The screen is locked, so window counts aren't available.\n\(list)" : list
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

    // Long settings panes put the control you want hundreds of lines down. This walks
    // everything (as --all) but prints only the matches, and leaves the last look alone
    // so the next snap still diffs against what the agent last saw in full.
    private func find(_ target: String, _ text: String) throws -> String {
        guard !text.isEmpty else { throw CubError("Find what? e.g. `computercub snap \(target) --find Privacy`.") }
        let win = try desk.window(target)
        let lines = Snapshot.lines(win, desk, all: true)
        // Landmarks ([sheet], [toolbar]) say where a match is; keep the one above each.
        var out: [String] = [], landmark: String?
        for l in lines {
            let hit = l.localizedCaseInsensitiveContains(text)
            if l.hasPrefix("[") {
                landmark = hit ? nil : l
                if hit { out.append(l) }
                continue
            }
            guard hit else { continue }
            if let m = landmark { out.append(m); landmark = nil }
            out.append(l)
        }
        let header = desk.header(win)
        if out.isEmpty { return "\(header)\nNothing matching \"\(text)\" in its \(lines.count) lines. `computercub read \(desk.ref(for: win))` has the words that aren't controls." }
        return "\(header) (matching \"\(text)\")\n" + out.joined(separator: "\n")
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
    // settle: look again until two looks agree, for things that animate. Each look of a
    // long pane can take seconds on a busy Mac, so scrolls (which rarely change the
    // list) take just one.
    private func acting(_ win: Win, settle: Bool = true, _ body: () throws -> String) throws -> String {
        let before = Set(desk.windows(of: win.app).map(\.id))
        if desk.lastLines[win.id] == nil { desk.lastLines[win.id] = Snapshot.lines(win, desk) }
        let earlier = sheetElsewhere(win)
        var out = [try body()]
        usleep(250_000)
        if win.el.isAlive {
            var lines = Snapshot.lines(win, desk)
            for _ in 0..<(settle ? 3 : 0) {
                usleep(250_000)
                guard win.el.isAlive else { break }
                let again = Snapshot.lines(win, desk)
                if again == lines { break }
                lines = again
            }
            let d = Snapshot.diff(desk.lastLines[win.id], lines)
            desk.lastLines[win.id] = lines
            // "(no change)" would read as the action having missed in a window like iPhone
            // Mirroring, which can't say what changed.
            if lines.isEmpty {
                out.append("This window shows nothing to Accessibility, so a new `computercub shot \(desk.ref(for: win))` is the way to see what it did.")
            } else {
                out.append(desk.header(win) + (d.full ? "" : " (changes)") + "\n" + d.text)
            }
        } else {
            out.append("\(desk.ref(for: win)) closed.")
        }
        for w in desk.windows(of: win.app) where w.id != 0 && !before.contains(w.id) {
            let lines = Snapshot.lines(w, desk)
            desk.lastLines[w.id] = lines
            out.append("New window: \(desk.header(w))\n" + lines.joined(separator: "\n"))
        }
        if let earlier {
            if earlier.sheet.isAlive { out.append("\(desk.ref(for: earlier.host)) still has a sheet open. Keys pointed at \(desk.ref(for: win)) don't reach it; point them at \(desk.ref(for: earlier.host)).") }
        } else if let now = sheetElsewhere(win) {
            let lines = Snapshot.lines(now.host, desk)
            let d = Snapshot.diff(desk.lastLines[now.host.id], lines)
            desk.lastLines[now.host.id] = lines
            out.append("A sheet opened on another window: \(desk.header(now.host))\n\(d.text)")
        }
        return out.joined(separator: "\n")
    }

    // The sheet holding the app's keys, if it's on a window other than this one. Finder
    // puts Go to Folder on a browser window even when cmd+shift+g was pressed at a Get Info
    // window, and from there Escape meant for "the panel" went to the wrong window.
    private func sheetElsewhere(_ win: Win) -> (sheet: AXUIElement, host: Win)? {
        guard let sheet = AXUIElementCreateApplication(win.pid).element(kAXFocusedWindowAttribute),
              sheet.string(kAXRoleAttribute) == kAXSheetRole else { return nil }
        var top = sheet.element(kAXParentAttribute)
        for _ in 0..<4 where top?.string(kAXRoleAttribute) == kAXSheetRole { top = top?.element(kAXParentAttribute) }
        guard let top, !CFEqual(top, win.el), let host = desk.windows(of: win.app).first(where: { CFEqual($0.el, top) }) else { return nil }
        return (sheet, host)
    }

    private func click(_ ref: String, mouse: Bool, double: Bool, pointer: Bool) throws -> String {
        let (el, win) = try desk.lookup(ref)
        return try acting(win) {
            // A double-click opens things, and most rows say so through AXOpen on their
            // cell, so try that before borrowing Mike's pointer.
            if double && !mouse && !pointer, let target = openable(el) {
                // Finder's sidebar answers AXOpen with "unsupported" (-25205) and opens
                // the folder anyway, so the error code says nothing. The diff shows if it went.
                target.perform("AXOpen")
                return "Opened \(ref)."
            }
            if pointer {
                try Input.click(el, in: win, double: double)
                return "\(double ? "Double-clicked" : "Clicked") \(ref) with \(userName)'s pointer."
            }
            if mouse || double {
                try Input.post(click: el, in: win, double: double)
                return "\(double ? "Double-clicked" : "Clicked") \(ref) with a click sent to the window, so the pointer didn't move. If nothing changed, --pointer clicks with the real one."
            }
            let role = el.string(kAXRoleAttribute) ?? ""
            let actions = el.actions
            if actions.contains(kAXPressAction) {
                let r = el.perform(kAXPressAction)
                guard r == .success else { throw CubError("Pressing \(ref) failed (AX error \(r.rawValue)). Try --mouse.") }
                return "Pressed \(ref)."
            }
            if ["AXRow", "AXCell", "AXOutlineRow"].contains(role), el.set(kAXSelectedAttribute, kCFBooleanTrue) == .success {
                return "Selected \(ref). If it should have opened too (Finder's sidebar), use --double."
            }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role), el.set(kAXFocusedAttribute, kCFBooleanTrue) == .success {
                return el.isFocused ? "Focused \(ref)." : "\(ref) didn't take focus from the background. Try --mouse."
            }
            for alt in ["AXPick", "AXConfirm", "AXOpen"] where actions.contains(alt) {
                if el.perform(alt) == .success { return "Did \(alt) on \(ref)." }
            }
            throw CubError("\(ref) has nothing to press (it offers: \(actions.joined(separator: ", "))). Try --mouse.")
        }
    }

    // For windows with nothing in Accessibility, where a position in a shot is all there is
    // to aim at. A plain AX press can't exist here, so it's --mouse's route by default.
    private func click(_ target: String, _ numbers: [String], double: Bool, pointer: Bool) throws -> String {
        let win = try desk.window(target)
        let v = numbers.compactMap(Double.init)
        guard v.count == 2, numbers.count == 2 else {
            throw CubError("Give x and y from the window's last shot: `computercub click \(target) 120 340`.")
        }
        let p = try shotPoint(win, target, x: v[0], y: v[1])
        let at = "\(fmt(v[0])),\(fmt(v[1]))", done = double ? "Double-clicked" : "Clicked"
        return try acting(win) {
            if pointer {
                try Input.click(at: p, in: win, double: double)
                return "\(done) \(at) with \(userName)'s pointer."
            }
            Input.focusBehind(win)
            Input.post(clickAt: p, in: win, double: double, hold: Input.positionHold)
            return "\(done) \(at) with a click sent to the window, so the pointer didn't move. If a shot shows it didn't land, --pointer uses the real one, which takes \(userName)'s pointer."
        }
    }

    private func swipe(_ target: String, _ numbers: [String], pointer: Bool) throws -> String {
        let win = try desk.window(target)
        let v = numbers.compactMap(Double.init)
        guard v.count == 4, numbers.count == 4 else {
            throw CubError("Give where to start and end, from the window's last shot: `computercub swipe \(target) 300 900 300 300`.")
        }
        let a = try shotPoint(win, target, x: v[0], y: v[1]), b = try shotPoint(win, target, x: v[2], y: v[3])
        let path = "\(fmt(v[0])),\(fmt(v[1])) to \(fmt(v[2])),\(fmt(v[3]))"
        return try acting(win) {
            if pointer {
                try Input.swipe(from: a, to: b, in: win)
                return "Swiped \(path) with \(userName)'s pointer."
            }
            Input.focusBehind(win)
            Input.post(swipeFrom: a, to: b, in: win)
            return "Swiped \(path) with events sent to the window, so the pointer didn't move. If a shot shows it didn't land, --pointer uses the real one, which takes \(userName)'s pointer."
        }
    }

    // A position in the window's last shot, as a point in the window. Refuses rather than
    // guesses: a click somewhere other than where the agent looked can do real damage.
    private func shotPoint(_ win: Win, _ target: String, x: Double, y: Double) throws -> CGPoint {
        guard let map = desk.lastShots[win.id] else {
            throw CubError("Positions come from the window's last shot, and there isn't one. Run `computercub shot \(target)` first.")
        }
        if (win.el.attr(kAXMinimizedAttribute) as? Bool) == true { throw CubError("That window is minimised.") }
        guard let now = win.el.frame, !map.stale(windowSize: now.size) else {
            throw CubError("The window has changed size since its last shot, so that spot has moved. Run `computercub shot \(target)` again.")
        }
        guard map.inPicture(x: x, y: y) else {
            throw CubError("\(fmt(x)),\(fmt(y)) is outside the last shot, which is \(Int(map.size.width))×\(Int(map.size.height)).")
        }
        let p = map.point(x: x, y: y)
        guard map.inWindow(p) else { throw CubError("\(fmt(x)),\(fmt(y)) is over a menu or popover, not the window. Use `computercub snap \(target)` and click its ref.") }
        return p
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    // The element itself, its cells (a row), or the cell around it (a row's text).
    private func openable(_ el: AXUIElement) -> AXUIElement? {
        if el.actions.contains("AXOpen") { return el }
        if let cell = el.elements(kAXChildrenAttribute).first(where: { $0.actions.contains("AXOpen") }) { return cell }
        if let up = el.element(kAXParentAttribute), up.actions.contains("AXOpen") { return up }
        return nil
    }

    private func type(_ ref: String, _ text: String, submit: Bool, keys: Bool, front: Bool) throws -> String {
        let (el, win) = try desk.lookup(ref)
        let role = el.string(kAXRoleAttribute) ?? ""
        if role == "AXSecureTextField" || el.string(kAXSubroleAttribute) == "AXSecureTextField" {
            throw CubError("\(ref) is a password field. Passwords stay with \(userName): use `computercub handoff \(desk.ref(for: win)) \"…\"`.")
        }
        return try acting(win) {
            // Setting the value is instant and doesn't depend on focus, but the app isn't told:
            // the snap shows the new text while Finder's rename fields carry on as before. So
            // anything that has to take effect goes in as real keys, as Mike would type it.
            if !keys && !submit {
                if !el.isFocused { el.set(kAXFocusedAttribute, kCFBooleanTrue) }
                if el.set(kAXValueAttribute, text as CFString) == .success {
                    return "Set \(ref)'s text directly, so the app may not have noticed yet. --submit or --keys types it for real."
                }
            }
            let forward = try typeKeys(text, into: el, ref: ref, win: win, submit: submit, front: front)
            return "Typed into \(ref) with keys\(forward ? " with the window brought forward" : "")\(submit ? " and pressed Return" : "")."
        }
    }

    // For windows with no refs: keys go to whatever the window has focused, so tap the field
    // first. Nothing can read the text back, so it can't refuse a password field or say the
    // keys landed the way the ref version does.
    private func type(window target: String, _ text: String, submit: Bool, front: Bool) throws -> String {
        let win = try desk.window(target)
        return try acting(win) {
            if !front { Input.focusBehind(win) }
            let moved = try Input.toWindow(win, front: front) { to in
                try Input.type(text, pid: to)
                if submit { try Input.key("return", pid: to) }
            }
            return "Sent the keys to the window\(moved ? " in front" : "")\(submit ? " and pressed Return" : "")."
        }
    }

    // Tries from the background first. Some fields are drawn by a helper process that keys
    // sent to the app never reach (Finder's page for a plugged-in iPhone belongs to
    // com.apple.amp.devicesui, though Accessibility says it's Finder's), and some only start
    // editing on a real click. So check the text landed, and if it didn't, do what Mike
    // would: bring the window up, click the field, and use the keyboard. That takes his
    // focus, so only with --front (or with the app in front already); otherwise it says
    // so and leaves the call to the agent. Returns whether the window came forward.
    private func typeKeys(_ text: String, into el: AXUIElement, ref: String, win: Win, submit: Bool, front: Bool) throws -> Bool {
        func send(_ to: pid_t?) throws -> Bool {
            if !el.selectAllText() { try Input.key("cmd+a", pid: to) }
            try Input.type(text, pid: to)
            return el.waitForText(text)
        }
        if !el.isFocused { el.set(kAXFocusedAttribute, kCFBooleanTrue) }
        var why = el.isFocused ? "\(ref) already shows that text, so there's no telling whether keys land" : "\(ref) wouldn't take focus in the background"
        // If the field already shows this text, there's no telling whether keys landed.
        if el.isFocused, el.string(kAXValueAttribute) != text {
            var landed = false
            do {
                try Input.toWindow(win, front: false) { to in
                    landed = try send(to)
                    if landed && submit { try Input.key("return", pid: to) }
                }
                if landed { return false }
                why = "keys sent in the background didn't land in \(ref)" + (el.string(kAXValueAttribute).map { " (it shows \"\(clip($0))\")" } ?? "")
            } catch is CubError where front {
                // Keys can't get there from the background, and --front says come forward.
            }
        }
        if !front && win.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            throw CubError("Not typed: \(why). Bringing the window up to click it would take \(userName)'s focus; if it's worth that, run it again with --front. "
                + "Without --submit or --keys, type just sets the text.")
        }
        try Input.toWindow(win, front: true) { to in
            if !el.isFocused { el.set(kAXFocusedAttribute, kCFBooleanTrue) }
            // The first click on a page that's just loaded can go unnoticed, hence two tries:
            // one sent to the window, then Mike's pointer if that didn't take.
            for attempt in 0..<2 where !el.isFocused {
                if attempt == 0 { try Input.post(click: el, in: win, double: false) } else { try Input.click(el, in: win, double: false) }
                usleep(250_000)
            }
            guard try send(to) else {
                let now = el.string(kAXValueAttribute).map { "\"\(clip($0))\"" } ?? "something else"
                throw CubError("Typed into \(ref), but it shows \(now)\(submit ? ", so Return wasn't pressed" : "").")
            }
            if submit { try Input.key("return", pid: to) }
        }
        return true
    }

    private func press(_ target: String, _ combos: [String], front: Bool) throws -> String {
        guard !combos.isEmpty else { throw CubError("Which keys? e.g. `computercub press Finder cmd+shift+g`.") }
        let win: Win
        if target.range(of: #"^e\d+$"#, options: .regularExpression) != nil {
            let (el, w) = try desk.lookup(target)
            // Asking again from the background can knock a field out of editing.
            if !el.isFocused { el.set(kAXFocusedAttribute, kCFBooleanTrue) }
            win = w
        } else {
            win = try desk.window(target)
        }
        for c in combos { _ = try Input.parse(c) }  // fail before sending any of them
        // In front already (or asked to come forward), keys behave as Mike's would.
        if front || win.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return try acting(win) {
                let moved = try Input.toWindow(win, front: front) { to in for c in combos { try Input.key(c, pid: to) } }
                return "Pressed \(combos.joined(separator: " "))\(moved ? " with the window in front" : "")."
            }
        }
        // Cmd+w is the shortcut agents send most, and the window's own close button works
        // from the background. Picking the menu item doesn't: background apps grey out
        // Close (nothing is their key window), and a greyed-out item does nothing even when
        // pressed through AX. Not where cmd+w would close a tab instead: in a browser, or a
        // window with tabs.
        let combo = combos.first?.lowercased().replacingOccurrences(of: "command", with: "cmd") ?? ""
        if !Input.onSheet(win), combos.count == 1, combo == "cmd+w", !hasTabs(win),
           let close = win.el.element(kAXCloseButtonAttribute), (close.attr(kAXEnabledAttribute) as? Bool) != false {
            return try acting(win) {
                close.perform(kAXPressAction)
                return "Pressed cmd+w (the window's close button, so it stayed in the background)."
            }
        }
        return try acting(win) {
            var done: [String] = []
            for c in combos {
                do { done.append(try pressBehind(c, win)) } catch let e as CubError where !done.isEmpty {
                    throw CubError("Pressed \(done.joined(separator: ", ")), but not \(c). \(e.description)")
                }
            }
            return "Pressed \(done.joined(separator: ", ")), with the window left in the background."
        }
    }

    // One key for a window in the background, by whichever route keeps it there. Throws,
    // rather than bringing it forward, when none will: taking Mike's focus is the agent's
    // call to make, with --front.
    private func pressBehind(_ combo: String, _ win: Win) throws -> String {
        let cmd = try Input.parse(combo).1.contains(.maskCommand)
        let sheet = Input.onSheet(win)
        let retry = "If it's worth taking \(userName)'s focus, run it again with --front."
        // macOS only fires a shortcut in the active app, so press its menu item instead.
        // Not while a sheet's up: the sheet's shortcuts (a file picker's cmd+shift+g) are
        // its own, and the app's menu would act on the window under it.
        if !sheet, try Input.menuItem(for: combo, pid: win.pid) != nil {
            // Menu items act on the app's key window, so point it at ours first, and look
            // again after: some items only light up once there's a window to act on.
            if !Input.aimed(win) { Input.focus(win); usleep(50_000) }
            guard Input.aimed(win) else {
                throw CubError("Not sent: \(win.appName)'s menus would act on another of its windows while it's in the background. \(retry)")
            }
            if let (item, title, enabled) = try Input.menuItem(for: combo, pid: win.pid) {
                guard enabled else {
                    throw CubError("Not sent: \(combo) is \(win.appName)'s \"\(title)\", which is greyed out while it's in the background. A button in the window may do the same from there (snap shows them). \(retry)")
                }
                let mine = NSWorkspace.shared.frontmostApplication
                item.perform(kAXPressAction)
                // Some items bring their app forward themselves (Finder's Go to Folder), so
                // hand Mike's app straight back. What they opened may only work in front.
                usleep(300_000)
                if let mine, mine.processIdentifier != win.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == win.pid {
                    AXUIElementCreateApplication(mine.processIdentifier).set(kAXFrontmostAttribute, kCFBooleanTrue)
                    mine.activate()
                    return "\(combo) (\"\(title)\" from the menu; \(win.appName) came forward by itself for it and was sent back, and what it opened may only respond with --front)"
                }
                return "\(combo) (\"\(title)\" from the menu)"
            }
        }
        if let how = Input.confirm(combo, in: win) { return "\(combo) (\(how))" }
        if cmd {
            let why = sheet ? "keys for its sheet only get there with the window in front (its buttons and fields work from the background, so click or type into those instead)"
                : "\(win.appName) has no menu item for it, and shortcuts only work in the active app"
            throw CubError("Not sent: \(why). \(retry)")
        }
        try Input.toWindow(win, front: false) { try Input.key(combo, pid: $0) }
        return combo
    }

    private func hasTabs(_ win: Win) -> Bool {
        let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "net.imput.helium",
                                     "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]
        if browsers.contains(win.app.bundleIdentifier ?? "") { return true }
        func look(_ el: AXUIElement, _ depth: Int) -> Bool {
            for kid in el.elements(kAXChildrenAttribute) {
                if kid.string(kAXRoleAttribute) == kAXTabGroupRole { return true }
                if depth < 2, look(kid, depth + 1) { return true }
            }
            return false
        }
        return look(win.el, 0)
    }

    private func menu(_ appQuery: String, _ path: String?) throws -> String {
        let app = try desk.findApp(appQuery)
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = ax.element(kAXMenuBarAttribute) else { throw CubError("\(app.localizedName ?? appQuery) has no menu bar.") }
        let parts = (path ?? "").split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces) }
        var items = bar.elements(kAXChildrenAttribute)
        var trail: [String] = []
        for (i, part) in parts.enumerated() {
            let titled = items.map { ($0, $0.string(kAXTitleAttribute) ?? "") }
            guard let (item, title) = titled.first(where: { norm($0.1) == norm(part) }) ?? titled.first(where: { norm($0.1).hasPrefix(norm(part)) }) else {
                let have = titled.map(\.1).filter { !$0.isEmpty }.joined(separator: ", ")
                throw CubError("No \"\(part)\" in \(trail.isEmpty ? "the menu bar" : trail.joined(separator: " > ")). There's: \(have)")
            }
            trail.append(title)
            let submenu = item.elements(kAXChildrenAttribute).first
            if i == parts.count - 1 && submenu == nil {
                if (item.attr(kAXEnabledAttribute) as? Bool) == false { throw CubError("\(trail.joined(separator: " > ")) is greyed out.") }
                // Listing is fine, but a pick here would run with no window to show what it
                // did, on a Mac nobody's watching.
                if screenLocked { throw CubError(ScreenLock.refusal(user: userName)) }
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

    private func scroll(_ target: String, _ direction: String?, front: Bool) throws -> String {
        let isRef = target.range(of: #"^e\d+$"#, options: .regularExpression) != nil
        let el: AXUIElement, win: Win
        if isRef {
            (el, win) = try desk.lookup(target)
        } else {
            win = try desk.window(target)
            el = win.el
        }
        guard let direction else {
            guard isRef else { throw CubError("Say up or down, e.g. `computercub scroll \(target) down`.") }
            return try acting(win, settle: false) {
                Input.reveal(el, in: win)
                guard Input.shown(el, in: win) else { throw CubError("\(target) wouldn't scroll into view.") }
                return "Scrolled \(target) into view."
            }
        }
        guard direction == "up" || direction == "down" else { throw CubError("Scroll up or down.") }
        guard let area = scrollArea(around: el) else { throw CubError("Nothing scrolls there.") }
        let bar = area.element(kAXVerticalScrollBarAttribute)
        // Where it got to, so an agent can tell when to stop.
        func whereNow() -> String {
            guard let v = (bar?.attr(kAXValueAttribute) as? NSNumber)?.doubleValue else { return "" }
            return v >= 0.995 ? " (at the bottom)" : v <= 0.005 ? " (at the top)" : " (\(Int(v * 100))% of the way down)"
        }
        return try acting(win, settle: false) {
            // The bar first: System Settings' SwiftUI panes say yes to AXScrollDownByPage and
            // jump to the top instead, so paging through one never got past the first screen.
            if let bar, let now = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue {
                // Nine tenths of what's showing, so a line at the edge stays in view.
                let page = Input.scrollRange(area, vertical: true).map { $0.visible * 0.9 / $0.range } ?? 0.25
                let next = min(1, max(0, now + (direction == "up" ? -page : page)))
                if bar.set(kAXValueAttribute, NSNumber(value: next)) == .success {
                    usleep(150_000)
                    return "Scrolled \(direction) a page\(whereNow())."
                }
            }
            let action = direction == "up" ? "AXScrollUpByPage" : "AXScrollDownByPage"
            if area.actions.contains(action), area.perform(action) == .success {
                usleep(150_000)
                return "Scrolled \(direction) a page\(whereNow())."
            }
            try Input.toWindow(win, front: front) { try Input.key(direction == "up" ? "pageup" : "pagedown", pid: $0) }
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
            // Role and children in one round trip; this walk covers the whole window.
            let v = n.values([kAXRoleAttribute, kAXChildrenAttribute])
            if v[kAXRoleAttribute] as? String == "AXScrollArea" {
                if let f = n.frame, f.width * f.height > (best?.1 ?? 0) { best = (n, f.width * f.height) }
                continue
            }
            queue += v[kAXChildrenAttribute] as? [AXUIElement] ?? []
        }
        return best?.0
    }

    // There's no accessibility action for dragging, so this is a real mouse drag:
    // the window comes forward, and the pointer goes back where it was afterwards.
    private func drag(_ from: String, _ to: String) throws -> String {
        let (src, win) = try desk.lookup(from)
        let dest = to.range(of: #"^e\d+$"#, options: .regularExpression) != nil ? try desk.lookup(to) : nil
        let destWin = dest == nil ? try desk.window(to) : nil
        return try acting(win) {
            Input.bringForward(win)
            usleep(300_000)
            // Points come after raising and scrolling, which both move things.
            Input.reveal(src, in: win)
            guard Input.shown(src, in: win), let a = grabPoint(src) else { throw CubError("\(from) is out of view. Not dragging.") }
            let b: CGPoint
            if let dest {
                guard let p = grabPoint(dest.el) else { throw CubError("Can't tell where \(to) is on screen.") }
                b = p
            } else {
                guard let f = destWin?.el.frame else { throw CubError("Can't tell where \(to) is on screen.") }
                b = CGPoint(x: f.midX, y: f.midY)
            }
            for (p, name) in [(a, from), (b, to)] {
                if let owner = Input.owner(at: p), owner != win.pid, name == from || desk.windowOwner(to) != owner {
                    let app = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "another app"
                    throw CubError("\(app) is on top of \(name), so the drag would land there. Not dragging.")
                }
            }
            Input.drag(from: a, to: b)
            return "Dragged \(from) onto \(to) with the mouse."
        }
    }

    // Where to take hold of an element. In a list, the middle of a row is often
    // empty space, where a drag draws a selection box (Finder's list view), so
    // grab the row's icon or name instead.
    private func grabPoint(_ el: AXUIElement) -> CGPoint? {
        let role = el.string(kAXRoleAttribute) ?? ""
        if role == "AXRow" || role == "AXCell" {
            var queue = el.elements(kAXChildrenAttribute), seen = 0
            while !queue.isEmpty, seen < 40 {
                let k = queue.removeFirst()
                seen += 1
                let r = k.string(kAXRoleAttribute) ?? ""
                if ["AXImage", "AXTextField", "AXStaticText"].contains(r), let f = k.frame, f.width > 0 {
                    return CGPoint(x: f.midX, y: f.midY)
                }
                queue += k.elements(kAXChildrenAttribute)
            }
        }
        guard let f = el.frame, f.width > 0 else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    private func move(_ target: String, _ numbers: [String]) throws -> String {
        let win = try desk.window(target)
        let v = numbers.compactMap(Double.init)
        guard v.count == 2 || v.count == 4 else {
            throw CubError("Give x and y (top-left, in points), and optionally width and height: `computercub move \(target) 100 80 1200 800`.")
        }
        var p = CGPoint(x: v[0], y: v[1])
        guard win.el.set(kAXPositionAttribute, AXValueCreate(.cgPoint, &p)!) == .success else {
            throw CubError("\(win.appName) wouldn't move that window.")
        }
        if v.count == 4 {
            var s = CGSize(width: v[2], height: v[3])
            win.el.set(kAXSizeAttribute, AXValueCreate(.cgSize, &s)!)
        }
        usleep(150_000)
        return "Moved " + desk.describe(win, focused: nil)
    }

    private func shot(_ target: String, max: Int) throws -> String {
        let el: AXUIElement?, win: Win
        if target.range(of: #"^e\d+$"#, options: .regularExpression) != nil {
            (el, win) = try { let (e, w) = try desk.lookup(target); return (e, w) }()
        } else {
            (el, win) = (nil, try desk.window(target))
        }
        let taken = try Shot.capture(win, crop: el?.frame, maxSide: max, overlays: desk.overlays(of: win))
        desk.lastShots[win.id] = taken.map
        return taken.line
    }

    private func handoff(_ a: Args, agent: String?) throws -> String {
        let target = try a.at(0, "a window")
        let message = try a.at(1, "what \(userName) needs to do")
        guard !Thread.isMainThread else { throw CubError("handoff needs the ComputerCub app; run the installed `computercub`.") }
        if screenLocked { throw CubError(ScreenLock.refusal(user: userName)) }
        let (win, label) = try work.sync { () throws -> (Win, String) in
            desk.agent = agent
            let w = try desk.window(target)
            // It's Mike's turn in there, so the "agent at work" mark comes off.
            Marks.shared.hide(w.id)
            Input.bringForward(w)
            if desk.lastLines[w.id] == nil { desk.lastLines[w.id] = Snapshot.lines(w, desk) }
            return (w, desk.header(w))
        }
        let frame = win.el.frame
        DispatchQueue.main.sync { Handoffs.shared.show(window: win.id, message: message, near: frame) }
        guard let wait = a.flags["wait"].flatMap(Double.init) else {
            return "Over to \(userName) in \(label): \(message)\nThe panel stays up until they click Done. `--wait 300` waits for that."
        }
        guard Handoffs.shared.wait(window: win.id, timeout: wait) else {
            return "Still with \(userName) after \(Int(wait)) s. Run the same command to keep waiting."
        }
        return try work.sync {
            guard win.el.isAlive else { return "\(userName)'s done; \(label) has closed." }
            let lines = Snapshot.lines(win, desk)
            let d = Snapshot.diff(desk.lastLines[win.id], lines)
            desk.lastLines[win.id] = lines
            return "\(userName)'s done.\n\(label)\(d.full ? "" : " (changes)")\n\(d.text)"
        }
    }
}
