// Matches a key combo like "cmd+shift+g" against a menu item's shortcut, as Accessibility
// describes it. macOS only fires shortcuts in the active app, but the menu item behind one
// can be pressed from the background, so this is how `press` keeps windows behind.
public struct MenuShortcut: Equatable {
    // AXMenuItemCmdModifiers bits. Command is on unless the no-command bit says otherwise.
    public static let shift = 1, option = 2, control = 4, noCommand = 8

    public let key: String
    public let keyCode: Int
    public let modifiers: Int

    // nil for combos no menu would have: plain keys, and shift alone (that's just typing).
    public init?(key: String, keyCode: Int, cmd: Bool, shift: Bool, option: Bool, control: Bool) {
        guard cmd || option || control else { return nil }
        self.key = key.lowercased()
        self.keyCode = keyCode
        modifiers = (cmd ? 0 : Self.noCommand) | (shift ? Self.shift : 0) | (option ? Self.option : 0) | (control ? Self.control : 0)
    }

    // An item's shortcut is a character (cmd+N) or, for keys with no character (cmd+delete,
    // cmd+up), a virtual key code. A missing modifiers value means plain command.
    public func matches(char: String?, modifiers itemModifiers: Int?, virtualKey: Int?) -> Bool {
        guard (itemModifiers ?? 0) == modifiers else { return false }
        if let char, !char.isEmpty, char != "\u{0}" {
            return key.count == 1 && char.lowercased() == key
        }
        if let virtualKey { return virtualKey == keyCode }
        return false
    }
}
