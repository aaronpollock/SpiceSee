// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpiceSee",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpiceKit", targets: ["SpiceKit"]),
        .executable(name: "spicerec", targets: ["spicerec"]),
        .executable(name: "spicesee-cli", targets: ["spicesee-cli"]),
    ],
    // The LGPL codecs live in their own package so they link as a dylib rather than being absorbed
    // into SpiceCanvas — see Packages/CSpiceCodec/Package.swift.
    dependencies: [.package(path: "Packages/CSpiceCodec")],
    targets: [
        .target(name: "SpiceWire"),
        .target(name: "SpiceCore", dependencies: ["SpiceWire"]),
        .target(name: "SpiceCanvas", dependencies: ["SpiceWire", .product(name: "CSpiceCodec", package: "CSpiceCodec")]),
        .target(name: "SpiceKit", dependencies: ["SpiceCore", "SpiceCanvas", "SpiceMedia"]),
        .target(name: "SpiceMedia", dependencies: ["SpiceWire"]),
        .executableTarget(name: "spicerec"),
        .executableTarget(name: "spicesee-cli", dependencies: ["SpiceKit", "SpiceCanvas", "SpiceCore", "SpiceWire", "SpiceMedia"]),
        .testTarget(name: "SpiceWireTests", dependencies: ["SpiceWire"]),
        .testTarget(name: "SpiceCoreTests", dependencies: ["SpiceCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SpiceCanvasTests", dependencies: ["SpiceCanvas", .product(name: "CSpiceCodec", package: "CSpiceCodec")]),
        .testTarget(name: "SpiceKitTests", dependencies: ["SpiceKit", "SpiceCore", "SpiceCanvas", "SpiceMedia"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SpiceMediaTests", dependencies: ["SpiceMedia", "SpiceWire"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
