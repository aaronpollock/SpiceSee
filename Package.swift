// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpiceSee",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpiceKit", targets: ["SpiceKit"]),
        // Dynamic so a user can substitute their own build of the LGPL codecs (LGPL-2.1 §6(b)).
        .library(name: "CSpiceCodec", type: .dynamic, targets: ["CSpiceCodec"]),
        .executable(name: "spicerec", targets: ["spicerec"]),
        .executable(name: "spicesee-cli", targets: ["spicesee-cli"]),
    ],
    targets: [
        .target(name: "CSpiceCodec",
                // The *_tmpl.c files are #included by quic.c/lz.c/decode-glz.c with macros predefined;
                // they are not translation units and must not be compiled on their own.
                exclude: ["vendor/common/quic_family_tmpl.c", "vendor/common/quic_tmpl.c",
                          "vendor/common/lz_compress_tmpl.c", "vendor/common/lz_decompress_tmpl.c",
                          "vendor/decode-glz-tmpl.c", "VENDORED.md", "LICENSE.LGPL-2.1"],
                cSettings: [.headerSearchPath("vendor"), .headerSearchPath("vendor/common"), .headerSearchPath("shim")]),
        .target(name: "SpiceWire"),
        .target(name: "SpiceCore", dependencies: ["SpiceWire"]),
        .target(name: "SpiceCanvas", dependencies: ["SpiceWire", "CSpiceCodec"]),
        .target(name: "SpiceKit", dependencies: ["SpiceCore", "SpiceCanvas"]),
        .executableTarget(name: "spicerec"),
        .executableTarget(name: "spicesee-cli", dependencies: ["SpiceCore", "SpiceWire"]),
        .testTarget(name: "SpiceWireTests", dependencies: ["SpiceWire"]),
        .testTarget(name: "SpiceCoreTests", dependencies: ["SpiceCore"]),
        .testTarget(name: "SpiceCanvasTests", dependencies: ["SpiceCanvas", "CSpiceCodec"]),
    ],
    swiftLanguageModes: [.v6]
)
