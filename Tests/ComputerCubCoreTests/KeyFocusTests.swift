import XCTest
@testable import ComputerCubCore

final class KeyFocusTests: XCTestCase {
    // A Slack-like window: the thread's reply box with a paragraph inside, and the
    // channel's message box beside it.
    let parents: [String: String] = [
        "reply": "thread", "reply.p": "reply", "thread": "window",
        "composer": "channel", "channel": "window",
    ]

    func holds(_ target: String, focused: String?, saysFocused: Bool = false) -> Bool {
        KeyFocus.holds(target: target, appFocused: focused, targetSaysFocused: saysFocused,
                       parent: { self.parents[$0] }, same: ==)
    }

    func testFocusOnTheTargetOrInsideItHolds() {
        XCTAssertTrue(holds("reply", focused: "reply"))
        XCTAssertTrue(holds("reply", focused: "reply.p"))
    }

    // The Slack miss: the reply box said it was focused, but the app's focus was elsewhere,
    // so the keys would have gone in as shortcuts.
    func testTheAppsFocusElsewhereWinsOverTheTargetsOwnClaim() {
        XCTAssertFalse(holds("reply", focused: "composer", saysFocused: true))
        XCTAssertFalse(holds("reply", focused: "window", saysFocused: true))
    }

    // Focus on a container around the target isn't focus on the target.
    func testFocusOnAnAncestorDoesntHold() {
        XCTAssertFalse(holds("reply.p", focused: "reply"))
    }

    func testWithNoAppFocusTheTargetsOwnAttributeDecides() {
        XCTAssertTrue(holds("reply", focused: nil, saysFocused: true))
        XCTAssertFalse(holds("reply", focused: nil, saysFocused: false))
    }

    func testALoopingTreeEnds() {
        let loop = ["a": "b", "b": "a"]
        XCTAssertFalse(KeyFocus.holds(target: "c", appFocused: "a", targetSaysFocused: true,
                                      parent: { loop[$0] }, same: ==))
    }
}
