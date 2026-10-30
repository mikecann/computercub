import XCTest
@testable import ComputerCubCore

final class ScreenLockTests: XCTestCase {
    func testTheKeyOnlySaysLockedWhenItIsSet() {
        // CGSessionCopyCurrentDictionary gives a CFBoolean or a number, depending on the OS.
        XCTAssertTrue(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": 1]))
        XCTAssertFalse(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(ScreenLock.isLocked(session: ["kCGSSessionOnConsoleKey": true]))
        XCTAssertFalse(ScreenLock.isLocked(session: nil))
    }
}
