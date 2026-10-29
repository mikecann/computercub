// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mitts",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "mitts")
    ],
    // Swift 5 mode: the AX and CoreGraphics APIs are all C, and strict concurrency adds noise without catching anything here.
    swiftLanguageModes: [.v5]
)
