import XCTest
@testable import ComputerCubCore

final class MenuShortcutTests: XCTestCase {
    func combo(_ key: String, code: Int = 0, cmd: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) -> MenuShortcut? {
        MenuShortcut(key: key, keyCode: code, cmd: cmd, shift: shift, option: option, control: control)
    }

    func testPlainKeysAndShiftAloneArentShortcuts() {
        XCTAssertNil(combo("return", cmd: false))
        XCTAssertNil(combo("a", cmd: false, shift: true))
        XCTAssertNotNil(combo("f", cmd: false, control: true))
    }

    func testMatchesTheItemsCharacterAndModifiers() {
        // Finder's Go to Folder: "G" with shift, command implied.
        let goTo = combo("g", shift: true)!
        XCTAssertTrue(goTo.matches(char: "G", modifiers: 1, virtualKey: nil))
        XCTAssertFalse(goTo.matches(char: "G", modifiers: 0, virtualKey: nil))  // that's cmd+g
        XCTAssertFalse(goTo.matches(char: "H", modifiers: 1, virtualKey: nil))
        // An app that leaves modifiers out means plain command.
        XCTAssertTrue(combo("n")!.matches(char: "N", modifiers: nil, virtualKey: nil))
        XCTAssertTrue(combo(",")!.matches(char: ",", modifiers: 0, virtualKey: nil))
    }

    func testCommandlessItemsCarryTheNoCommandBit() {
        let ctrlF = combo("f", cmd: false, control: true)!
        XCTAssertTrue(ctrlF.matches(char: "F", modifiers: MenuShortcut.control | MenuShortcut.noCommand, virtualKey: nil))
        XCTAssertFalse(ctrlF.matches(char: "F", modifiers: MenuShortcut.control, virtualKey: nil))
    }

    func testKeysWithoutACharacterMatchByKeyCode() {
        let trash = combo("delete", code: 51)!
        XCTAssertTrue(trash.matches(char: "", modifiers: 0, virtualKey: 51))
        XCTAssertTrue(trash.matches(char: "\u{0}", modifiers: 0, virtualKey: 51))
        XCTAssertFalse(trash.matches(char: nil, modifiers: 0, virtualKey: 117))
        XCTAssertFalse(trash.matches(char: nil, modifiers: 0, virtualKey: nil))
    }
}
