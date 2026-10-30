// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MrClicky",
    platforms: [.macOS(.v14)],
    products: [
        // The command agents run is `mr-clicky`; the module needs a name without a hyphen.
        .executable(name: "mr-clicky", targets: ["MrClicky"])
    ],
    targets: [
        .executableTarget(name: "MrClicky")
    ],
    // Swift 5 mode: the AX and CoreGraphics APIs are all C, and strict concurrency adds noise without catching anything here.
    swiftLanguageModes: [.v5]
)
