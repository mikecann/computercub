import CoreGraphics

// Key events that carry exactly the modifiers we ask for. An event made from a
// .hidSystemState source starts out with whatever modifiers the window server thinks are
// held, and that can be stale: with a Command stuck down in that state (nobody at the
// keyboard), `type --keys` sent every character as cmd+character, TextEdit took them as
// shortcuts, and the field stayed empty while a paste (which sets its flags) went in fine.
public enum KeyEvent {
    // Exactly these flags, as key() has always sent and iPhone Mirroring is happy with.
    public static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], source: CGEventSource?) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        e.flags = flags
        return e
    }

    // A character as text on virtual key 0, for apps that read the text an event carries.
    // No modifiers: the text already says the case, and shift on key 0 is shift+a to an app
    // that looks at the key.
    public static func text(_ ch: Character, down: Bool, source: CGEventSource?) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return nil }
        return text(ch, on: e)
    }

    // Split out so tests can hand it an event that already carries a held cmd.
    static func text(_ ch: Character, on e: CGEvent) -> CGEvent {
        e.clearModifiers()  // the rest of the source's flags stay, as they did before this went wrong
        let units = Array(String(ch).utf16)
        e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return e
    }
}

public extension CGEventFlags {
    // A real keyboard also says which modifier key is down, left or right, in the low bits
    // (NX_DEVICELCMDKEYMASK and friends). Screen Sharing reads those, not the plain flags:
    // shift+p with only maskShift arrived on the other Mac as "p", and with these as "P".
    // These are the left-hand keys', as Input.modifiers presses.
    var withLeftKeys: CGEventFlags {
        var raw = rawValue
        if contains(.maskControl) { raw |= 0x1 }
        if contains(.maskShift) { raw |= 0x2 }
        if contains(.maskCommand) { raw |= 0x8 }
        if contains(.maskAlternate) { raw |= 0x20 }
        return CGEventFlags(rawValue: raw)
    }

    static let modifiers: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
                                          .maskSecondaryFn, .maskHelp, .maskNumericPad]
}

public extension CGEvent {
    // Drops the held-modifier bits (and caps lock) but keeps the rest the source set, such
    // as NonCoalesced, so the event is otherwise what it was. maskNumericPad is in there
    // too: it says which keypad the key is on, and a stale one from the source is meaningless.
    func clearModifiers() { flags.subtract(.modifiers) }
}
