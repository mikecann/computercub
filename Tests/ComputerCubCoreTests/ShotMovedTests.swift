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

final class ScrollColumnTests: XCTestCase {
    // A header button over a list: the button's own box stays still, so the whole column
    // under it is what's watched, and a small list lower down in it still counts.
    func testAHeaderButtonWatchesTheListBelowIt() {
        let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
        let button = CGRect(x: 200, y: 120, width: 40, height: 20)
        let part = PictureChange.column(of: button, in: window)
        XCTAssertEqual(part.minY, 0)
        XCTAssertEqual(part.height, 1)
        XCTAssertEqual(part.width, 0.125, accuracy: 0.0001)
        let width = 256, height = 170
        let before = [UInt8](repeating: 30, count: width * height)
        var after = before
        // The list scrolls: 200×100 points, below the button, in a 1200×800 window.
        for y in 30..<51 { for x in 22..<64 { after[y * width + x] = (x + y) % 2 == 0 ? 220 : 30 } }
        XCTAssertFalse(PictureChange.moved(before, after, width: width))
        XCTAssertTrue(PictureChange.moved(before, after, width: width, part: part))
    }

    func testAColumnAtTheEdgeStaysInThePicture() {
        let part = PictureChange.column(of: CGRect(x: 1290, y: 500, width: 10, height: 10), in: CGRect(x: 100, y: 100, width: 1200, height: 800))
        XCTAssertLessThanOrEqual(part.maxX, 1.0001)
    }
}

final class ScrollBandTests: XCTestCase {
    // Row buttons that look alike in a gutter: their column stays still as the list moves
    // by whole rows, but the labels beside them, in the same band, change.
    func testAGutterButtonWatchesTheLabelsBesideIt() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let button = CGRect(x: 470, y: 400, width: 20, height: 20)
        let width = 256, height = 170
        let before = [UInt8](repeating: 30, count: width * height)
        var after = before
        // Labels at x 110–280, y 360–460 change; nothing in the button's column does.
        for y in 77..<98 { for x in 23..<60 { after[y * width + x] = (x + y) % 2 == 0 ? 220 : 30 } }
        XCTAssertFalse(PictureChange.moved(before, after, width: width))
        XCTAssertFalse(PictureChange.moved(before, after, width: width, part: PictureChange.column(of: button, in: window)))
        XCTAssertTrue(PictureChange.moved(before, after, width: width, part: PictureChange.band(of: button, in: window)))
    }
}
