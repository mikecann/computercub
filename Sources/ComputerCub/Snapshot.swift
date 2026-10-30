import AppKit
import ApplicationServices

// Turns a window's accessibility tree into a short list an agent can act on, the same
// shape as BrowserBear:
//
//   [toolbar]
//   e4 button "Back" [disabled]
//   e7 searchbox "Search" = "invoices"
//   e9 row "Downloads" [selected]
//   [page "Developer Dashboard" https://chrome.google.com/webstore/devconsole]
//   ## Items
//   e31 link "BrowserBear"
//
// Only things you can act on, plus headings and the containers that change what's
// clickable (sheets, dialogs, menus, the web page) make the cut.
enum Snapshot {
    static let fields = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXChildrenAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXExpandedAttribute,
        "AXPlaceholderValue", kAXHelpAttribute,
    ]

    static let roles: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXTextField": "textbox",
        "AXTextArea": "textbox", "AXSecureTextField": "password", "AXComboBox": "combobox", "AXPopUpButton": "popup",
        "AXMenuButton": "menubutton", "AXLink": "link", "AXSlider": "slider", "AXIncrementor": "stepper",
        "AXStepper": "stepper", "AXMenuItem": "menuitem", "AXMenuBarItem": "menu", "AXDisclosureTriangle": "disclosure",
        "AXColorWell": "colorwell", "AXDateField": "date", "AXTimeField": "time", "AXRow": "row", "AXDockItem": "item",
    ]
    static let subroles: [String: String] = [
        "AXSwitch": "switch", "AXToggle": "toggle", "AXSearchField": "searchbox", "AXSecureTextField": "password",
        "AXTabButton": "tab",
    ]
    // Leaves for our purposes: nothing inside them is worth listing on its own.
    static let skip: Set<String> = [
        "AXStaticText", "AXImage", "AXScrollBar", "AXValueIndicator", "AXGrowArea", "AXColumn", "AXSplitter",
        "AXRuler", "AXMatte", "AXBusyIndicator", "AXProgressIndicator", "AXLevelIndicator",
    ]
    // The traffic lights have no names of their own.
    static let windowButtons = [
        "AXCloseButton": "Close window", "AXMinimizeButton": "Minimise", "AXZoomButton": "Zoom", "AXFullScreenButton": "Full screen",
    ]
    static let textRoles: Set<String> = ["textbox", "searchbox", "combobox", "popup", "slider", "stepper", "date", "time", "colorwell"]
    static let onOff: Set<String> = ["checkbox", "radio", "switch", "toggle"]
    static let maxRows = 40

    final class Walker {
        let win: Win
        let desk: Desktop
        let all: Bool
        var lines: [String] = []
        var signatures: [String: String] = [:]
        var visited = 0
        var emptyWebArea = false
        var sawWebArea = false
        var truncated = false
        let deadline = Date().addingTimeInterval(6)

        init(_ win: Win, _ desk: Desktop, all: Bool) {
            self.win = win
            self.desk = desk
            self.all = all
        }

        // inWeb: inside a web page, where rows and cells are layout, not things to pick.
        // inRow: inside a native list row, whose text already went into the row's name.
        // inDialog: inside a sheet, dialog or alert, where the words matter ("Delete 3 items?").
        func walk(_ el: AXUIElement, depth: Int, inWeb: Bool, inRow: Bool, inDialog: Bool) {
            if visited >= 8000 || depth > 120 || Date() > deadline {
                truncated = true
                return
            }
            visited += 1
            let v = el.values(Snapshot.fields)
            let role = v[kAXRoleAttribute] as? String ?? ""
            let sub = v[kAXSubroleAttribute] as? String
            let kids = v[kAXChildrenAttribute] as? [AXUIElement] ?? []
            var inWeb = inWeb, inDialog = inDialog

            if role == "AXStaticText" {
                if inDialog, !inRow, let s = v[kAXValueAttribute] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("\"\(clip(s, 160))\"")
                }
                return
            }
            if Snapshot.skip.contains(role) { return }

            if let landmark = landmark(role, sub, v, el) {
                lines.append(landmark)
                if role == "AXWebArea" {
                    inWeb = true
                    sawWebArea = true
                    if kids.isEmpty { emptyWebArea = true }
                }
                if role != "AXWebArea", role != "AXToolbar", role != "AXMenu" { inDialog = true }
            } else if role == "AXHeading" {
                let name = name(el, v, kids, gather: true)
                if !name.isEmpty {
                    let level = (v[kAXValueAttribute] as? NSNumber)?.intValue ?? 2
                    lines.append("\(String(repeating: "#", count: min(max(level, 1), 6))) \(name)")
                }
                return
            } else if var kind = Snapshot.subroles[sub ?? ""] ?? Snapshot.roles[role] {
                if inWeb && (role == "AXRow") { kind = "" }
                // A row's text is already in its name, and Finder gives every folder row its own
                // unnamed disclosure triangle (Right arrow opens it anyway).
                if inRow && (kind == "textbox" || kind == "row" || kind == "disclosure") { kind = "" }
                if !kind.isEmpty {
                    let l = line(kind, el, v, kids)
                    // Unnamed rows are spacers between sidebar sections.
                    if kind == "row" && !l.contains("\"") { return }
                    lines.append(l)
                    // Only containers that can hold a menu or list need walking further.
                    if kind != "row" && kind != "popup" && kind != "menubutton" && kind != "combobox" && kind != "menu" { return }
                    if kind == "row" {
                        walkKids(kids, depth: depth, inWeb: inWeb, inRow: true, inDialog: inDialog, role: role)
                        return
                    }
                }
            }
            walkKids(kids, depth: depth, inWeb: inWeb, inRow: inRow, inDialog: inDialog, role: role)
        }

        private func walkKids(_ kids: [AXUIElement], depth: Int, inWeb: Bool, inRow: Bool, inDialog: Bool, role: String) {
            // Long native lists (a Finder folder, a log) would swamp everything else.
            let listy = !inWeb && !all && (role == "AXOutline" || role == "AXTable" || role == "AXList")
            for (i, k) in kids.enumerated() {
                if listy && i >= Snapshot.maxRows {
                    lines.append("… \(kids.count - i) more (snap --all shows them)")
                    return
                }
                walk(k, depth: depth + 1, inWeb: inWeb, inRow: inRow, inDialog: inDialog)
            }
        }

        private func landmark(_ role: String, _ sub: String?, _ v: [String: AnyObject], _ el: AXUIElement) -> String? {
            let title = clip(v[kAXTitleAttribute] as? String ?? v[kAXDescriptionAttribute] as? String ?? "")
            let named = { (kind: String) in title.isEmpty ? "[\(kind)]" : "[\(kind) \"\(title)\"]" }
            switch (role, sub ?? "") {
            case ("AXWebArea", _):
                var s = named("page")
                if let url = el.attr("AXURL") as? URL { s.removeLast(); s += " \(clip(url.absoluteString, 120))]" }
                return s
            case ("AXSheet", _): return named("sheet")
            case ("AXPopover", _): return named("popover")
            case ("AXMenu", _): return "[menu]"
            case ("AXToolbar", _): return "[toolbar]"
            case (_, "AXApplicationDialog"), (_, "AXApplicationAlertDialog"), (_, "AXDialog"), (_, "AXSystemDialog"):
                return named("dialog")
            case (_, "AXApplicationAlert"): return named("alert")
            default: return nil
            }
        }

        private func line(_ kind: String, _ el: AXUIElement, _ v: [String: AnyObject], _ kids: [AXUIElement]) -> String {
            let name = name(el, v, kids, gather: kind == "row" || kind == "link" || kind == "button" || kind == "tab" || kind == "item")
            let signature = "\(kind) \"\(name)\""
            let ref = desk.ref(for: el, in: win, signature: name.isEmpty ? nil : signature)
            if !name.isEmpty { signatures[signature] = ref }
            var s = "\(ref) \(kind)"
            if !name.isEmpty { s += " \"\(name)\"" }
            var flags: [String] = []
            let value = v[kAXValueAttribute]
            if Snapshot.onOff.contains(kind) || kind == "tab" || kind == "disclosure" {
                switch (value as? NSNumber)?.intValue {
                case 1: flags.append(kind == "tab" ? "selected" : kind == "disclosure" ? "expanded" : "checked")
                case 2: flags.append("mixed")
                default: break
                }
            } else if kind == "password" {
                if let s0 = value as? String, !s0.isEmpty { s += " = \"••••\"" }
            } else if Snapshot.textRoles.contains(kind), let value {
                let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
                if !text.isEmpty && text != name {
                    s += looksSecret(name) ? " = \"••••\"" : " = \"\(clip(text))\""
                } else if text.isEmpty, let p = v["AXPlaceholderValue"] as? String, !p.isEmpty, p != name {
                    s += " (\(clip(p, 40)))"
                }
            }
            if (v[kAXEnabledAttribute] as? Bool) == false { flags.append("disabled") }
            if (v[kAXSelectedAttribute] as? Bool) == true, !flags.contains("selected") { flags.append("selected") }
            if (v[kAXExpandedAttribute] as? Bool) == true, !flags.contains("expanded") { flags.append("expanded") }
            if (v[kAXFocusedAttribute] as? Bool) == true { flags.append("focused") }
            if !flags.isEmpty { s += " [\(flags.joined(separator: ", "))]" }
            return s
        }

        private func name(_ el: AXUIElement, _ v: [String: AnyObject], _ kids: [AXUIElement], gather: Bool) -> String {
            if let sub = v[kAXSubroleAttribute] as? String, let n = Snapshot.windowButtons[sub] { return n }
            for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let s = v[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return clip(s) }
            }
            if let label = el.element("AXTitleUIElement"),
               let s = label.string(kAXValueAttribute) ?? label.string(kAXTitleAttribute), !s.isEmpty {
                return clip(s)
            }
            if gather {
                var parts: [String] = []
                gatherText(kids, into: &parts, depth: 0)
                if !parts.isEmpty { return clip(parts.joined(separator: " · ")) }
            }
            if let s = v[kAXHelpAttribute] as? String, !s.isEmpty { return clip(s) }
            return ""
        }

        private func gatherText(_ els: [AXUIElement], into parts: inout [String], depth: Int) {
            var icons: [String] = []
            gatherText(els, into: &parts, icons: &icons, depth: depth)
            // Icon names ("Arrow Down Circle") are only worth it when there's no text at all.
            if parts.isEmpty { parts = Array(icons.prefix(2)) }
        }

        private func gatherText(_ els: [AXUIElement], into parts: inout [String], icons: inout [String], depth: Int) {
            guard depth < 4 else { return }
            for el in els where parts.count < 3 {
                let v = el.values([kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
                let role = v[kAXRoleAttribute] as? String ?? ""
                if role == "AXStaticText" || role == "AXTextField" {
                    if let s = (v[kAXValueAttribute] as? String) ?? (v[kAXTitleAttribute] as? String), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                        parts.append(clip(s, 50))
                    }
                } else if role == "AXImage" {
                    if let s = v[kAXDescriptionAttribute] as? String, !s.isEmpty { icons.append(clip(s, 30)) }
                } else {
                    gatherText(v[kAXChildrenAttribute] as? [AXUIElement] ?? [], into: &parts, icons: &icons, depth: depth + 1)
                }
            }
        }
    }

    static func lines(_ win: Win, _ desk: Desktop, all: Bool = false) -> [String] {
        let justTurnedOn = desk.ensureWeb(win.app)
        var w = Walker(win, desk, all: all)
        w.walk(win.el, depth: 0, inWeb: false, inRow: false, inDialog: false)
        // Chrome builds the page's tree a moment after it's asked for; wait for it once.
        let pageMissing = w.emptyWebArea || (Desktop.isChromium(win.app) && !w.sawWebArea)
        if pageMissing && (justTurnedOn || desk.tryEnhancedWeb(win.app)) {
            for _ in 0..<6 where w.emptyWebArea || !w.sawWebArea {
                usleep(500_000)
                w = Walker(win, desk, all: all)
                w.walk(win.el, depth: 0, inWeb: false, inRow: false, inDialog: false)
            }
        }
        desk.signatures[win.id] = w.signatures
        var out = w.lines
        if w.truncated { out.append("… stopped after \(w.visited) elements; `computercub read` or a narrower window helps") }
        return out
    }

    // The cheaper of a diff against the last look and the full list, as in BrowserBear.
    static func diff(_ before: [String]?, _ after: [String]) -> (full: Bool, text: String) {
        guard let before else { return (true, after.joined(separator: "\n")) }
        let was = Set(before), now = Set(after)
        let added = after.filter { !was.contains($0) }
        let removed = before.filter { !now.contains($0) }
        if added.isEmpty && removed.isEmpty { return (false, "(no change)") }
        let text = (removed.map { "- \($0)" } + added.map { "+ \($0)" }).joined(separator: "\n")
        let whole = after.joined(separator: "\n")
        // A navigation changes nearly everything; then the plain list is shorter.
        if text.count >= whole.count { return (true, whole) }
        return (false, "\(text)\n(\(after.count - added.count) unchanged)")
    }
}
