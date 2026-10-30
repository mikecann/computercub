import XCTest
@testable import ComputerCubCore

final class SetupTests: XCTestCase {
    func testCompleteNeedsBoth() {
        XCTAssertTrue(SetupState(accessibility: .granted, screenRecording: .granted).isComplete)
        XCTAssertFalse(SetupState(accessibility: .granted, screenRecording: .missing).isComplete)
        XCTAssertFalse(SetupState(accessibility: .missing, screenRecording: .granted).isComplete)
    }

    func testReadyOnceAccessibilityIsOn() {
        XCTAssertTrue(SetupState(accessibility: .granted, screenRecording: .missing).isReady)
        XCTAssertFalse(SetupState(accessibility: .missing, screenRecording: .granted).isReady)
    }

    func testOpensAtLaunchWhenAnythingIsMissing() {
        XCTAssertTrue(SetupState(accessibility: .missing, screenRecording: .granted).opensAtLaunch(skippedScreenRecording: false))
        XCTAssertTrue(SetupState(accessibility: .granted, screenRecording: .missing).opensAtLaunch(skippedScreenRecording: false))
        XCTAssertFalse(SetupState(accessibility: .granted, screenRecording: .granted).opensAtLaunch(skippedScreenRecording: false))
    }

    func testLaterOnScreenRecordingStopsTheNagging() {
        // Screenshots are optional, so once Mike says Later it stays closed for that alone.
        XCTAssertFalse(SetupState(accessibility: .granted, screenRecording: .missing).opensAtLaunch(skippedScreenRecording: true))
        // But Accessibility is needed for everything, so it still opens for that.
        XCTAssertTrue(SetupState(accessibility: .missing, screenRecording: .missing).opensAtLaunch(skippedScreenRecording: true))
    }

    func testHeadlines() {
        XCTAssertEqual(SetupState(accessibility: .granted, screenRecording: .granted).headline, "ComputerCub is all set")
        XCTAssertEqual(SetupState(accessibility: .granted, screenRecording: .missing).headline, "ComputerCub is ready")
        XCTAssertEqual(SetupState(accessibility: .missing, screenRecording: .missing).headline, "Let ComputerCub use your Mac")
    }
}
