import AppKit
import ApplicationServices

struct Win {
    let el: AXUIElement
    let app: NSRunningApplication
    let id: CGWindowID
    var pid: pid_t { app.processIdentifier }
    var appName: String { app.localizedName ?? "pid \(pid)" }
    var title: String { el.string(kAXTitleAttribute) ?? "" }
}

// Everything the service remembers between commands: which refs point where, and the
// last snapshot of each window so the next look can be a diff.
final class Desktop {
    static let shared = Desktop()

    private var windowRefs: [CGWindowID: String] = [:]
    private var windowsByRef: [String: (pid: pid_t, id: CGWindowID)] = [:]
    private var elementRefs: [AXKey: String] = [:]
    private var elementsByRef: [String: (el: AXUIElement, window: CGWindowID, pid: pid_t)] = [:]
    private var nextWindow = 1, nextElement = 1
    private var webTurnedOn: Set<pid_t> = []
    var lastLines: [CGWindowID: [String]] = [:]

    // Window refs follow the CGWindowID, which lasts as long as the window does.
    func ref(for win: Win) -> String {
        if let r = windowRefs[win.id] { return r }
        let r = "w\(nextWindow)"
        nextWindow += 1
        windowRefs[win.id] = r
        windowsByRef[r] = (win.pid, win.id)
        return r
    }

    // What each ref looked like in the last snapshot of its window ("row \"Keyboard\"").
    var signatures: [CGWindowID: [String: String]] = [:]

    func ref(for el: AXUIElement, in win: Win, signature: String? = nil) -> String {
        let key = AXKey(el: el)
        if let r = elementRefs[key] { return r }
        // SwiftUI (System Settings) hands out new elements for the same control on every
        // look. If one looks exactly like a control that just went away, it keeps that
        // control's ref, so diffs show real changes rather than churn.
        if let signature, let old = signatures[win.id]?[signature], let prev = elementsByRef[old],
           !CFEqual(prev.el, el), !prev.el.isAlive {
            elementRefs.removeValue(forKey: AXKey(el: prev.el))
            elementRefs[key] = old
            elementsByRef[old] = (el, win.id, win.pid)
            return old
        }
        let r = "e\(nextElement)"
        nextElement += 1
        elementRefs[key] = r
        elementsByRef[r] = (el, win.id, win.pid)
        return r
    }

    func lookup(_ ref: String) throws -> (el: AXUIElement, win: Win) {
        guard let e = elementsByRef[ref] else { throw MittsError("No element \(ref). Refs come from `mitts snap`.") }
        guard e.el.isAlive else { throw MittsError("\(ref) has gone (the app removed it). Take another look with `mitts snap`.") }
        return (e.el, try window(pid: e.pid, id: e.window, ref: ref))
    }

