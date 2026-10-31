import XCTest
@testable import ComputerCubCore

final class ShotMapTests: XCTestCase {
    func testRetinaPixelsBecomeWindowPoints() {
        let map = ShotMap(origin: .zero, scale: 2, size: CGSize(width: 800, height: 600), windowSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(map.point(x: 100, y: 50), CGPoint(x: 50, y: 25))
    }

    func testACroppedShotStartsAtTheElement() {
        let map = ShotMap(origin: CGPoint(x: 30, y: 40), scale: 2, size: CGSize(width: 100, height: 60), windowSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(map.point(x: 10, y: 20), CGPoint(x: 35, y: 50))
    }

    func testOutsideThePictureOrWindowIsNoticed() {
        let map = ShotMap(origin: CGPoint(x: -20, y: 0), scale: 1, size: CGSize(width: 100, height: 100), windowSize: CGSize(width: 50, height: 50))
        XCTAssertFalse(map.inPicture(x: 100, y: 10))
        XCTAssertFalse(map.inPicture(x: -1, y: 10))
        XCTAssertTrue(map.inPicture(x: 10, y: 10))
        // In the picture, over an open menu hanging off the window's left edge.
        XCTAssertFalse(map.inWindow(map.point(x: 10, y: 10)))
        XCTAssertTrue(map.inWindow(map.point(x: 30, y: 10)))
    }

    func testOnlyAResizeMakesAShotStale() {
        let map = ShotMap(origin: .zero, scale: 2, size: CGSize(width: 800, height: 600), windowSize: CGSize(width: 400, height: 300))
        XCTAssertFalse(map.stale(windowSize: CGSize(width: 400.5, height: 300)))
        XCTAssertTrue(map.stale(windowSize: CGSize(width: 500, height: 300)))
    }
}
