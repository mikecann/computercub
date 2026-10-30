import AppKit
import ApplicationServices

// Private, but it's been stable since 10.6 and every window manager uses it (Rectangle,
// AltTab, Peekaboo). It's the only way from an AX window to the CGWindowID that
// ScreenCaptureKit wants, and the id is what keeps window refs stable.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct ClickyError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
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
}

func clip(_ s: String, _ max: Int = 80) -> String {
    let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return t.count > max ? String(t.prefix(max - 1)) + "…" : t
}

// Values whose names look like secrets are masked, as in Paws.
let secretName = try! NSRegularExpression(pattern: "pass(word|code)?|secret|token|api.?key|cvc|cvv|card.?number|one.?time|otp", options: .caseInsensitive)

func looksSecret(_ s: String) -> Bool {
    secretName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}
