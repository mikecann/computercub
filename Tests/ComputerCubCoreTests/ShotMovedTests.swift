import XCTest
@testable import ComputerCubCore

final class ShotMovedTests: XCTestCase {
    // A small list scrolling in a big still window: too little of the whole picture
    // changes to count, but its own spot clearly did.
    func testASmallPaneCountsWhenLookedAtOnItsOwn() {
        let width = 64, height = 40
        let before = [UInt8](repeating: 30, count: width * height)
        var after = before
        for y in 10..<12 { for x in 10..<14 { after[y * width + x] = 200 } }
        XCTAssertFalse(PictureChange.moved(before, after, width: width))
        let part = CGRect(x: 10.0 / 64, y: 10.0 / 40, width: 4.0 / 64, height: 2.0 / 40)
        XCTAssertTrue(PictureChange.moved(before, after, width: width, part: part))
    }

    func testAStillSpotDoesNotCount() {
        let width = 64
        let before = [UInt8](repeating: 30, count: width * 40)
        var after = before
        after[0] = 200
        XCTAssertFalse(PictureChange.moved(before, after, width: width, part: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)))
    }
}
