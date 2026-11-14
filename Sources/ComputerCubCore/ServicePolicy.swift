public struct ServicePolicy {
    public let isPrivate: Bool
    public let allowsSetup: Bool
    public var allowsRestart: Bool { !isPrivate }

    public init(environment: [String: String]) {
        // Privacy and lifecycle rules must survive detached or symlinked executables.
        isPrivate = environment["COMPUTERCUB_HOME"] != nil
        allowsSetup = !isPrivate || environment["COMPUTERCUB_DEV_SETUP"] == "1"
    }
}
