import AppKit
import ApplicationServices
import ComputerCubCore

// Private, but it's been stable since 10.6 and every window manager uses it (Rectangle,
// AltTab, Peekaboo). It's the only way from an AX window to the CGWindowID that
// ScreenCaptureKit wants, and the id is what keeps window refs stable.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct CubError: Error, CustomStringConvertible {
    let description: String
    // A fresh process might succeed where this one can't: macOS only hands a Screen
    // Recording grant to processes started after it was given.
    let restart: Bool
    init(_ description: String, restart: Bool = false) {
        self.description = description
        self.restart = restart
    }
}

// Two AXUIElements for the same control compare equal with CFEqual, even when fetched
// separately, so they can key a dictionary. That's what makes element refs stick.
struct AXKey: Hashable {
    let el: AXUIElement
    static func == (a: AXKey, b: AXKey) -> Bool { CFEqual(a.el, b.el) }
    func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
}

extension AXUIElement {
    func attr(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }

    func string(_ name: String) -> String? { attr(name) as? String }

    func element(_ name: String) -> AXUIElement? {
        guard let v = attr(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] { attr(name) as? [AXUIElement] ?? [] }

    // One round trip for many attributes. Each AX call is an IPC to the app, so on a
    // big Chrome page this is the difference between a second and ten.
    func values(_ names: [String]) -> [String: AnyObject] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let list = out as? [AnyObject] else { return [:] }
        var d: [String: AnyObject] = [:]
        for (i, v) in list.enumerated() where i < names.count {
            // Missing attributes come back as an AXValue holding an error.
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { continue }
            d[names[i]] = v
        }
        return d
    }

    // Top-left origin, in points, across all displays: the same space CGEvent uses.
    var frame: CGRect? {
        let v = values([kAXPositionAttribute, kAXSizeAttribute])
        guard let p = v[kAXPositionAttribute], let s = v[kAXSizeAttribute] else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    var actions: [String] {
        var a: CFArray?
        AXUIElementCopyActionNames(self, &a)
        return a as? [String] ?? []
    }

    @discardableResult func perform(_ action: String) -> AXError { AXUIElementPerformAction(self, action as CFString) }

    @discardableResult func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    var windowID: CGWindowID {
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(self, &id)
        return id
    }

    var isAlive: Bool { attr(kAXRoleAttribute) != nil }

    var isFocused: Bool { attr(kAXFocusedAttribute) as? Bool == true }

    // Whether keys sent to the app now would land here: see KeyFocus.
    var hasKeyFocus: Bool {
        KeyFocus.holds(target: self, appFocused: AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute),
                       targetSaysFocused: isFocused, parent: { $0.element(kAXParentAttribute) }, same: { CFEqual($0, $1) })
    }

    // Focus can take a moment to settle after a click, more so in web views.
    func waitForKeyFocus(_ seconds: Double = 0.6) -> Bool {
        for _ in 0..<max(1, Int(seconds / 0.05)) {
            if hasKeyFocus { return true }
            usleep(50_000)
        }
        return hasKeyFocus
    }

    // Unlike cmd+a, which is a menu shortcut and only fires in the active app.
    func selectAllText() -> Bool {
        var all = CFRange(location: 0, length: (string(kAXValueAttribute) ?? "").utf16.count)
        guard let range = AXValueCreate(.cfRange, &all), set(kAXSelectedTextRangeAttribute, range) == .success else { return false }
        var now = CFRange()
        guard let v = attr(kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cfRange, &now) else { return false }
        return now.length == all.length
    }

    // Whether a field shows this text within half a second. Fields that won't say what's in
    // them (some web ones), and text with line breaks in it, get the benefit of the doubt.
    func waitForText(_ text: String) -> Bool {
        if text.contains(where: \.isNewline) { return true }
        for _ in 0..<10 {
            guard let now = string(kAXValueAttribute) else { return true }
            if now == text { return true }
            usleep(50_000)
        }
        return false
    }
}

// What has an app's keyboard focus, for saying where keys would have gone instead.
func focusedSummary(pid: pid_t) -> String {
    guard let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) else { return "nothing it will name" }
    let label = [f.string(kAXTitleAttribute), f.string(kAXDescriptionAttribute), f.string(kAXPlaceholderValueAttribute)]
        .compactMap { $0 }.first { !$0.isEmpty }
    let role = f.string(kAXRoleDescriptionAttribute) ?? f.string(kAXRoleAttribute) ?? "an element"
    return label.map { "\(role) \"\(clip($0, 40))\"" } ?? role
}

func clip(_ s: String, _ max: Int = 80) -> String {
    let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return t.count > max ? String(t.prefix(max - 1)) + "…" : t
}

// Values whose names look like secrets are masked, as in BrowserBear.
let secretName = try! NSRegularExpression(pattern: "pass(word|code)?|secret|token|api.?key|cvc|cvv|card.?number|one.?time|otp", options: .caseInsensitive)

func looksSecret(_ s: String) -> Bool {
    secretName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}
