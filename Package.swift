// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpiceSee",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpiceKit", targets: ["SpiceKit"]),
    ],
    targets: [
        .target(name: "SpiceWire"),
        .target(name: "SpiceCore", dependencies: ["SpiceWire"]),
        .target(name: "SpiceCanvas", dependencies: ["SpiceWire"]),
        .target(name: "SpiceKit", dependencies: ["SpiceCore", "SpiceCanvas"]),
        .testTarget(name: "SpiceWireTests", dependencies: ["SpiceWire"]),
        .testTarget(name: "SpiceCoreTests", dependencies: ["SpiceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
