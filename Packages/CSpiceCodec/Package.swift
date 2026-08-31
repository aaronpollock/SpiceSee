// swift-tools-version: 6.0
import PackageDescription

// A package of its own so that the codec reaches the app only as a dynamic library. A same-package
// dependency on the target absorbs the objects into whatever links it, and the LGPL-2.1 §6(b)
// substitution promise needs the vendored code in a separately replaceable binary.
let package = Package(
    name: "CSpiceCodec",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CSpiceCodec", type: .dynamic, targets: ["CSpiceCodec"]),
    ],
    targets: [
        .target(name: "CSpiceCodec",
                // The *_tmpl.c files are #included by quic.c/lz.c/decode-glz.c with macros predefined;
                // they are not translation units and must not be compiled on their own.
                exclude: ["vendor/common/quic_family_tmpl.c", "vendor/common/quic_tmpl.c",
                          "vendor/common/lz_compress_tmpl.c", "vendor/common/lz_decompress_tmpl.c",
                          "vendor/decode-glz-tmpl.c", "VENDORED.md", "LICENSE.LGPL-2.1"],
                cSettings: [.headerSearchPath("vendor"), .headerSearchPath("vendor/common"), .headerSearchPath("shim")]),
    ]
)
