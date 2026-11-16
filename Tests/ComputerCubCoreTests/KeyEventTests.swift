import CoreGraphics
import XCTest
@testable import ComputerCubCore

// Events built from the system's state pick up any modifier it thinks is held, and once
// that was a cmd stuck down with nobody at the keyboard. These hand the builders events
// that already carry a held cmd, so they test that case whatever the machine's state.
final class KeyEventTests: XCTestCase {
    let src = CGEventSource(stateID: .hidSystemState)

    // What a .hidSystemState event looked like with cmd stuck: cmd plus NonCoalesced.
    func contaminated(_ code: CGKeyCode = 0) throws -> CGEvent {
        let e = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true))
        e.flags = [.maskCommand, .maskControl, CGEventFlags(rawValue: 0x2000_0000)]
        return e
    }

    func testTypedTextDropsHeldModifiersAndKeepsTheRest() throws {
        let e = KeyEvent.text("é", on: try contaminated())
        XCTAssertEqual(e.flags.intersection(.modifiers), [])
        XCTAssertEqual(e.flags.rawValue & 0x2000_0000, 0x2000_0000)
        XCTAssertEqual(e.getIntegerValueField(.keyboardEventKeycode), 0)
        var units = [UniChar](repeating: 0, count: 4)
        var n = 0
        e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &units)
        XCTAssertEqual(String(utf16CodeUnits: units, count: n), "é")
    }

    func testTypedTextFromTheSourceCarriesNoModifiers() throws {
        for down in [true, false] {
            XCTAssertEqual(try XCTUnwrap(KeyEvent.text("a", down: down, source: src)).flags.intersection(.modifiers), [])
        }
    }

    func testKeysCarryExactlyTheirModifiers() throws {
        XCTAssertEqual(try XCTUnwrap(KeyEvent.key(9, down: true, flags: .maskCommand, source: src)).flags, .maskCommand)
        XCTAssertEqual(try XCTUnwrap(KeyEvent.key(36, down: false, source: src)).flags, [])
    }

    func testClearingModifiersOnAMouseEvent() throws {
        let e = try XCTUnwrap(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        e.flags = [.maskCommand, .maskShift, CGEventFlags(rawValue: 0x2000_0000)]
        e.clearModifiers()
        XCTAssertEqual(e.flags.rawValue, 0x2000_0000)
    }
}
