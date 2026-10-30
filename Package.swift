// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComputerCub",
    platforms: [.macOS(.v14)],
    products: [
        // The command agents run is `computercub`; the module needs a name without a hyphen.
        .executable(name: "computercub", targets: ["ComputerCub"])
    ],
    targets: [
        // The setup window's state, kept apart from AppKit so it can be tested.
        .target(name: "ComputerCubCore"),
        .executableTarget(name: "ComputerCub", dependencies: ["ComputerCubCore"]),
        .testTarget(name: "ComputerCubCoreTests", dependencies: ["ComputerCubCore"]),
    ],
    // Swift 5 mode: the AX and CoreGraphics APIs are all C, and strict concurrency adds noise without catching anything here.
    swiftLanguageModes: [.v5]
)