    private func window(pid: pid_t, id: CGWindowID, ref: String) throws -> Win {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw MittsError("The app that had \(ref) has quit.")
        }
        guard let w = windows(of: app).first(where: { $0.id == id }) else {
            throw MittsError("The window that had \(ref) has closed.")
        }
        return w
    }

    func apps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    func windows(of app: NSRunningApplication) -> [Win] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app would otherwise stall every command for the default 6 s.
        AXUIElementSetMessagingTimeout(ax, 1.5)
        // Finder lists the desktop among its windows, as a scroll area.
        return ax.elements(kAXWindowsAttribute)
            .filter { $0.string(kAXRoleAttribute) == kAXWindowRole }
            .map { Win(el: $0, app: app, id: $0.windowID) }
    }

    func findApp(_ query: String) throws -> NSRunningApplication {
        let q = query.lowercased()
        let all = apps()
        let name = { (a: NSRunningApplication) in (a.localizedName ?? "").lowercased() }
        if let a = all.first(where: { name($0) == q || $0.bundleIdentifier?.lowercased() == q }) { return a }
        let partial = all.filter { name($0).contains(q) || ($0.bundleIdentifier?.lowercased().contains(q) ?? false) }
        if partial.count == 1 { return partial[0] }
        // "Chrome" means Google Chrome, not Google Chrome for Testing: the shortest name
        // wins when it starts every other one.
        if let shortest = partial.min(by: { name($0).count < name($1).count }),
           partial.allSatisfy({ name($0).hasPrefix(name(shortest)) }) {
            return shortest
        }
        if partial.isEmpty {
            throw MittsError("No app like \"\(query)\" is running. Running: \(all.compactMap(\.localizedName).joined(separator: ", "))")
        }
        throw MittsError("\"\(query)\" could be \(partial.compactMap(\.localizedName).joined(separator: " or ")). Say which.")
    }

    // A window can be named as w3, an element ref (its window), an app ("Finder"), an app
    // and part of a title ("Chrome:Web Store"), or "front" for whatever Mike is looking at.
    func window(_ target: String) throws -> Win {
        if target.range(of: #"^w\d+$"#, options: .regularExpression) != nil {
            guard let w = windowsByRef[target] else { throw MittsError("No window \(target). `mitts windows` lists them.") }
            return try window(pid: w.pid, id: w.id, ref: target)
        }
        if target.range(of: #"^e\d+$"#, options: .regularExpression) != nil { return try lookup(target).win }

        var appQuery = target, titleQuery = ""
        if let i = target.firstIndex(of: ":") {
            appQuery = String(target[..<i])
            titleQuery = target[target.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let app: NSRunningApplication
        if appQuery == "front" {
            guard let f = NSWorkspace.shared.frontmostApplication else { throw MittsError("Nothing is frontmost.") }
            app = f
        } else {
            app = try findApp(appQuery)
        }
        let wins = windows(of: app)
        let name = app.localizedName ?? appQuery
        guard !wins.isEmpty else { throw MittsError("\(name) has no windows open (on this Space).") }
        if !titleQuery.isEmpty {
            let matches = wins.filter { $0.title.localizedCaseInsensitiveContains(titleQuery) }
            guard !matches.isEmpty else {
                throw MittsError("No \(name) window titled like \"\(titleQuery)\". Its windows: \(wins.map { "\"\(clip($0.title, 60))\"" }.joined(separator: ", "))")
            }
            return preferFocused(matches, app)
        }
        return preferFocused(wins, app)
    }

    private func preferFocused(_ wins: [Win], _ app: NSRunningApplication) -> Win {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let f = ax.element(attr), let w = wins.first(where: { CFEqual($0.el, f) }) { return w }
        }
        return wins[0]
    }

    func header(_ win: Win) -> String {
        "\(ref(for: win)) \(win.appName) \"\(clip(win.title))\""
    }

    func describe(_ win: Win, focused: AXUIElement?) -> String {
        var s = "\(ref(for: win)) \"\(clip(win.title, 70))\""
        let v = win.el.values([kAXSubroleAttribute, kAXMinimizedAttribute])
        if let f = win.el.frame {
            s += " \(Int(f.width))×\(Int(f.height)) on \(Self.display(for: f))"
        }
        var flags: [String] = []
        if let focused, CFEqual(focused, win.el) { flags.append("focused") }
        if (v[kAXMinimizedAttribute] as? Bool) == true { flags.append("minimised") }
        if let sub = v[kAXSubroleAttribute] as? String, sub != "AXStandardWindow" {
            flags.append(sub.replacingOccurrences(of: "AX", with: "").lowercased())
        }
        if !flags.isEmpty { s += " [\(flags.joined(separator: ", "))]" }
        return s
    }

    // NSScreen frames are bottom-left origin; AX frames are top-left from the main
    // display. Flip using the main display's height so they line up on every display.
    static func display(for frame: CGRect) -> String {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return "?" }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        for s in screens {
            let f = s.frame
            let topLeft = CGRect(x: f.minX, y: primary.frame.height - f.maxY, width: f.width, height: f.height)
            if topLeft.contains(c) { return s.localizedName }
        }
        return "no display (off-screen)"
    }

    // Chromium and Electron only build their web accessibility tree when they think a
    // screen reader is listening. AXManualAccessibility asks for it without the window
    // animation side effects of AXEnhancedUserInterface. Returns true the first time.
    func ensureWeb(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if enhanced[pid] != nil { enhanced[pid] = Date() }
        guard !webTurnedOn.contains(pid) else { return false }
        webTurnedOn.insert(pid)
        return AXUIElementCreateApplication(pid).set("AXManualAccessibility", kCFBooleanTrue) == .success
    }

    // Chrome itself (as opposed to Electron) may only listen to AXEnhancedUserInterface,
    // the switch VoiceOver flips. It makes Chrome keep a full tree for every tab and
    // slows its window animations, so relaxWeb hands it back once we stop looking.
    private var enhanced: [pid_t: Date] = [:]

    func tryEnhancedWeb(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard enhanced[pid] == nil else { return false }
        guard AXUIElementCreateApplication(pid).set("AXEnhancedUserInterface", kCFBooleanTrue) == .success else { return false }
        enhanced[pid] = Date()
        return true
    }

    func relaxWeb(idleFor seconds: TimeInterval) {
        for (pid, used) in enhanced where Date().timeIntervalSince(used) > seconds {
            AXUIElementCreateApplication(pid).set("AXEnhancedUserInterface", kCFBooleanFalse)
            enhanced.removeValue(forKey: pid)
        }
    }

    static func isChromium(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier?.lowercased() ?? ""
        return ["chrome", "chromium", "brave", "edgemac", "thebrowser", "helium", "vivaldi", "opera"].contains { id.contains($0) }
    }
}
