import Foundation

/// Where one of ComputerCub's permissions stands, for the setup window.
public enum PermissionState: Equatable, Sendable {
    case granted
    /// Not asked yet, or not switched on yet.
    case missing
}

/// The permissions ComputerCub needs, as the setup window shows them.
public struct SetupState: Equatable, Sendable {
    /// Accessibility: reading windows and pressing things. Nothing works without it.
    public var accessibility: PermissionState
    /// Screen Recording: only for `computercub shot`.
    public var screenRecording: PermissionState

    public init(accessibility: PermissionState, screenRecording: PermissionState) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    /// Both are on.
    public var isComplete: Bool { accessibility == .granted && screenRecording == .granted }

    /// Agents can use it: everything but screenshots works.
    public var isReady: Bool { accessibility == .granted }

    /// Whether the window should open by itself when the app starts. It does when
    /// anything's missing, except when the only thing missing is Screen Recording and
    /// Mike has already said Later to it: screenshots are optional, so no nagging.
    public func opensAtLaunch(skippedScreenRecording: Bool) -> Bool {
        if accessibility != .granted { return true }
        return screenRecording != .granted && !skippedScreenRecording
    }

    public var headline: String {
        isComplete ? "ComputerCub is all set" : isReady ? "ComputerCub is ready" : "Let ComputerCub use your Mac"
    }

    public var subline: String {
        isComplete ? "You can close this."
            : isReady ? "Turn on Screen Recording too if you want screenshots."
            : "Each one turns green once it's on."
    }
}
