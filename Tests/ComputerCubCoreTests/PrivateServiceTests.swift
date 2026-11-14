import Foundation
import XCTest
@testable import ComputerCubCore

final class PrivateServiceTests: XCTestCase {
    private let bundledApp = URL(fileURLWithPath: "/fixtures/ComputerCub.app")

    private final class Session {
        var replies: [ClientReply?]
        var calls: [[String]] = []
        var apps: [URL?] = []
        var localCalls: [[String]] = []
        var restarts: [URL] = []

        init(_ replies: [ClientReply?] = []) { self.replies = replies }

        func run(_ args: [String], isPrivate: Bool = true, app: URL?) -> ClientReply? {
            ClientSession.run(
                ClientArguments(args), isPrivate: isPrivate, app: app,
                call: { args, app in
                    self.calls.append(args)
                    self.apps.append(app)
                    return self.replies.isEmpty ? nil : self.replies.removeFirst()
                }, local: { args in
                    self.localCalls.append(args)
                    return ClientReply(ok: true, out: "local")
                }, restart: { app in self.restarts.append(app) }
            )
        }
    }

    func testPrivateMissingSocketCannotLaunchABundledAppOrFallBack() {
        let session = Session([nil])
        XCTAssertNil(session.run(["doctor"], app: bundledApp))
        XCTAssertEqual(session.calls, [["doctor"]])
        XCTAssertEqual(session.apps.count, 1)
        XCTAssertNil(session.apps[0], "nil is what prevents Client.call from launching an app")
        XCTAssertTrue(session.localCalls.isEmpty)
        XCTAssertTrue(session.restarts.isEmpty)
    }

    func testPrivateBundledPermissionDenialCannotRestartOrReplay() {
        let session = Session([ClientReply(ok: false, out: "denied", restart: true)])
        let reply = session.run(["shot", "w1"], app: bundledApp)
        XCTAssertEqual(reply?.out, "denied")
        XCTAssertEqual(session.calls, [["shot", "w1"]])
        XCTAssertNil(session.apps[0])
        XCTAssertTrue(session.restarts.isEmpty)
        XCTAssertTrue(session.localCalls.isEmpty)
    }

    func testPrivateUnbundledReplyUsesTheSameRouting() {
        let session = Session([ClientReply(ok: true, out: "private")])
        XCTAssertEqual(session.run(["doctor"], app: nil)?.out, "private")
        XCTAssertEqual(session.calls, [["doctor"]])
        XCTAssertNil(session.apps[0])
        XCTAssertTrue(session.localCalls.isEmpty)
    }

    func testInstalledBundledClientKeepsItsOneRestartAndRetry() {
        let session = Session([
            ClientReply(ok: false, out: "restart needed", restart: true),
            ClientReply(ok: true, out: "ready"),
        ])
        XCTAssertEqual(session.run(["shot", "w1"], isPrivate: false, app: bundledApp)?.out, "ready")
        XCTAssertEqual(session.apps, [bundledApp, bundledApp])
        XCTAssertEqual(session.calls, [["shot", "w1"], ["shot", "w1"]])
        XCTAssertEqual(session.restarts, [bundledApp])
        XCTAssertTrue(session.localCalls.isEmpty)
    }

    func testInstalledInitialFailureDoesNotReplay() {
        let session = Session([nil])
        XCTAssertNil(session.run(["doctor"], isPrivate: false, app: bundledApp))
        XCTAssertEqual(session.apps, [bundledApp])
        XCTAssertTrue(session.restarts.isEmpty)
    }

    func testUnbundledNonPrivateClientStillRunsLocally() {
        let session = Session()
        XCTAssertEqual(session.run(["doctor"], isPrivate: false, app: nil)?.out, "local")
        XCTAssertEqual(session.localCalls, [["doctor"]])
        XCTAssertTrue(session.calls.isEmpty)
    }

    func testLocalTextCannotSelectLocalExecution() {
        let session = Session([ClientReply(ok: true, out: "sent")])
        XCTAssertEqual(session.run(["type", "w1", "--local"], app: bundledApp)?.out, "sent")
        XCTAssertEqual(session.calls, [["type", "w1", "--local"]])
        XCTAssertTrue(session.localCalls.isEmpty)
        let arguments = CommandArguments(["w1", "--local"])
        XCTAssertEqual(arguments.pos, ["w1", "--local"])
        XCTAssertFalse(arguments.has("local"))
    }

    func testFlagValueCannotSelectLocalExecution() {
        let session = Session([ClientReply(ok: true, out: "sent")])
        _ = session.run(["snap", "w1", "--find", "--local"], app: bundledApp)
        XCTAssertEqual(session.calls, [["snap", "w1", "--find", "--local"]])
        XCTAssertTrue(session.localCalls.isEmpty)
        let arguments = CommandArguments(["w1", "--find", "--local", "--all"])
        XCTAssertEqual(arguments.flags["find"], "--local")
        XCTAssertTrue(arguments.has("all"))
    }

    func testLeadingLocalOptionRemovesOnlyItself() {
        let session = Session()
        _ = session.run(["--local", "type", "w1", "--local"], app: bundledApp)
        XCTAssertEqual(session.localCalls, [["type", "w1", "--local"]])
        XCTAssertTrue(session.calls.isEmpty)
    }

    func testEndOfOptionsPreservesLiteralFlags() {
        let arguments = CommandArguments(["w1", "--", "--submit", "--local"])
        XCTAssertEqual(arguments.pos, ["w1", "--submit", "--local"])
        XCTAssertTrue(arguments.flags.isEmpty)
    }

    func testPrivateSetupDefaultsToClosedWithoutAnyBundleLookup() {
        // The policy has no executable-path input, so detached copies and symlinks
        // cannot change it. Empty but present private homes must fail closed too.
        for home in ["/tmp/cub.test", ""] {
            let policy = ServicePolicy(environment: ["COMPUTERCUB_HOME": home])
            XCTAssertTrue(policy.isPrivate)
            XCTAssertFalse(policy.allowsSetup)
            XCTAssertFalse(policy.allowsRestart)
        }
    }

    func testExplicitDevSetupCannotEnableALaunchServicesRestart() {
        let policy = ServicePolicy(environment: [
            "COMPUTERCUB_HOME": "/tmp/cub.dev", "COMPUTERCUB_DEV_SETUP": "1",
        ])
        XCTAssertTrue(policy.allowsSetup)
        XCTAssertFalse(policy.allowsRestart)
        XCTAssertFalse(ServicePolicy(environment: [
            "COMPUTERCUB_HOME": "/tmp/cub.dev", "COMPUTERCUB_DEV_SETUP": "true",
        ]).allowsSetup)
    }

    func testInstalledSetupAndRestartRemainAvailable() {
        let policy = ServicePolicy(environment: [:])
        XCTAssertFalse(policy.isPrivate)
        XCTAssertTrue(policy.allowsSetup)
        XCTAssertTrue(policy.allowsRestart)
    }
}
