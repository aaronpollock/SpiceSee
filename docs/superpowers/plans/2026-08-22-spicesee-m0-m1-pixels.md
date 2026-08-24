# SpiceSee M0–M1 (Pixels) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A plain QEMU desktop renders in a macOS window — link handshake, main + display channels, tier-1 draws, QUIC/LZ/GLZ decode, Metal present — with the whole stack below the app testable headless from recorded bytes.

**Architecture:** Single SPM package. `SpiceWire` (pure value types, bounds-checked reader) → `SpiceCore` (transport, handshake, channel actors over a `ByteSource` abstraction so recordings replay identically to sockets) → `SpiceCanvas` (BGRA surfaces, image cache, codec routing into vendored C) → `SpiceKit` facade → thin app. Dependencies strictly downward.

**Tech Stack:** Swift 6.2 strict concurrency, Swift Testing, Network.framework, Security.framework (RSA-OAEP), Metal/CAMetalLayer, ImageIO, Compression.framework, vendored `quic.c`/`lz.c`/`decode-glz.c` (LGPL-2.1+), xcodegen for the app project.

**Spec:** `docs/superpowers/specs/2026-08-22-spicesee-design.md` — this plan implements §2, §3 (minus TLS/`.vv`/migration), §4 tier 1 + codecs, §7 replay tests, and milestones M0–M1. Later plans (write each after the previous ships):

| Plan | Spec sections | Milestone |
|---|---|---|
| `…-m2-input.md` | §6 keyboard, mouse, cursor channel | M2 |
| `…-m3-proxmox.md` | §3 TLS verify block, `.vv` parsing, document type, migration prompt | M3 |
| `…-m4-canvas-complete.md` | §4 tiers 2–3, all draw ops, streams → VideoToolbox, STREAM_REPORT | M4 |
| `…-m5-agent.md` | §5 vdagent, clipboard, monitors config, multi-window viewports | M5 |
| `…-m6-audio.md` | §5 Opus playback | M6 |
| `…-m7-ship.md` | §6 connection manager/prefs, §8 signing, Sparkle, cask | M7 |

## Global Constraints

- Swift 6 language mode, strict concurrency. No locks, no `@unchecked Sendable`.
- `platforms: [.macOS(.v14)]`. Universal binary (arm64 + x86_64) — never add arch-specific code.
- `SpiceWire` is the security boundary: every reader accessor throws; a malformed message must never trap. No `!` unwraps, no unchecked subscripts on wire data.
- `SpiceCanvas` imports nothing from `SpiceCore`. `SpiceCore` never touches pixels.
- Only vendored C is `Sources/CSpiceCodec` (decode-only codecs, LGPL-2.1+). It builds as a **dynamic** library product. No OpenSSL, no glib, no pixman.
- Capabilities advertised: common `AUTH_SPICE`, `MINI_HEADER`; display `MJPEG`, `H264` (decoders land in M4, but caps are set once here so recordings match). Never advertise `VP8`/`VP9`.
- Tests use Swift Testing (`import Testing`). Fixtures live in `Tests/<Target>Tests/Fixtures/`.
- Commit after every task. Conventional-commit prefixes: `feat:`, `test:`, `build:`, `chore:`.
- Library code logs via `os.Logger(subsystem: "com.spicesee", category: "<module>")`. No `print` outside executables.

## File Structure

```
Package.swift
project.yml                               xcodegen spec for the app bundle (Task 17)
scripts/dev-server.sh                     starts the dev SPICE server (Task 12)
Sources/
  CSpiceCodec/
    include/spice_codec.h                 our C API (the only header Swift sees)
    codec_bridge.c                        wraps quic/lz/glz behind spice_codec.h
    shim/spice_shim.h                     replaces glib/spice-common macros
    vendor/ quic.c quic_family_tmpl.c quic_rgb_tmpl.c quic_tmpl.c quic.h quic_config.h
            lz.c lz.h lz_common.h lz_config.h lz_decompress_tmpl.c lz_compress_tmpl.c
            decode-glz.c decode-glz-tmpl.c glz_decoder.h  (+ spice-protocol draw.h, types.h, macros.h)
  SpiceWire/
    WireError.swift       SpiceReader.swift     SpiceWriter.swift
    Constants.swift       channel types, message ids, capability bits, ROPD bits
    Link.swift            SpiceLinkHeader / LinkMess / LinkReply / LinkResult
    DataHeader.swift      full (18 B) and mini (6 B) headers
    Geometry.swift        SpicePoint, SpiceRect, SpiceClip, SpiceQMask, SpiceBrush
    Image.swift           SpiceImageDescriptor + SpiceImage payload enum
    MainMessages.swift    MainInit, ChannelsList, MouseMode, MultiMediaTime, AgentToken…
    CommonMessages.swift  SetAck, Ping, Notify, Disconnecting
    DisplayMessages.swift SurfaceCreate/Destroy, DrawBase, Fill, Copy, Opaque, Blend…
    ClientMessages.swift  AckSync, Pong, AttachChannels, DisplayInit encoders
  SpiceCore/
    SpiceError.swift
    ByteSource.swift      protocol ByteSource/ByteSink + InMemoryByteSource + RecordingSink
    NWTransport.swift     NWConnection-backed ByteSource+ByteSink (TCP; TLS in M3)
    Ticket.swift          RSA-OAEP-SHA1 ticket encryption
    LinkHandshake.swift   performs link + auth, returns negotiated caps
    ChannelReader.swift   header loop → AsyncStream<RawMessage>; auto SET_ACK/PING
    MainChannel.swift     actor: MAIN_INIT, CHANNELS_LIST
    DisplayChannel.swift  actor: DISPLAY_INIT, forwards display messages
  SpiceCanvas/
    Surface.swift         aligned BGRA buffer + dirty-rect accumulation
    ImageCache.swift      id → decoded image
    DecodedImage.swift    width/height/stride/BGRA bytes
    ImageDecoder.swift    codec routing → DecodedImage (uses CSpiceCodec, ImageIO, Compression)
    Tier1.swift           copy / fill / blackness / whiteness / invers / copy_bits scanline ops
    Canvas.swift          applies DisplayMessage to surfaces; owns cache + GLZ window
  SpiceKit/
    SpiceSession.swift    facade: connect → main → display channels → surface updates
  spicesee-cli/main.swift connect + print MAIN_INIT (M0 exit) / dump surface PNG
  spicerec/main.swift     recording TCP proxy
  SpiceSee/ (app, Task 17–18)
    SpiceSeeApp.swift  ConnectView.swift  SessionWindow.swift  MetalSurfaceView.swift
Tests/
  SpiceWireTests/ SpiceCoreTests/ SpiceCanvasTests/ SpiceKitTests/ (+ Fixtures/)
```

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`, `.gitignore`, one placeholder source per target, `Tests/SpiceWireTests/SmokeTests.swift`

**Interfaces:**
- Produces: module names `SpiceWire`, `SpiceCore`, `SpiceCanvas`, `SpiceKit`, `CSpiceCodec`, executables `spicerec`, `spicesee-cli`.

- [x] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpiceSee",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpiceKit", targets: ["SpiceKit"]),
        .library(name: "CSpiceCodec", type: .dynamic, targets: ["CSpiceCodec"]),
        .executable(name: "spicerec", targets: ["spicerec"]),
        .executable(name: "spicesee-cli", targets: ["spicesee-cli"]),
    ],
    targets: [
        .target(name: "CSpiceCodec",
                cSettings: [.headerSearchPath("vendor"), .headerSearchPath("shim")]),
        .target(name: "SpiceWire"),
        .target(name: "SpiceCore", dependencies: ["SpiceWire"]),
        .target(name: "SpiceCanvas", dependencies: ["SpiceWire", "CSpiceCodec"]),
        .target(name: "SpiceKit", dependencies: ["SpiceCore", "SpiceCanvas"]),
        .executableTarget(name: "spicerec"),
        .executableTarget(name: "spicesee-cli", dependencies: ["SpiceKit"]),
        .testTarget(name: "SpiceWireTests", dependencies: ["SpiceWire"]),
        .testTarget(name: "SpiceCoreTests", dependencies: ["SpiceCore"]),
        .testTarget(name: "SpiceCanvasTests", dependencies: ["SpiceCanvas"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SpiceKitTests", dependencies: ["SpiceKit"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
```

- [x] **Step 2: Create placeholders so every target compiles**

```bash
mkdir -p Sources/{CSpiceCodec/include,CSpiceCodec/shim,CSpiceCodec/vendor,SpiceWire,SpiceCore,SpiceCanvas,SpiceKit,spicerec,spicesee-cli}
mkdir -p Tests/{SpiceWireTests,SpiceCoreTests,SpiceCanvasTests/Fixtures,SpiceKitTests/Fixtures}
touch Tests/SpiceCanvasTests/Fixtures/.keep Tests/SpiceKitTests/Fixtures/.keep
cat > Sources/CSpiceCodec/include/spice_codec.h <<'EOF'
#ifndef SPICE_CODEC_H
#define SPICE_CODEC_H
#include <stdint.h>
#include <stddef.h>
int sc_version(void);
#endif
EOF
cat > Sources/CSpiceCodec/codec_bridge.c <<'EOF'
#include "spice_codec.h"
int sc_version(void) { return 1; }
EOF
for m in SpiceWire SpiceCore SpiceCanvas SpiceKit; do echo "// $m" > Sources/$m/$m.swift; done
echo 'print("spicerec")' > Sources/spicerec/main.swift
echo 'print("spicesee-cli")' > Sources/spicesee-cli/main.swift
printf '.build/\n*.xcodeproj\nDerivedData/\n.DS_Store\n' > .gitignore
```

- [x] **Step 3: Write smoke test**

`Tests/SpiceWireTests/SmokeTests.swift`:
```swift
import Testing
@testable import SpiceWire

@Test func packageBuilds() { #expect(true) }
```

- [x] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: `Build complete`, `Test run with 1 test passed`.

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "build: SPM scaffold with module layout"
```

---

### Task 2: SpiceReader / SpiceWriter

**Files:**
- Create: `Sources/SpiceWire/WireError.swift`, `Sources/SpiceWire/SpiceReader.swift`, `Sources/SpiceWire/SpiceWriter.swift`
- Test: `Tests/SpiceWireTests/SpiceReaderTests.swift`
- Delete: `Sources/SpiceWire/SpiceWire.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum WireError: Error, Equatable, Sendable {
      case truncated(needed: Int, available: Int)
      case badOffset(Int)
      case badValue(field: String, value: UInt64)
      case unsupported(String)
  }
  public struct SpiceReader: Sendable {
      public init(_ bytes: [UInt8])
      public var offset: Int { get }
      public var remaining: Int { get }
      public var count: Int { get }
      public mutating func u8() throws -> UInt8
      public mutating func u16() throws -> UInt16
      public mutating func u32() throws -> UInt32
      public mutating func u64() throws -> UInt64
      public mutating func i32() throws -> Int32
      public mutating func bytes(_ n: Int) throws -> [UInt8]
      public mutating func skip(_ n: Int) throws
      public func reader(at offset: UInt32) throws -> SpiceReader   // for wire "pointer" fields; offset relative to this reader's base
  }
  public struct SpiceWriter: Sendable {
      public init()
      public var bytes: [UInt8] { get }
      public mutating func u8(_:UInt8) / u16(_:UInt16) / u32(_:UInt32) / u64(_:UInt64) / i32(_:Int32) / bytes(_:[UInt8])
      public mutating func patchU32(at: Int, _ value: UInt32)   // fill a size field after the fact
  }
  ```

- [x] **Step 1: Write failing tests**

```swift
import Testing
@testable import SpiceWire

@Test func readsLittleEndianScalars() throws {
    var r = SpiceReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
    #expect(try r.u8() == 0x01)
    #expect(try r.u16() == 0x0302)
    #expect(try r.u32() == 0x07060504)
    #expect(try r.u64() == 0x0F0E0D0C0B0A0908)
    #expect(r.remaining == 0)
}

@Test func truncatedReadThrowsNotTraps() {
    var r = SpiceReader([0x01, 0x02])
    #expect(throws: WireError.truncated(needed: 4, available: 2)) { try r.u32() }
    #expect(r.offset == 0)  // failed read does not advance
}

@Test func pointerReaderIsRelativeToBase() throws {
    var r = SpiceReader([0xAA, 0xBB, 0x42, 0x00, 0x00, 0x00])
    _ = try r.u16()
    var sub = try r.reader(at: 2)
    #expect(try sub.u32() == 0x42)
    #expect(throws: WireError.badOffset(7)) { _ = try r.reader(at: 7) }
}

@Test func writerRoundTrips() throws {
    var w = SpiceWriter()
    w.u8(1); w.u16(0x0302); w.u32(0x07060504); w.u64(0x0F0E0D0C0B0A0908); w.i32(-1)
    w.patchU32(at: 3, 0xDEADBEEF)
    var r = SpiceReader(w.bytes)
    #expect(try r.u8() == 1)
    #expect(try r.u16() == 0x0302)
    #expect(try r.u32() == 0xDEADBEEF)
    #expect(try r.u64() == 0x0F0E0D0C0B0A0908)
    #expect(try r.i32() == -1)
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter SpiceWireTests`
Expected: compile error `cannot find 'SpiceReader'`.

- [x] **Step 3: Implement**

`WireError.swift`:
```swift
public enum WireError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case badOffset(Int)
    case badValue(field: String, value: UInt64)
    case unsupported(String)
}
```

`SpiceReader.swift`:
```swift
public struct SpiceReader: Sendable {
    private let storage: [UInt8]
    private let base: Int
    public private(set) var offset: Int

    public init(_ bytes: [UInt8]) { storage = bytes; base = 0; offset = 0 }
    private init(storage: [UInt8], base: Int) { self.storage = storage; self.base = base; offset = base }

    public var count: Int { storage.count - base }
    public var remaining: Int { storage.count - offset }

    private mutating func load<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { throw WireError.truncated(needed: n, available: remaining) }
        let v = storage.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += n
        return T(littleEndian: v)
    }
    public mutating func u8() throws -> UInt8 { try load(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try load(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try load(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try load(UInt64.self) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try load(UInt32.self)) }

    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw WireError.truncated(needed: n, available: remaining) }
        defer { offset += n }
        return Array(storage[offset ..< offset + n])
    }
    public mutating func skip(_ n: Int) throws { _ = try bytes(n) }

    /// A reader positioned at `offset` bytes from this reader's base (SPICE pointer fields).
    public func reader(at pointer: UInt32) throws -> SpiceReader {
        let abs = base + Int(pointer)
        guard abs <= storage.count else { throw WireError.badOffset(Int(pointer)) }
        return SpiceReader(storage: storage, base: abs)
    }
}
```

`SpiceWriter.swift`:
```swift
public struct SpiceWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    private mutating func store<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }
    public mutating func u8(_ v: UInt8) { store(v) }
    public mutating func u16(_ v: UInt16) { store(v) }
    public mutating func u32(_ v: UInt32) { store(v) }
    public mutating func u64(_ v: UInt64) { store(v) }
    public mutating func i32(_ v: Int32) { store(v) }
    public mutating func bytes(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func patchU32(at index: Int, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { src in
            for i in 0 ..< 4 { bytes[index + i] = src[i] }
        }
    }
}
```

- [x] **Step 4: Run tests**

Run: `swift test --filter SpiceWireTests`
Expected: 5 tests pass.

- [x] **Step 5: Commit**

```bash
git rm -q Sources/SpiceWire/SpiceWire.swift
git add -A && git commit -m "feat(wire): bounds-checked SpiceReader and SpiceWriter"
```

---

### Task 3: Wire constants and link messages

**Files:**
- Create: `Sources/SpiceWire/Constants.swift`, `Sources/SpiceWire/Link.swift`
- Test: `Tests/SpiceWireTests/LinkTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ChannelType: UInt8, Sendable { case main = 1, display = 2, inputs = 3, cursor = 4, playback = 5, record = 6, tunnel = 7, smartcard = 8, usbredir = 9, port = 10, webdav = 11 }
  public enum CommonCap { public static let protocolAuthSelection: UInt32 = 0, authSpice = 1, authSasl = 2, miniHeader = 3 }
  public enum DisplayCap { sizedStream = 0, monitorsConfig = 1, composite = 2, a8Surface = 3, streamReport = 4, lz4 = 5, prefCompression = 6, glScanout = 7, multiCodec = 8, codecMjpeg = 9, codecVp8 = 10, codecH264 = 11, prefVideoCodecType = 12, codecVp9 = 13, codecH265 = 14 }
  public struct CapabilitySet: Sendable, Equatable { public init(bits: [UInt32]); public init(); public mutating func set(_ bit: UInt32); public func contains(_ bit: UInt32) -> Bool; public var words: [UInt32] }
  public enum LinkError: UInt32, Sendable { case ok = 0, error, invalidMagic, invalidData, versionMismatch, needSecured, needUnsecured, permissionDenied, badConnectionID, channelNotAvailable }
  public struct SpiceLinkMess: Sendable { connectionID: UInt32, channelType: ChannelType, channelID: UInt8, commonCaps: CapabilitySet, channelCaps: CapabilitySet; func encode() -> [UInt8]  /* header + mess */ }
  public struct SpiceLinkReply: Sendable, Equatable { error: LinkError, publicKey: [UInt8] /*162*/, commonCaps: CapabilitySet, channelCaps: CapabilitySet; init(reader: inout SpiceReader) throws; static func parseHeader(_ r: inout SpiceReader) throws -> Int /* returns payload size */ }
  public enum Link { static let magic: UInt32 = 0x51444552; static let major: UInt32 = 2; static let minor: UInt32 = 2; static let ticketPubkeyBytes = 162; static let ticketBytes = 128; static let maxPasswordLength = 60 }
  ```

- [x] **Step 1: Write failing tests**

```swift
import Testing
@testable import SpiceWire

@Test func linkMessEncodesHeaderAndCaps() throws {
    var common = CapabilitySet(); common.set(CommonCap.authSpice); common.set(CommonCap.miniHeader)
    let mess = SpiceLinkMess(connectionID: 0, channelType: .main, channelID: 0,
                             commonCaps: common, channelCaps: CapabilitySet())
    let bytes = mess.encode()
    var r = SpiceReader(bytes)
    #expect(try r.u32() == 0x51444552)          // "REDQ"
    #expect(try r.u32() == 2)                   // major
    #expect(try r.u32() == 2)                   // minor
    #expect(try r.u32() == UInt32(bytes.count - 16)) // size of link mess
    #expect(try r.u32() == 0)                   // connection id
    #expect(try r.u8() == 1)                    // main
    #expect(try r.u8() == 0)
    #expect(try r.u32() == 1)                   // num common caps
    #expect(try r.u32() == 0)                   // num channel caps
    #expect(try r.u32() == 18)                  // caps offset
    #expect(try r.u32() == (1 << 1) | (1 << 3))
    #expect(r.remaining == 0)
}

@Test func linkReplyParses() throws {
    var w = SpiceWriter()
    w.u32(0x51444552); w.u32(2); w.u32(2); w.u32(0) // header; size patched below
    let start = w.bytes.count
    w.u32(0)                                   // error ok
    w.bytes([UInt8](repeating: 0xAB, count: 162))
    w.u32(1); w.u32(1); w.u32(178)             // num common, num channel, caps offset
    w.u32(0b1011); w.u32(1 << 9)               // common caps, display caps (MJPEG)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    var r = SpiceReader(w.bytes)
    let size = try SpiceLinkReply.parseHeader(&r)
    #expect(size == 186)
    let reply = try SpiceLinkReply(reader: &r)
    #expect(reply.error == .ok)
    #expect(reply.publicKey.count == 162)
    #expect(reply.commonCaps.contains(CommonCap.miniHeader))
    #expect(reply.channelCaps.contains(DisplayCap.codecMjpeg))
}

@Test func linkReplyRejectsBadMagic() {
    var r = SpiceReader([0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0])
    #expect(throws: WireError.badValue(field: "magic", value: 0)) { _ = try SpiceLinkReply.parseHeader(&r) }
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter LinkTests`
Expected: compile errors for missing types.

- [x] **Step 3: Implement**

`Constants.swift`:
```swift
public enum ChannelType: UInt8, Sendable {
    case main = 1, display = 2, inputs = 3, cursor = 4, playback = 5, record = 6
    case tunnel = 7, smartcard = 8, usbredir = 9, port = 10, webdav = 11
}

public enum CommonCap {
    public static let protocolAuthSelection: UInt32 = 0
    public static let authSpice: UInt32 = 1
    public static let authSasl: UInt32 = 2
    public static let miniHeader: UInt32 = 3
}

public enum DisplayCap {
    public static let sizedStream: UInt32 = 0, monitorsConfig: UInt32 = 1, composite: UInt32 = 2
    public static let a8Surface: UInt32 = 3, streamReport: UInt32 = 4, lz4: UInt32 = 5
    public static let prefCompression: UInt32 = 6, glScanout: UInt32 = 7, multiCodec: UInt32 = 8
    public static let codecMjpeg: UInt32 = 9, codecVp8: UInt32 = 10, codecH264: UInt32 = 11
    public static let prefVideoCodecType: UInt32 = 12, codecVp9: UInt32 = 13, codecH265: UInt32 = 14
}

public struct CapabilitySet: Sendable, Equatable {
    public private(set) var words: [UInt32]
    public init() { words = [] }
    public init(bits: [UInt32]) { words = []; bits.forEach { set($0) } }
    public init(words: [UInt32]) { self.words = words }
    public mutating func set(_ bit: UInt32) {
        let i = Int(bit / 32)
        while words.count <= i { words.append(0) }
        words[i] |= 1 << (bit % 32)
    }
    public func contains(_ bit: UInt32) -> Bool {
        let i = Int(bit / 32)
        return i < words.count && words[i] & (1 << (bit % 32)) != 0
    }
}

public enum Link {
    public static let magic: UInt32 = 0x51444552   // "REDQ" little-endian
    public static let major: UInt32 = 2
    public static let minor: UInt32 = 2
    public static let ticketPubkeyBytes = 162
    public static let ticketBytes = 128
    public static let maxPasswordLength = 60
}

public enum LinkError: UInt32, Sendable {
    case ok = 0, error, invalidMagic, invalidData, versionMismatch, needSecured
    case needUnsecured, permissionDenied, badConnectionID, channelNotAvailable
}
```

`Link.swift`:
```swift
public struct SpiceLinkMess: Sendable {
    public var connectionID: UInt32
    public var channelType: ChannelType
    public var channelID: UInt8
    public var commonCaps: CapabilitySet
    public var channelCaps: CapabilitySet

    public init(connectionID: UInt32, channelType: ChannelType, channelID: UInt8,
                commonCaps: CapabilitySet, channelCaps: CapabilitySet) {
        self.connectionID = connectionID; self.channelType = channelType; self.channelID = channelID
        self.commonCaps = commonCaps; self.channelCaps = channelCaps
    }

    /// SpiceLinkHeader + SpiceLinkMess + caps words.
    public func encode() -> [UInt8] {
        var w = SpiceWriter()
        w.u32(Link.magic); w.u32(Link.major); w.u32(Link.minor); w.u32(0)
        w.u32(connectionID)
        w.u8(channelType.rawValue); w.u8(channelID)
        w.u32(UInt32(commonCaps.words.count)); w.u32(UInt32(channelCaps.words.count))
        w.u32(18) // caps_offset: sizeof(SpiceLinkMess)
        commonCaps.words.forEach { w.u32($0) }
        channelCaps.words.forEach { w.u32($0) }
        w.patchU32(at: 12, UInt32(w.bytes.count - 16))
        return w.bytes
    }
}

public struct SpiceLinkReply: Sendable, Equatable {
    public var error: LinkError
    public var publicKey: [UInt8]
    public var commonCaps: CapabilitySet
    public var channelCaps: CapabilitySet

    /// Reads the 16-byte SpiceLinkHeader, returns the size of the reply body that follows.
    public static func parseHeader(_ r: inout SpiceReader) throws -> Int {
        let magic = try r.u32()
        guard magic == Link.magic else { throw WireError.badValue(field: "magic", value: UInt64(magic)) }
        let major = try r.u32()
        guard major == Link.major else { throw WireError.badValue(field: "major", value: UInt64(major)) }
        _ = try r.u32() // minor
        let size = try r.u32()
        guard size >= 178, size < 1 << 16 else { throw WireError.badValue(field: "size", value: UInt64(size)) }
        return Int(size)
    }

    /// Parses the reply body (reader positioned right after the header).
    public init(reader r: inout SpiceReader) throws {
        var body = try r.reader(at: UInt32(r.offset))
        let err = try body.u32()
        guard let e = LinkError(rawValue: err) else { throw WireError.badValue(field: "error", value: UInt64(err)) }
        error = e
        publicKey = try body.bytes(Link.ticketPubkeyBytes)
        let nCommon = try body.u32(), nChannel = try body.u32(), capsOffset = try body.u32()
        guard nCommon <= 16, nChannel <= 16 else { throw WireError.badValue(field: "num_caps", value: UInt64(nCommon)) }
        var caps = try body.reader(at: capsOffset)
        commonCaps = CapabilitySet(words: try (0 ..< nCommon).map { _ in try caps.u32() })
        channelCaps = CapabilitySet(words: try (0 ..< nChannel).map { _ in try caps.u32() })
        try r.skip(caps.offset - body.offset + (body.offset - r.offset))  // consume whole body
    }
}
```

> Note on the final `skip`: the body is `r`'s remaining bytes from its current offset; after parsing, advance `r` by the total consumed (`caps.offset` is absolute within the shared storage, so the expression reduces to `caps.offset - r.offset`). If that reads confusingly, replace with `try r.skip(caps.offset - r.offset)` — same value.

- [x] **Step 4: Run tests**

Run: `swift test --filter LinkTests`
Expected: 3 pass. (If `linkReplyParses` fails on `remaining`, fix the skip expression per the note.)

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(wire): channel types, capability sets, link handshake messages"
```

---

### Task 4: Data headers, common and main messages

**Files:**
- Create: `Sources/SpiceWire/DataHeader.swift`, `Sources/SpiceWire/CommonMessages.swift`, `Sources/SpiceWire/MainMessages.swift`, `Sources/SpiceWire/ClientMessages.swift`
- Test: `Tests/SpiceWireTests/MainMessageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct DataHeader: Sendable, Equatable { public var serial: UInt64 /* 0 for mini */; public var type: UInt16; public var size: UInt32; public var subList: UInt32
      public static let fullSize = 18, miniSize = 6
      public init(mini r: inout SpiceReader) throws; public init(full r: inout SpiceReader) throws
      public func encode(mini: Bool) -> [UInt8] }
  public enum CommonServerMsg: UInt16 { case migrate = 1, migrateData = 2, setAck = 3, ping = 4, waitForChannels = 5, disconnecting = 6, notify = 7, list = 8 }
  public enum CommonClientMsg: UInt16 { case ackSync = 1, ack = 2, pong = 3, migrateFlushMark = 4, migrateData = 5, disconnecting = 6 }
  public enum MainServerMsg: UInt16 { migrateBegin = 101, migrateCancel, `init`, channelsList, mouseMode, multiMediaTime, agentConnected, agentDisconnected, agentData, agentToken, migrateSwitchHost, migrateEnd, name, uuid, agentConnectedTokens, migrateBeginSeamless, migrateDstSeamlessAck, migrateDstSeamlessNack }
  public enum MainClientMsg: UInt16 { clientInfo = 101, migrateConnected, migrateConnectError, attachChannels, mouseModeRequest, agentStart, agentData, agentToken, migrateEnd, migrateDstDoSeamless }
  public struct SetAck: Sendable, Equatable { generation: UInt32; window: UInt32; init(reader:) throws }
  public struct Ping: Sendable, Equatable { id: UInt32; timestamp: UInt64; init(reader:) throws }
  public struct Notify: Sendable, Equatable { timestamp: UInt64; severity: UInt32; visibility: UInt32; what: UInt32; message: String; init(reader:) throws }
  public struct MainInit: Sendable, Equatable { sessionID, displayChannelsHint, supportedMouseModes, currentMouseMode, agentConnected, agentTokens, multiMediaTime, ramHint: UInt32; init(reader:) throws }
  public struct ChannelDescriptor: Sendable, Hashable { type: ChannelType; id: UInt8 }
  public struct ChannelsList: Sendable, Equatable { channels: [ChannelDescriptor]; init(reader:) throws }   // unknown channel types are skipped, not errors
  public struct MouseMode: Sendable, Equatable { supported: UInt32; current: UInt32; init(reader:) throws }
  public struct MultiMediaTime: Sendable, Equatable { time: UInt32; init(reader:) throws }
  public enum MainMessage: Sendable { case `init`(MainInit), channelsList(ChannelsList), mouseMode(MouseMode), multiMediaTime(MultiMediaTime), agentConnected, agentDisconnected(UInt32), agentData([UInt8]), agentToken(UInt32), agentConnectedTokens(UInt32), name(String), uuid([UInt8]), other(type: UInt16, payload: [UInt8])
      public init(type: UInt16, payload: [UInt8]) throws }
  public enum ClientMessage { static func ackSync(generation: UInt32) -> [UInt8]; static func ack() -> [UInt8]; static func pong(_ p: Ping) -> [UInt8]; static func attachChannels() -> [UInt8]; static func mouseModeRequest(_ mode: UInt32) -> [UInt8]
      /// Frames `payload` with a data header. Returns header+payload.
      static func frame(type: UInt16, payload: [UInt8], mini: Bool, serial: UInt64) -> [UInt8] }
  ```

- [x] **Step 1: Write failing tests**

```swift
import Testing
@testable import SpiceWire

@Test func miniAndFullHeadersRoundTrip() throws {
    let h = DataHeader(serial: 7, type: 103, size: 32, subList: 0)
    var mini = SpiceReader(h.encode(mini: true))
    #expect(try DataHeader(mini: &mini) == DataHeader(serial: 0, type: 103, size: 32, subList: 0))
    var full = SpiceReader(h.encode(mini: false))
    #expect(try DataHeader(full: &full) == h)
    #expect(h.encode(mini: true).count == 6)
    #expect(h.encode(mini: false).count == 18)
}

@Test func mainInitParses() throws {
    var w = SpiceWriter()
    [1, 2, 3, 2, 1, 10, 5000, 0].forEach { w.u32(UInt32($0)) }
    let m = try MainMessage(type: MainServerMsg.init.rawValue, payload: w.bytes)
    guard case let .init(i) = m else { Issue.record("wrong case"); return }
    #expect(i.sessionID == 1)
    #expect(i.displayChannelsHint == 2)
    #expect(i.currentMouseMode == 2)
    #expect(i.agentTokens == 10)
    #expect(i.multiMediaTime == 5000)
}

@Test func channelsListSkipsUnknownTypes() throws {
    var w = SpiceWriter()
    w.u32(3); w.u8(2); w.u8(0); w.u8(99); w.u8(0); w.u8(4); w.u8(0)
    let m = try MainMessage(type: MainServerMsg.channelsList.rawValue, payload: w.bytes)
    guard case let .channelsList(l) = m else { Issue.record("wrong case"); return }
    #expect(l.channels == [ChannelDescriptor(type: .display, id: 0), ChannelDescriptor(type: .cursor, id: 0)])
}

@Test func truncatedMainInitThrows() {
    #expect(throws: WireError.self) { _ = try MainMessage(type: MainServerMsg.init.rawValue, payload: [1, 2, 3]) }
}

@Test func pongEchoesPing() throws {
    let ping = Ping(id: 9, timestamp: 1234)
    var r = SpiceReader(ClientMessage.pong(ping))
    #expect(try r.u32() == 9)
    #expect(try r.u64() == 1234)
}

@Test func frameBuildsMiniHeader() throws {
    let f = ClientMessage.frame(type: 2, payload: [0xAA], mini: true, serial: 1)
    #expect(f == [2, 0, 1, 0, 0, 0, 0xAA])
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter MainMessageTests`
Expected: compile errors.

- [x] **Step 3: Implement**

`DataHeader.swift`:
```swift
public struct DataHeader: Sendable, Equatable {
    public var serial: UInt64
    public var type: UInt16
    public var size: UInt32
    public var subList: UInt32
    public static let fullSize = 18
    public static let miniSize = 6

    public init(serial: UInt64, type: UInt16, size: UInt32, subList: UInt32) {
        self.serial = serial; self.type = type; self.size = size; self.subList = subList
    }
    public init(mini r: inout SpiceReader) throws {
        serial = 0; type = try r.u16(); size = try r.u32(); subList = 0
    }
    public init(full r: inout SpiceReader) throws {
        serial = try r.u64(); type = try r.u16(); size = try r.u32(); subList = try r.u32()
    }
    public func encode(mini: Bool) -> [UInt8] {
        var w = SpiceWriter()
        if !mini { w.u64(serial) }
        w.u16(type); w.u32(size)
        if !mini { w.u32(subList) }
        return w.bytes
    }
}
```

`CommonMessages.swift`:
```swift
public enum CommonServerMsg: UInt16, Sendable {
    case migrate = 1, migrateData = 2, setAck = 3, ping = 4, waitForChannels = 5
    case disconnecting = 6, notify = 7, list = 8
}
public enum CommonClientMsg: UInt16, Sendable {
    case ackSync = 1, ack = 2, pong = 3, migrateFlushMark = 4, migrateData = 5, disconnecting = 6
}

public struct SetAck: Sendable, Equatable {
    public var generation: UInt32, window: UInt32
    public init(reader r: inout SpiceReader) throws { generation = try r.u32(); window = try r.u32() }
}

public struct Ping: Sendable, Equatable {
    public var id: UInt32, timestamp: UInt64
    public init(id: UInt32, timestamp: UInt64) { self.id = id; self.timestamp = timestamp }
    public init(reader r: inout SpiceReader) throws { id = try r.u32(); timestamp = try r.u64() }
}

public struct Notify: Sendable, Equatable {
    public var timestamp: UInt64, severity: UInt32, visibility: UInt32, what: UInt32, message: String
    public init(reader r: inout SpiceReader) throws {
        timestamp = try r.u64(); severity = try r.u32(); visibility = try r.u32(); what = try r.u32()
        let len = try r.u32()
        guard len < 1 << 16 else { throw WireError.badValue(field: "message_len", value: UInt64(len)) }
        message = String(decoding: try r.bytes(Int(len)), as: UTF8.self)
    }
}
```

`MainMessages.swift`:
```swift
public enum MainServerMsg: UInt16, Sendable {
    case migrateBegin = 101, migrateCancel, `init`, channelsList, mouseMode, multiMediaTime
    case agentConnected, agentDisconnected, agentData, agentToken, migrateSwitchHost, migrateEnd
    case name, uuid, agentConnectedTokens, migrateBeginSeamless, migrateDstSeamlessAck, migrateDstSeamlessNack
}
public enum MainClientMsg: UInt16, Sendable {
    case clientInfo = 101, migrateConnected, migrateConnectError, attachChannels, mouseModeRequest
    case agentStart, agentData, agentToken, migrateEnd, migrateDstDoSeamless
}

public struct MainInit: Sendable, Equatable {
    public var sessionID, displayChannelsHint, supportedMouseModes, currentMouseMode: UInt32
    public var agentConnected, agentTokens, multiMediaTime, ramHint: UInt32
    public init(reader r: inout SpiceReader) throws {
        sessionID = try r.u32(); displayChannelsHint = try r.u32()
        supportedMouseModes = try r.u32(); currentMouseMode = try r.u32()
        agentConnected = try r.u32(); agentTokens = try r.u32()
        multiMediaTime = try r.u32(); ramHint = try r.u32()
    }
}

public struct ChannelDescriptor: Sendable, Hashable {
    public var type: ChannelType, id: UInt8
    public init(type: ChannelType, id: UInt8) { self.type = type; self.id = id }
}

public struct ChannelsList: Sendable, Equatable {
    public var channels: [ChannelDescriptor]
    public init(reader r: inout SpiceReader) throws {
        let n = try r.u32()
        guard n <= 256 else { throw WireError.badValue(field: "num_of_channels", value: UInt64(n)) }
        channels = []
        for _ in 0 ..< n {
            let t = try r.u8(), id = try r.u8()
            if let type = ChannelType(rawValue: t) { channels.append(ChannelDescriptor(type: type, id: id)) }
        }
    }
}

public struct MouseMode: Sendable, Equatable {
    public var supported: UInt32, current: UInt32
    public init(reader r: inout SpiceReader) throws { supported = try r.u32(); current = try r.u32() }
}

public struct MultiMediaTime: Sendable, Equatable {
    public var time: UInt32
    public init(reader r: inout SpiceReader) throws { time = try r.u32() }
}

public enum MainMessage: Sendable {
    case `init`(MainInit)
    case channelsList(ChannelsList)
    case mouseMode(MouseMode)
    case multiMediaTime(MultiMediaTime)
    case agentConnected
    case agentDisconnected(UInt32)
    case agentData([UInt8])
    case agentToken(UInt32)
    case agentConnectedTokens(UInt32)
    case name(String)
    case uuid([UInt8])
    case other(type: UInt16, payload: [UInt8])

    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        switch MainServerMsg(rawValue: type) {
        case .`init`: self = .`init`(try MainInit(reader: &r))
        case .channelsList: self = .channelsList(try ChannelsList(reader: &r))
        case .mouseMode: self = .mouseMode(try MouseMode(reader: &r))
        case .multiMediaTime: self = .multiMediaTime(try MultiMediaTime(reader: &r))
        case .agentConnected: self = .agentConnected
        case .agentDisconnected: self = .agentDisconnected(try r.u32())
        case .agentData: self = .agentData(payload)
        case .agentToken: self = .agentToken(try r.u32())
        case .agentConnectedTokens: self = .agentConnectedTokens(try r.u32())
        case .name:
            let len = try r.u32()
            self = .name(String(decoding: try r.bytes(Int(min(len, 4096))), as: UTF8.self))
        case .uuid: self = .uuid(try r.bytes(16))
        default: self = .other(type: type, payload: payload)
        }
    }
}
```

`ClientMessages.swift`:
```swift
public enum ClientMessage {
    public static func frame(type: UInt16, payload: [UInt8], mini: Bool, serial: UInt64) -> [UInt8] {
        DataHeader(serial: serial, type: type, size: UInt32(payload.count), subList: 0).encode(mini: mini) + payload
    }
    public static func ackSync(generation: UInt32) -> [UInt8] { var w = SpiceWriter(); w.u32(generation); return w.bytes }
    public static func ack() -> [UInt8] { [] }
    public static func pong(_ p: Ping) -> [UInt8] { var w = SpiceWriter(); w.u32(p.id); w.u64(p.timestamp); return w.bytes }
    public static func attachChannels() -> [UInt8] { [] }
    public static func mouseModeRequest(_ mode: UInt32) -> [UInt8] { var w = SpiceWriter(); w.u32(mode); return w.bytes }
}
```

- [x] **Step 4: Run tests**

Run: `swift test --filter MainMessageTests`
Expected: 6 pass.

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(wire): data headers, common and main channel messages"
```

---

### Task 5: Geometry and image descriptors

**Files:**
- Create: `Sources/SpiceWire/Geometry.swift`, `Sources/SpiceWire/Image.swift`
- Test: `Tests/SpiceWireTests/ImageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SpicePoint: Sendable, Equatable { x: Int32; y: Int32; init(reader:) throws }
  public struct SpiceRect: Sendable, Equatable { top, left, bottom, right: Int32; var width: Int32 { right-left }; var height: Int32 { bottom-top }; init(reader:) throws; func intersection(_:) -> SpiceRect?; var isEmpty: Bool }
  public enum SpiceClip: Sendable, Equatable { case none; case rects([SpiceRect]); init(reader:) throws }
  public enum ROPD { static let inversSrc: UInt16 = 1<<0, inversBrush = 1<<1, inversDest = 1<<2, opPut = 1<<3, opOr = 1<<4, opAnd = 1<<5, opXor = 1<<6, opBlackness = 1<<7, opWhiteness = 1<<8, opInvers = 1<<9, inversRes = 1<<10 }
  public struct SpiceQMask: Sendable, Equatable { flags: UInt8; pos: SpicePoint; bitmap: SpiceImage?; init(reader:, base:) throws }   // flags bit0 = invers
  public enum SpiceBrush: Sendable, Equatable { case none; case solid(UInt32); case pattern(SpiceImage, SpicePoint); init(reader:, base:) throws }
  public enum ImageType: UInt8 { bitmap = 0, quic = 1, lzPlt = 100, lzRGB = 101, glzRGB = 102, fromCache = 103, surface = 104, jpeg = 105, fromCacheLossless = 106, zlibGlzRGB = 107, jpegAlpha = 108, lz4 = 109 }
  public enum ImageFlags { static let cacheMe: UInt8 = 1, highBitsSet = 2, cacheReplaceMe = 4 }
  public enum BitmapFormat: UInt8 { bit1LE = 1, bit1BE, bit4LE, bit4BE, bit8, bit16, bit24, bit32, rgba, bit8A }
  public enum BitmapFlags { static let palCacheMe: UInt8 = 1, palFromCache = 2, topDown = 4 }
  public struct SpicePalette: Sendable, Equatable { id: UInt64; entries: [UInt32] }
  public struct SpiceBitmap: Sendable, Equatable { format: BitmapFormat; flags: UInt8; width: UInt32; height: UInt32; stride: UInt32; palette: SpicePalette?; paletteID: UInt64?; data: [UInt8] }
  public struct SpiceImageDescriptor: Sendable, Equatable { id: UInt64; type: ImageType; flags: UInt8; width: UInt32; height: UInt32 }
  public enum ImagePayload: Sendable, Equatable { case bitmap(SpiceBitmap); case quic([UInt8]); case lzRGB([UInt8]); case glzRGB([UInt8]); case zlibGlzRGB([UInt8]); case lzPlt(flags: UInt8, palette: SpicePalette?, paletteID: UInt64?, data: [UInt8]); case jpeg([UInt8]); case jpegAlpha(flags: UInt8, jpegSize: UInt32, data: [UInt8]); case lz4([UInt8]); case fromCache; case fromCacheLossless; case surface(UInt32) }
  public struct SpiceImage: Sendable, Equatable { descriptor: SpiceImageDescriptor; payload: ImagePayload
      /// `pointer` is a u32 offset from `base` (the message body reader). 0 means "no image".
      static func at(pointer: UInt32, base: SpiceReader) throws -> SpiceImage? }
  ```

- [x] **Step 1: Write failing tests**

```swift
import Testing
@testable import SpiceWire

private func bitmapMessage() -> [UInt8] {
    // body: [u32 ptr=4][image @4]
    var w = SpiceWriter()
    w.u32(4)
    w.u64(0x1122); w.u8(ImageType.bitmap.rawValue); w.u8(ImageFlags.cacheMe); w.u32(2); w.u32(1)  // descriptor
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(1); w.u32(8); w.u32(0) // palette ptr 0
    w.bytes([1, 2, 3, 4, 5, 6, 7, 8])
    return w.bytes
}

@Test func parsesBitmapImageThroughPointer() throws {
    var r = SpiceReader(bitmapMessage())
    let ptr = try r.u32()
    let img = try #require(try SpiceImage.at(pointer: ptr, base: r))
    #expect(img.descriptor.id == 0x1122)
    #expect(img.descriptor.flags & ImageFlags.cacheMe != 0)
    guard case let .bitmap(b) = img.payload else { Issue.record("not bitmap"); return }
    #expect(b.format == .bit32)
    #expect(b.stride == 8)
    #expect(b.data == [1, 2, 3, 4, 5, 6, 7, 8])
}

@Test func nullPointerIsNil() throws {
    let r = SpiceReader([0, 0, 0, 0])
    #expect(try SpiceImage.at(pointer: 0, base: r) == nil)
}

@Test func fromCacheHasNoPayload() throws {
    var w = SpiceWriter()
    w.u64(5); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(10); w.u32(10)
    let img = try SpiceImage(reader: SpiceReader(w.bytes), base: SpiceReader(w.bytes))
    #expect(img.payload == .fromCache)
}

@Test func bitmapStrideOverflowThrows() {
    var w = SpiceWriter()
    w.u64(1); w.u8(0); w.u8(0); w.u32(2); w.u32(1)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(0xFFFF_FFFF); w.u32(8); w.u32(0)
    #expect(throws: WireError.self) { _ = try SpiceImage(reader: SpiceReader(w.bytes), base: SpiceReader(w.bytes)) }
}

@Test func clipRectsParse() throws {
    var w = SpiceWriter()
    w.u8(1); w.u32(1); w.i32(0); w.i32(0); w.i32(10); w.i32(20)
    var r = SpiceReader(w.bytes)
    #expect(try SpiceClip(reader: &r) == .rects([SpiceRect(top: 0, left: 0, bottom: 10, right: 20)]))
}

@Test func rectIntersection() {
    let a = SpiceRect(top: 0, left: 0, bottom: 10, right: 10)
    let b = SpiceRect(top: 5, left: 5, bottom: 20, right: 20)
    #expect(a.intersection(b) == SpiceRect(top: 5, left: 5, bottom: 10, right: 10))
    #expect(a.intersection(SpiceRect(top: 50, left: 50, bottom: 60, right: 60)) == nil)
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter ImageTests`
Expected: compile errors.

- [x] **Step 3: Implement**

`Geometry.swift`:
```swift
public struct SpicePoint: Sendable, Equatable {
    public var x: Int32, y: Int32
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
    public init(reader r: inout SpiceReader) throws { x = try r.i32(); y = try r.i32() }
}

public struct SpiceRect: Sendable, Equatable {
    public var top, left, bottom, right: Int32
    public init(top: Int32, left: Int32, bottom: Int32, right: Int32) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public init(reader r: inout SpiceReader) throws {
        top = try r.i32(); left = try r.i32(); bottom = try r.i32(); right = try r.i32()
    }
    public var width: Int32 { right - left }
    public var height: Int32 { bottom - top }
    public var isEmpty: Bool { right <= left || bottom <= top }
    public func intersection(_ o: SpiceRect) -> SpiceRect? {
        let r = SpiceRect(top: max(top, o.top), left: max(left, o.left), bottom: min(bottom, o.bottom), right: min(right, o.right))
        return r.isEmpty ? nil : r
    }
}

public enum SpiceClip: Sendable, Equatable {
    case none
    case rects([SpiceRect])
    public init(reader r: inout SpiceReader) throws {
        switch try r.u8() {
        case 0: self = .none
        case 1:
            let n = try r.u32()
            guard n <= 1 << 16 else { throw WireError.badValue(field: "num_rects", value: UInt64(n)) }
            self = .rects(try (0 ..< n).map { _ in try SpiceRect(reader: &r) })
        case let t: throw WireError.badValue(field: "clip_type", value: UInt64(t))
        }
    }
}

public enum ROPD {
    public static let inversSrc: UInt16 = 1 << 0, inversBrush: UInt16 = 1 << 1, inversDest: UInt16 = 1 << 2
    public static let opPut: UInt16 = 1 << 3, opOr: UInt16 = 1 << 4, opAnd: UInt16 = 1 << 5, opXor: UInt16 = 1 << 6
    public static let opBlackness: UInt16 = 1 << 7, opWhiteness: UInt16 = 1 << 8, opInvers: UInt16 = 1 << 9
    public static let inversRes: UInt16 = 1 << 10
}

public struct SpiceQMask: Sendable, Equatable {
    public var flags: UInt8
    public var pos: SpicePoint
    public var bitmap: SpiceImage?
    public init(reader r: inout SpiceReader, base: SpiceReader) throws {
        flags = try r.u8(); pos = try SpicePoint(reader: &r)
        bitmap = try SpiceImage.at(pointer: try r.u32(), base: base)
    }
}

public enum SpiceBrush: Sendable, Equatable {
    case none
    case solid(UInt32)
    case pattern(SpiceImage, SpicePoint)
    public init(reader r: inout SpiceReader, base: SpiceReader) throws {
        switch try r.u8() {
        case 0: self = .none
        case 1: self = .solid(try r.u32())
        case 2:
            let ptr = try r.u32(); let pos = try SpicePoint(reader: &r)
            guard let img = try SpiceImage.at(pointer: ptr, base: base) else { throw WireError.badValue(field: "pattern", value: 0) }
            self = .pattern(img, pos)
        case let t: throw WireError.badValue(field: "brush_type", value: UInt64(t))
        }
    }
}
```

`Image.swift`:
```swift
public enum ImageType: UInt8, Sendable {
    case bitmap = 0, quic = 1, lzPlt = 100, lzRGB = 101, glzRGB = 102, fromCache = 103, surface = 104
    case jpeg = 105, fromCacheLossless = 106, zlibGlzRGB = 107, jpegAlpha = 108, lz4 = 109
}
public enum ImageFlags { public static let cacheMe: UInt8 = 1, highBitsSet: UInt8 = 2, cacheReplaceMe: UInt8 = 4 }
public enum BitmapFormat: UInt8, Sendable { case bit1LE = 1, bit1BE, bit4LE, bit4BE, bit8, bit16, bit24, bit32, rgba, bit8A }
public enum BitmapFlags { public static let palCacheMe: UInt8 = 1, palFromCache: UInt8 = 2, topDown: UInt8 = 4 }

public struct SpicePalette: Sendable, Equatable {
    public var id: UInt64, entries: [UInt32]
    public init(reader r: inout SpiceReader) throws {
        id = try r.u64()
        let n = try r.u16()
        guard n <= 256 else { throw WireError.badValue(field: "num_ents", value: UInt64(n)) }
        entries = try (0 ..< n).map { _ in try r.u32() }
    }
}

public struct SpiceImageDescriptor: Sendable, Equatable {
    public var id: UInt64, type: ImageType, flags: UInt8, width: UInt32, height: UInt32
    public init(reader r: inout SpiceReader) throws {
        id = try r.u64()
        let t = try r.u8()
        guard let type = ImageType(rawValue: t) else { throw WireError.badValue(field: "image_type", value: UInt64(t)) }
        self.type = type; flags = try r.u8(); width = try r.u32(); height = try r.u32()
        guard width <= 16384, height <= 16384 else { throw WireError.badValue(field: "image_size", value: UInt64(width) << 32 | UInt64(height)) }
    }
}

public struct SpiceBitmap: Sendable, Equatable {
    public var format: BitmapFormat, flags: UInt8, width: UInt32, height: UInt32, stride: UInt32
    public var palette: SpicePalette?, paletteID: UInt64?, data: [UInt8]
}

public enum ImagePayload: Sendable, Equatable {
    case bitmap(SpiceBitmap)
    case quic([UInt8]), lzRGB([UInt8]), glzRGB([UInt8]), zlibGlzRGB([UInt8])
    case lzPlt(flags: UInt8, palette: SpicePalette?, paletteID: UInt64?, data: [UInt8])
    case jpeg([UInt8])
    case jpegAlpha(flags: UInt8, jpegSize: UInt32, data: [UInt8])
    case lz4([UInt8])
    case fromCache, fromCacheLossless
    case surface(UInt32)
}

public struct SpiceImage: Sendable, Equatable {
    public var descriptor: SpiceImageDescriptor
    public var payload: ImagePayload

    public static func at(pointer: UInt32, base: SpiceReader) throws -> SpiceImage? {
        if pointer == 0 { return nil }
        return try SpiceImage(reader: try base.reader(at: pointer), base: base)
    }

    private static func sizedData(_ r: inout SpiceReader) throws -> [UInt8] {
        let n = try r.u32()
        guard n <= 1 << 26 else { throw WireError.badValue(field: "data_size", value: UInt64(n)) }
        return try r.bytes(Int(n))
    }

    public init(reader: SpiceReader, base: SpiceReader) throws {
        var r = reader
        descriptor = try SpiceImageDescriptor(reader: &r)
        switch descriptor.type {
        case .bitmap:
            let f = try r.u8()
            guard let format = BitmapFormat(rawValue: f) else { throw WireError.badValue(field: "bitmap_format", value: UInt64(f)) }
            let flags = try r.u8(), w = try r.u32(), h = try r.u32(), stride = try r.u32()
            var palette: SpicePalette? = nil, paletteID: UInt64? = nil
            if flags & BitmapFlags.palFromCache != 0 {
                paletteID = try r.u64()
            } else {
                let p = try r.u32()
                if p != 0 { var pr = try base.reader(at: p); palette = try SpicePalette(reader: &pr) }
            }
            let (size, overflow) = stride.multipliedReportingOverflow(by: h)
            guard !overflow, size <= 1 << 26 else { throw WireError.badValue(field: "bitmap_size", value: UInt64(stride)) }
            payload = .bitmap(SpiceBitmap(format: format, flags: flags, width: w, height: h, stride: stride,
                                          palette: palette, paletteID: paletteID, data: try r.bytes(Int(size))))
        case .quic: payload = .quic(try Self.sizedData(&r))
        case .lzRGB: payload = .lzRGB(try Self.sizedData(&r))
        case .glzRGB: payload = .glzRGB(try Self.sizedData(&r))
        case .zlibGlzRGB: payload = .zlibGlzRGB(try Self.sizedData(&r))
        case .lz4: payload = .lz4(try Self.sizedData(&r))
        case .jpeg: payload = .jpeg(try Self.sizedData(&r))
        case .jpegAlpha:
            let flags = try r.u8(), jpegSize = try r.u32()
            payload = .jpegAlpha(flags: flags, jpegSize: jpegSize, data: try Self.sizedData(&r))
        case .lzPlt:
            let flags = try r.u8()
            let n = try r.u32()
            var palette: SpicePalette? = nil, paletteID: UInt64? = nil
            if flags & BitmapFlags.palFromCache != 0 { paletteID = try r.u64() }
            else { let p = try r.u32(); if p != 0 { var pr = try base.reader(at: p); palette = try SpicePalette(reader: &pr) } }
            guard n <= 1 << 26 else { throw WireError.badValue(field: "data_size", value: UInt64(n)) }
            payload = .lzPlt(flags: flags, palette: palette, paletteID: paletteID, data: try r.bytes(Int(n)))
        case .fromCache: payload = .fromCache
        case .fromCacheLossless: payload = .fromCacheLossless
        case .surface: payload = .surface(try r.u32())
        }
    }
}
```

- [x] **Step 4: Run tests**

Run: `swift test --filter ImageTests`
Expected: 6 pass.

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(wire): geometry, clip, brush, qmask and image descriptors"
```

---

### Task 6: Display messages (M1 subset)

**Files:**
- Create: `Sources/SpiceWire/DisplayMessages.swift`; append to `Sources/SpiceWire/ClientMessages.swift`
- Test: `Tests/SpiceWireTests/DisplayMessageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum DisplayServerMsg: UInt16 { mode = 101, mark = 102, reset = 103, copyBits = 104, invalList = 105, invalAllPixmaps = 106, invalPalette = 107, invalAllPalettes = 108, streamCreate = 122, streamData = 123, streamClip = 124, streamDestroy = 125, streamDestroyAll = 126, drawFill = 302, drawOpaque = 303, drawCopy = 304, drawBlend = 305, drawBlackness = 306, drawWhiteness = 307, drawInvers = 308, drawRop3 = 309, drawStroke = 310, drawText = 311, drawTransparent = 312, drawAlphaBlend = 313, surfaceCreate = 314, surfaceDestroy = 315, streamDataSized = 316, monitorsConfig = 317, drawComposite = 318, streamActivateReport = 319 }
  public enum DisplayClientMsg: UInt16 { `init` = 101, streamReport = 102, preferredCompression = 103, glDrawDone = 104, preferredVideoCodecType = 105 }
  public enum SurfaceFormat: UInt32 { a1 = 1, a8 = 8, rgb555 = 16, xrgb32 = 32, rgb565 = 80, argb32 = 96 }
  public struct SurfaceCreate: Sendable, Equatable { surfaceID: UInt32; width: UInt32; height: UInt32; format: SurfaceFormat; flags: UInt32; var isPrimary: Bool { flags & 1 != 0 } }
  public struct DrawBase: Sendable, Equatable { surfaceID: UInt32; box: SpiceRect; clip: SpiceClip }
  public struct DrawFill: Sendable, Equatable { base: DrawBase; brush: SpiceBrush; rop: UInt16; mask: SpiceQMask }
  public struct DrawCopy: Sendable, Equatable { base: DrawBase; source: SpiceImage?; sourceArea: SpiceRect; rop: UInt16; scaleMode: UInt8; mask: SpiceQMask }   // also used for BLEND
  public struct DrawOpaque: Sendable, Equatable { base: DrawBase; source: SpiceImage?; sourceArea: SpiceRect; brush: SpiceBrush; rop: UInt16; scaleMode: UInt8; mask: SpiceQMask }
  public struct DrawMaskOnly: Sendable, Equatable { base: DrawBase; mask: SpiceQMask }   // BLACKNESS / WHITENESS / INVERS
  public struct CopyBits: Sendable, Equatable { base: DrawBase; sourcePos: SpicePoint }
  public struct DrawAlphaBlend: Sendable, Equatable { base: DrawBase; alphaFlags: UInt8; alpha: UInt8; source: SpiceImage?; sourceArea: SpiceRect }
  public struct MonitorHead: Sendable, Equatable { id, surfaceID, width, height, x, y, flags: UInt32 }
  public struct MonitorsConfig: Sendable, Equatable { maxAllowed: UInt16; heads: [MonitorHead] }
  public struct ResourceID: Sendable, Equatable { type: UInt8; id: UInt64 }
  public enum DisplayMessage: Sendable { case mode(width: UInt32, height: UInt32, bits: UInt32), mark, reset, surfaceCreate(SurfaceCreate), surfaceDestroy(UInt32), fill(DrawFill), copy(DrawCopy), blend(DrawCopy), opaque(DrawOpaque), blackness(DrawMaskOnly), whiteness(DrawMaskOnly), invers(DrawMaskOnly), copyBits(CopyBits), alphaBlend(DrawAlphaBlend), invalList([ResourceID]), invalAllPixmaps, invalPalette(UInt64), invalAllPalettes, monitorsConfig(MonitorsConfig), unsupported(type: UInt16, payload: [UInt8])
      public init(type: UInt16, payload: [UInt8]) throws }
  extension ClientMessage { static func displayInit(cacheID: UInt8 = 1, cacheSize: Int64, glzDictionaryID: UInt8 = 1, glzWindowSize: Int32) -> [UInt8] }
  ```

- [x] **Step 1: Write failing tests**

```swift
import Testing
@testable import SpiceWire

private func base(surface: UInt32 = 0) -> SpiceWriter {
    var w = SpiceWriter()
    w.u32(surface); w.i32(10); w.i32(20); w.i32(30); w.i32(40)   // box top,left,bottom,right
    w.u8(0)                                                       // clip none
    return w
}

@Test func surfaceCreateParses() throws {
    var w = SpiceWriter(); w.u32(0); w.u32(1024); w.u32(768); w.u32(32); w.u32(1)
    let m = try DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: w.bytes)
    guard case let .surfaceCreate(s) = m else { Issue.record("case"); return }
    #expect(s.width == 1024 && s.height == 768 && s.format == .xrgb32 && s.isPrimary)
}

@Test func drawFillSolidParses() throws {
    var w = base()
    w.u8(1); w.u32(0xFF0000)            // brush solid red
    w.u16(ROPD.opPut)
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)  // qmask: flags, pos, bitmap ptr 0
    let m = try DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes)
    guard case let .fill(f) = m else { Issue.record("case"); return }
    #expect(f.base.box == SpiceRect(top: 10, left: 20, bottom: 30, right: 40))
    #expect(f.brush == .solid(0xFF0000))
    #expect(f.rop == ROPD.opPut)
    #expect(f.mask.bitmap == nil)
}

@Test func drawCopyResolvesImagePointer() throws {
    var w = base()
    let ptrIndex = w.bytes.count
    w.u32(0)                                // src_bitmap ptr, patched
    w.i32(0); w.i32(0); w.i32(20); w.i32(20) // src_area
    w.u16(ROPD.opPut); w.u8(0)
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)   // mask
    w.patchU32(at: ptrIndex, UInt32(w.bytes.count))
    w.u64(77); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(20); w.u32(20)
    let m = try DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
    guard case let .copy(c) = m else { Issue.record("case"); return }
    #expect(c.source?.descriptor.id == 77)
    #expect(c.sourceArea.width == 20)
}

@Test func unknownTypeIsUnsupportedNotError() throws {
    let m = try DisplayMessage(type: 999, payload: [1, 2, 3])
    guard case let .unsupported(t, p) = m else { Issue.record("case"); return }
    #expect(t == 999 && p == [1, 2, 3])
}

@Test func displayInitEncodes14Bytes() {
    let b = ClientMessage.displayInit(cacheSize: 1 << 20, glzWindowSize: 1 << 16)
    #expect(b.count == 14)
    #expect(b[0] == 1)
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter DisplayMessageTests`
Expected: compile errors.

- [x] **Step 3: Implement**

`DisplayMessages.swift`:
```swift
public enum DisplayServerMsg: UInt16, Sendable {
    case mode = 101, mark, reset, copyBits, invalList, invalAllPixmaps, invalPalette, invalAllPalettes
    case streamCreate = 122, streamData, streamClip, streamDestroy, streamDestroyAll
    case drawFill = 302, drawOpaque, drawCopy, drawBlend, drawBlackness, drawWhiteness, drawInvers
    case drawRop3, drawStroke, drawText, drawTransparent, drawAlphaBlend, surfaceCreate, surfaceDestroy
    case streamDataSized, monitorsConfig, drawComposite, streamActivateReport
}
public enum DisplayClientMsg: UInt16, Sendable {
    case `init` = 101, streamReport, preferredCompression, glDrawDone, preferredVideoCodecType
}
public enum SurfaceFormat: UInt32, Sendable { case a1 = 1, a8 = 8, rgb555 = 16, xrgb32 = 32, rgb565 = 80, argb32 = 96 }

public struct SurfaceCreate: Sendable, Equatable {
    public var surfaceID: UInt32, width: UInt32, height: UInt32, format: SurfaceFormat, flags: UInt32
    public var isPrimary: Bool { flags & 1 != 0 }
    public init(reader r: inout SpiceReader) throws {
        surfaceID = try r.u32(); width = try r.u32(); height = try r.u32()
        let f = try r.u32()
        guard let fmt = SurfaceFormat(rawValue: f) else { throw WireError.badValue(field: "surface_format", value: UInt64(f)) }
        format = fmt; flags = try r.u32()
        guard width <= 16384, height <= 16384 else { throw WireError.badValue(field: "surface_size", value: UInt64(width)) }
    }
}

public struct DrawBase: Sendable, Equatable {
    public var surfaceID: UInt32, box: SpiceRect, clip: SpiceClip
    public init(reader r: inout SpiceReader) throws {
        surfaceID = try r.u32(); box = try SpiceRect(reader: &r); clip = try SpiceClip(reader: &r)
    }
}

public struct DrawFill: Sendable, Equatable {
    public var base: DrawBase, brush: SpiceBrush, rop: UInt16, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r); brush = try SpiceBrush(reader: &r, base: body)
        rop = try r.u16(); mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct DrawCopy: Sendable, Equatable {
    public var base: DrawBase, source: SpiceImage?, sourceArea: SpiceRect, rop: UInt16, scaleMode: UInt8, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r)
        source = try SpiceImage.at(pointer: try r.u32(), base: body)
        sourceArea = try SpiceRect(reader: &r); rop = try r.u16(); scaleMode = try r.u8()
        mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct DrawOpaque: Sendable, Equatable {
    public var base: DrawBase, source: SpiceImage?, sourceArea: SpiceRect, brush: SpiceBrush, rop: UInt16, scaleMode: UInt8, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r)
        source = try SpiceImage.at(pointer: try r.u32(), base: body)
        sourceArea = try SpiceRect(reader: &r); brush = try SpiceBrush(reader: &r, base: body)
        rop = try r.u16(); scaleMode = try r.u8(); mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct DrawMaskOnly: Sendable, Equatable {
    public var base: DrawBase, mask: SpiceQMask
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r); mask = try SpiceQMask(reader: &r, base: body)
    }
}

public struct CopyBits: Sendable, Equatable {
    public var base: DrawBase, sourcePos: SpicePoint
    init(reader r: inout SpiceReader) throws { base = try DrawBase(reader: &r); sourcePos = try SpicePoint(reader: &r) }
}

public struct DrawAlphaBlend: Sendable, Equatable {
    public var base: DrawBase, alphaFlags: UInt8, alpha: UInt8, source: SpiceImage?, sourceArea: SpiceRect
    init(reader r: inout SpiceReader, body: SpiceReader) throws {
        base = try DrawBase(reader: &r); alphaFlags = try r.u8(); alpha = try r.u8()
        source = try SpiceImage.at(pointer: try r.u32(), base: body); sourceArea = try SpiceRect(reader: &r)
    }
}

public struct MonitorHead: Sendable, Equatable {
    public var id, surfaceID, width, height, x, y, flags: UInt32
    init(reader r: inout SpiceReader) throws {
        id = try r.u32(); surfaceID = try r.u32(); width = try r.u32(); height = try r.u32()
        x = try r.u32(); y = try r.u32(); flags = try r.u32()
    }
}
public struct MonitorsConfig: Sendable, Equatable {
    public var maxAllowed: UInt16, heads: [MonitorHead]
    init(reader r: inout SpiceReader) throws {
        let count = try r.u16(); maxAllowed = try r.u16()
        guard count <= 64 else { throw WireError.badValue(field: "monitor_count", value: UInt64(count)) }
        heads = try (0 ..< count).map { _ in try MonitorHead(reader: &r) }
    }
}
public struct ResourceID: Sendable, Equatable { public var type: UInt8, id: UInt64 }

public enum DisplayMessage: Sendable {
    case mode(width: UInt32, height: UInt32, bits: UInt32)
    case mark, reset
    case surfaceCreate(SurfaceCreate), surfaceDestroy(UInt32)
    case fill(DrawFill), copy(DrawCopy), blend(DrawCopy), opaque(DrawOpaque)
    case blackness(DrawMaskOnly), whiteness(DrawMaskOnly), invers(DrawMaskOnly)
    case copyBits(CopyBits), alphaBlend(DrawAlphaBlend)
    case invalList([ResourceID]), invalAllPixmaps, invalPalette(UInt64), invalAllPalettes
    case monitorsConfig(MonitorsConfig)
    case unsupported(type: UInt16, payload: [UInt8])

    public init(type: UInt16, payload: [UInt8]) throws {
        let body = SpiceReader(payload)
        var r = body
        switch DisplayServerMsg(rawValue: type) {
        case .mode: self = .mode(width: try r.u32(), height: try r.u32(), bits: try r.u32())
        case .mark: self = .mark
        case .reset: self = .reset
        case .surfaceCreate: self = .surfaceCreate(try SurfaceCreate(reader: &r))
        case .surfaceDestroy: self = .surfaceDestroy(try r.u32())
        case .drawFill: self = .fill(try DrawFill(reader: &r, body: body))
        case .drawCopy: self = .copy(try DrawCopy(reader: &r, body: body))
        case .drawBlend: self = .blend(try DrawCopy(reader: &r, body: body))
        case .drawOpaque: self = .opaque(try DrawOpaque(reader: &r, body: body))
        case .drawBlackness: self = .blackness(try DrawMaskOnly(reader: &r, body: body))
        case .drawWhiteness: self = .whiteness(try DrawMaskOnly(reader: &r, body: body))
        case .drawInvers: self = .invers(try DrawMaskOnly(reader: &r, body: body))
        case .copyBits: self = .copyBits(try CopyBits(reader: &r))
        case .drawAlphaBlend: self = .alphaBlend(try DrawAlphaBlend(reader: &r, body: body))
        case .invalList:
            let n = try r.u16()
            self = .invalList(try (0 ..< n).map { _ in ResourceID(type: try r.u8(), id: try r.u64()) })
        case .invalAllPixmaps: self = .invalAllPixmaps
        case .invalPalette: self = .invalPalette(try r.u64())
        case .invalAllPalettes: self = .invalAllPalettes
        case .monitorsConfig: self = .monitorsConfig(try MonitorsConfig(reader: &r))
        default: self = .unsupported(type: type, payload: payload)
        }
    }
}
```

Append to `ClientMessages.swift`:
```swift
extension ClientMessage {
    public static func displayInit(cacheID: UInt8 = 1, cacheSize: Int64, glzDictionaryID: UInt8 = 1, glzWindowSize: Int32) -> [UInt8] {
        var w = SpiceWriter()
        w.u8(cacheID); w.u64(UInt64(bitPattern: cacheSize)); w.u8(glzDictionaryID); w.i32(glzWindowSize)
        return w.bytes
    }
}
```

- [x] **Step 4: Run tests**

Run: `swift test --filter DisplayMessageTests`
Expected: 5 pass.

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(wire): display channel messages for tier-1 drawing"
```

---

### Task 7: Ticket encryption

**Files:**
- Create: `Sources/SpiceCore/SpiceError.swift`, `Sources/SpiceCore/Ticket.swift`
- Test: `Tests/SpiceCoreTests/TicketTests.swift`
- Delete: `Sources/SpiceCore/SpiceCore.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SpiceError: Error, Sendable { public enum Kind: Sendable { case connect, tls, link(LinkError), auth, protocolError(WireError), closed, unsupported(String) }; public var kind: Kind; public var channel: ChannelDescriptor?; public var underlying: String? }
  /// DER SubjectPublicKeyInfo (162 bytes for RSA-1024) → RSA-OAEP-SHA1 ciphertext of the NUL-terminated password (128 bytes).
  public enum Ticket { static func encrypt(password: String, publicKey der: [UInt8]) throws -> [UInt8] }
  ```

- [x] **Step 1: Write failing test**

```swift
import Testing
import Security
@testable import SpiceCore

@Test func ticketDecryptsWithMatchingPrivateKey() throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024]
    var err: Unmanaged<CFError>?
    let priv = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &err))
    let pub = try #require(SecKeyCopyPublicKey(priv))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, &err)) as Data
    // Wrap PKCS#1 in SubjectPublicKeyInfo, as the server sends it.
    let spki = Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1))
    #expect(spki.count == 162)

    let cipher = try Ticket.encrypt(password: "hunter2", publicKey: spki)
    #expect(cipher.count == 128)

    let plain = try #require(SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA1, Data(cipher) as CFData, &err)) as Data
    #expect(plain == Data("hunter2".utf8) + [0])
}

@Test func passwordTooLongThrows() {
    #expect(throws: SpiceError.self) { _ = try Ticket.encrypt(password: String(repeating: "x", count: 61), publicKey: [UInt8](repeating: 0, count: 162)) }
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter TicketTests`
Expected: compile errors.

- [x] **Step 3: Implement**

`SpiceError.swift`:
```swift
import SpiceWire

public struct SpiceError: Error, Sendable {
    public enum Kind: Sendable {
        case connect, tls, link(LinkError), auth, protocolError(WireError), closed, unsupported(String)
    }
    public var kind: Kind
    public var channel: ChannelDescriptor?
    public var underlying: String?
    public init(_ kind: Kind, channel: ChannelDescriptor? = nil, underlying: String? = nil) {
        self.kind = kind; self.channel = channel; self.underlying = underlying
    }
}
```

`Ticket.swift`:
```swift
import Foundation
import Security
import SpiceWire

public enum Ticket {
    /// rsaEncryption OID + NULL, followed by BIT STRING wrapping the PKCS#1 key.
    private static let rsaAlgID: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]

    static func wrapSPKI(pkcs1: [UInt8]) -> [UInt8] {
        let bitString: [UInt8] = [0x03, 0x81, UInt8(pkcs1.count + 1), 0x00] + pkcs1
        let inner = rsaAlgID + bitString
        return [0x30, 0x81, UInt8(inner.count)] + inner
    }

    /// Strips SubjectPublicKeyInfo and returns the PKCS#1 RSAPublicKey bytes SecKey wants.
    static func unwrapSPKI(_ der: [UInt8]) throws -> [UInt8] {
        // Expected layout: 30 81 LL | 30 0D <algid> | 03 81 LL 00 <pkcs1>
        let prefix = 3 + rsaAlgID.count
        guard der.count > prefix + 4, der[0] == 0x30, Array(der[3 ..< prefix]) == rsaAlgID,
              der[prefix] == 0x03, der[prefix + 1] == 0x81, der[prefix + 3] == 0x00 else {
            throw SpiceError(.auth, underlying: "unexpected public key encoding")
        }
        return Array(der[(prefix + 4)...])
    }

    public static func encrypt(password: String, publicKey der: [UInt8]) throws -> [UInt8] {
        let pw = Array(password.utf8)
        guard pw.count <= Link.maxPasswordLength else { throw SpiceError(.auth, underlying: "password longer than 60 bytes") }
        let pkcs1 = try unwrapSPKI(der)
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, &err) else {
            throw SpiceError(.auth, underlying: "SecKeyCreateWithData: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(pw + [0]) as CFData, &err) else {
            throw SpiceError(.auth, underlying: "SecKeyCreateEncryptedData: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return [UInt8](cipher as Data)
    }
}
```

- [x] **Step 4: Run tests**

Run: `swift test --filter TicketTests`
Expected: 2 pass. If `unwrapSPKI` rejects a real server key later (Task 12), dump the 162 bytes with `xxd` and adjust the layout check — the format above is what `spice-server` produces via `i2d_RSA_PUBKEY` for 1024-bit keys.

- [x] **Step 5: Commit**

```bash
git rm -q Sources/SpiceCore/SpiceCore.swift
git add -A && git commit -m "feat(core): RSA-OAEP ticket encryption via Security.framework"
```

---

### Task 8: ByteSource abstraction and NWConnection transport

**Files:**
- Create: `Sources/SpiceCore/ByteSource.swift`, `Sources/SpiceCore/NWTransport.swift`
- Test: `Tests/SpiceCoreTests/ByteSourceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public protocol ByteSource: Sendable { func read(exactly n: Int) async throws -> [UInt8] }   // throws SpiceError(.closed) on EOF
  public protocol ByteSink: Sendable { func write(_ bytes: [UInt8]) async throws }
  public typealias Transport = ByteSource & ByteSink
  public actor InMemoryTransport: Transport { public init(input: [UInt8]); public private(set) var written: [UInt8]; public func read(exactly:) ; public func write(_:) }
  public actor NWTransport: Transport { public static func connect(host: String, port: UInt16) async throws -> NWTransport; public func close() }
  ```

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import SpiceCore

@Test func inMemoryReadsExactly() async throws {
    let t = InMemoryTransport(input: [1, 2, 3, 4, 5])
    #expect(try await t.read(exactly: 2) == [1, 2])
    #expect(try await t.read(exactly: 3) == [3, 4, 5])
}

@Test func inMemoryEOFThrowsClosed() async {
    let t = InMemoryTransport(input: [1])
    await #expect(throws: SpiceError.self) { _ = try await t.read(exactly: 2) }
}

@Test func inMemoryRecordsWrites() async throws {
    let t = InMemoryTransport(input: [])
    try await t.write([9, 9]); try await t.write([8])
    #expect(await t.written == [9, 9, 8])
}

@Test func nwConnectRefusedThrowsConnect() async {
    await #expect(throws: SpiceError.self) { _ = try await NWTransport.connect(host: "127.0.0.1", port: 1) }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ByteSourceTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

`ByteSource.swift`:
```swift
public protocol ByteSource: Sendable { func read(exactly n: Int) async throws -> [UInt8] }
public protocol ByteSink: Sendable { func write(_ bytes: [UInt8]) async throws }
public typealias Transport = ByteSource & ByteSink

public actor InMemoryTransport: Transport {
    private let input: [UInt8]
    private var cursor = 0
    public private(set) var written: [UInt8] = []
    public init(input: [UInt8]) { self.input = input }
    public func read(exactly n: Int) throws -> [UInt8] {
        guard input.count - cursor >= n else { throw SpiceError(.closed, underlying: "EOF") }
        defer { cursor += n }
        return Array(input[cursor ..< cursor + n])
    }
    public func write(_ bytes: [UInt8]) { written.append(contentsOf: bytes) }
}
```

`NWTransport.swift`:
```swift
import Foundation
import Network

public actor NWTransport: Transport {
    private let connection: NWConnection

    private init(connection: NWConnection) { self.connection = connection }

    public static func connect(host: String, port: UInt16) async throws -> NWTransport {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw SpiceError(.connect, underlying: "bad port") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            c.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; k.resume()
                case .failed(let e): resumed = true; k.resume(throwing: SpiceError(.connect, underlying: e.localizedDescription))
                case .waiting(let e): resumed = true; c.cancel(); k.resume(throwing: SpiceError(.connect, underlying: e.localizedDescription))
                default: break
                }
            }
            c.start(queue: DispatchQueue(label: "com.spicesee.nw"))
        }
        c.stateUpdateHandler = nil
        return NWTransport(connection: c)
    }

    public func read(exactly n: Int) async throws -> [UInt8] {
        if n == 0 { return [] }
        return try await withCheckedThrowingContinuation { k in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error { k.resume(throwing: SpiceError(.closed, underlying: error.localizedDescription)); return }
                guard let data, data.count == n else { k.resume(throwing: SpiceError(.closed, underlying: isComplete ? "EOF" : "short read")); return }
                k.resume(returning: [UInt8](data))
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { k.resume(throwing: SpiceError(.closed, underlying: error.localizedDescription)) } else { k.resume() }
            })
        }
    }

    public func close() { connection.cancel() }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ByteSourceTests`
Expected: 4 pass. (`nwConnectRefusedThrowsConnect` relies on nothing listening on port 1 — true on a default Mac.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): ByteSource/ByteSink with in-memory and NWConnection transports"
```

---

### Task 9: Link handshake

**Files:**
- Create: `Sources/SpiceCore/LinkHandshake.swift`
- Test: `Tests/SpiceCoreTests/LinkHandshakeTests.swift`

**Interfaces:**
- Consumes: `SpiceLinkMess.encode()`, `SpiceLinkReply`, `Ticket.encrypt`, `Transport`.
- Produces:
  ```swift
  public struct LinkResult: Sendable { public var serverCommonCaps: CapabilitySet; public var serverChannelCaps: CapabilitySet; public var miniHeader: Bool }
  public enum LinkHandshake {
      public static func clientCommonCaps() -> CapabilitySet   // AUTH_SPICE, MINI_HEADER
      public static func perform(on t: any Transport, connectionID: UInt32, channel: ChannelDescriptor,
                                 channelCaps: CapabilitySet, password: String?) async throws -> LinkResult }
  ```

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Security
import SpiceWire
@testable import SpiceCore

/// Server-side bytes: header + reply (with given common caps) + link result 0.
private func serverBytes(commonCaps: [UInt32], pubkey: [UInt8]) -> [UInt8] {
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(pubkey); w.u32(1); w.u32(0); w.u32(178)
    w.u32(commonCaps.reduce(0) { $0 | (1 << $1) })
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0) // SpiceLinkResult ok
    return w.bytes
}

private func keypair() throws -> (SecKey, [UInt8]) {
    var err: Unmanaged<CFError>?
    let priv = try #require(SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err))
    let pub = try #require(SecKeyCopyPublicKey(priv))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(pub, &err)) as Data
    return (priv, Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1)))
}

@Test func handshakeWithAuthSelectionSendsMechanismThenTicket() async throws {
    let (priv, spki) = try keypair()
    let t = InMemoryTransport(input: serverBytes(commonCaps: [CommonCap.protocolAuthSelection, CommonCap.authSpice, CommonCap.miniHeader], pubkey: spki))
    let result = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: "pw")
    #expect(result.miniHeader)
    let written = await t.written
    var r = SpiceReader(written)
    _ = try r.bytes(16)                       // link header
    let messSize = Int(SpiceReader(Array(written[12 ..< 16])).u32Unchecked())
    _ = try r.bytes(messSize)
    #expect(try r.u32() == CommonCap.authSpice)  // auth mechanism
    let ticket = try r.bytes(128)
    var err: Unmanaged<CFError>?
    let plain = try #require(SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA1, Data(ticket) as CFData, &err)) as Data
    #expect(plain == Data("pw".utf8) + [0])
    #expect(r.remaining == 0)
}

@Test func handshakeWithoutAuthSelectionSendsTicketOnly() async throws {
    let (_, spki) = try keypair()
    let t = InMemoryTransport(input: serverBytes(commonCaps: [CommonCap.authSpice], pubkey: spki))
    let result = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: "pw")
    #expect(!result.miniHeader)
    let written = await t.written
    let messSize = Int(SpiceReader(Array(written[12 ..< 16])).u32Unchecked())
    #expect(written.count == 16 + messSize + 128)
}

@Test func linkErrorSurfacesAsSpiceError() async throws {
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(178)
    w.u32(LinkError.needSecured.rawValue); w.bytes([UInt8](repeating: 0, count: 162)); w.u32(0); w.u32(0); w.u32(178)
    let t = InMemoryTransport(input: w.bytes)
    await #expect(throws: SpiceError.self) {
        _ = try await LinkHandshake.perform(on: t, connectionID: 0, channel: .init(type: .main, id: 0), channelCaps: CapabilitySet(), password: nil)
    }
}
```

Add this test helper to `Tests/SpiceCoreTests/TestSupport.swift`:
```swift
import SpiceWire
extension SpiceReader {
    func u32Unchecked() -> UInt32 { var c = self; return (try? c.u32()) ?? 0 }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LinkHandshakeTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

`LinkHandshake.swift`:
```swift
import SpiceWire

public struct LinkResult: Sendable {
    public var serverCommonCaps: CapabilitySet
    public var serverChannelCaps: CapabilitySet
    public var miniHeader: Bool
}

public enum LinkHandshake {
    public static func clientCommonCaps() -> CapabilitySet {
        CapabilitySet(bits: [CommonCap.authSpice, CommonCap.miniHeader])
    }

    public static func perform(on t: any Transport, connectionID: UInt32, channel: ChannelDescriptor,
                               channelCaps: CapabilitySet, password: String?) async throws -> LinkResult {
        let mess = SpiceLinkMess(connectionID: connectionID, channelType: channel.type, channelID: channel.id,
                                 commonCaps: clientCommonCaps(), channelCaps: channelCaps)
        try await t.write(mess.encode())

        var hdr = SpiceReader(try await t.read(exactly: 16))
        let size: Int
        do { size = try SpiceLinkReply.parseHeader(&hdr) } catch let e as WireError { throw SpiceError(.protocolError(e), channel: channel) }
        var body = SpiceReader(try await t.read(exactly: size))
        let reply: SpiceLinkReply
        do { reply = try SpiceLinkReply(reader: &body) } catch let e as WireError { throw SpiceError(.protocolError(e), channel: channel) }
        guard reply.error == .ok else { throw SpiceError(.link(reply.error), channel: channel) }

        if reply.commonCaps.contains(CommonCap.protocolAuthSelection) {
            var w = SpiceWriter(); w.u32(CommonCap.authSpice)
            try await t.write(w.bytes)
        }
        try await t.write(try Ticket.encrypt(password: password ?? "", publicKey: reply.publicKey))

        var res = SpiceReader(try await t.read(exactly: 4))
        let code = try res.u32()
        guard code == 0 else { throw SpiceError(.link(LinkError(rawValue: code) ?? .error), channel: channel) }

        return LinkResult(serverCommonCaps: reply.commonCaps, serverChannelCaps: reply.channelCaps,
                          miniHeader: reply.commonCaps.contains(CommonCap.miniHeader))
    }
}
```

> Servers with `disable-ticketing` still expect the 128-byte ticket; the empty password encrypts to a valid blob. Do not special-case it.

- [ ] **Step 4: Run tests**

Run: `swift test --filter LinkHandshakeTests`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): link handshake with auth selection and ticket"
```

---

### Task 10: ChannelReader message loop

**Files:**
- Create: `Sources/SpiceCore/ChannelReader.swift`
- Test: `Tests/SpiceCoreTests/ChannelReaderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RawMessage: Sendable, Equatable { public var type: UInt16; public var payload: [UInt8] }
  /// Reads data headers + payloads from `source`, auto-replies to SET_ACK (ACK_SYNC + periodic ACK) and PING (PONG) on `sink`,
  /// and yields every other message. Finishes the stream on error/EOF.
  public actor ChannelReader {
      public init(source: any ByteSource, sink: any ByteSink, miniHeader: Bool, channel: ChannelDescriptor)
      public nonisolated var messages: AsyncStream<RawMessage> { get }
      public func run() async   // the loop; call in a Task
      public func send(type: UInt16, payload: [UInt8]) async throws   // frames with header + serial
      public var lastRTTMillis: Double? { get }
  }
  ```

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import SpiceWire
@testable import SpiceCore

private func msg(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
    ClientMessage.frame(type: type, payload: payload, mini: true, serial: 0)
}

@Test func yieldsMessagesAndAnswersSetAckAndPing() async throws {
    var setAck = SpiceWriter(); setAck.u32(3); setAck.u32(2)   // generation 3, window 2
    var ping = SpiceWriter(); ping.u32(11); ping.u64(99)
    let input = msg(CommonServerMsg.setAck.rawValue, setAck.bytes)
              + msg(103, [1]) + msg(104, [2]) + msg(105, [3])
              + msg(CommonServerMsg.ping.rawValue, ping.bytes)
    let t = InMemoryTransport(input: input)
    let reader = ChannelReader(source: t, sink: t, miniHeader: true, channel: .init(type: .main, id: 0))
    let task = Task { await reader.run() }
    var got: [RawMessage] = []
    for await m in reader.messages { got.append(m) }
    await task.value

    #expect(got == [RawMessage(type: 103, payload: [1]), RawMessage(type: 104, payload: [2]), RawMessage(type: 105, payload: [3])])
    let written = await t.written
    // ACK_SYNC(gen 3), then ACK after every 2 messages (after 104), then PONG
    var expected = msg(CommonClientMsg.ackSync.rawValue, [3, 0, 0, 0])
    expected += msg(CommonClientMsg.ack.rawValue, [])
    expected += msg(CommonClientMsg.pong.rawValue, ping.bytes)
    #expect(written == expected)
}

@Test func fullHeaderMode() async throws {
    let input = ClientMessage.frame(type: 103, payload: [7], mini: false, serial: 1)
    let t = InMemoryTransport(input: input)
    let reader = ChannelReader(source: t, sink: t, miniHeader: false, channel: .init(type: .main, id: 0))
    Task { await reader.run() }
    var got: [RawMessage] = []
    for await m in reader.messages { got.append(m) }
    #expect(got == [RawMessage(type: 103, payload: [7])])
}

@Test func oversizedHeaderEndsStream() async throws {
    var w = SpiceWriter(); w.u16(103); w.u32(0xFFFF_FFFF)
    let t = InMemoryTransport(input: w.bytes)
    let reader = ChannelReader(source: t, sink: t, miniHeader: true, channel: .init(type: .main, id: 0))
    Task { await reader.run() }
    var count = 0
    for await _ in reader.messages { count += 1 }
    #expect(count == 0)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ChannelReaderTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

```swift
import Foundation
import os
import SpiceWire

public struct RawMessage: Sendable, Equatable {
    public var type: UInt16
    public var payload: [UInt8]
    public init(type: UInt16, payload: [UInt8]) { self.type = type; self.payload = payload }
}

public actor ChannelReader {
    public static let maxMessageSize = 64 << 20

    private let source: any ByteSource
    private let sink: any ByteSink
    private let miniHeader: Bool
    private let channel: ChannelDescriptor
    private let log = Logger(subsystem: "com.spicesee", category: "channel")
    private let continuation: AsyncStream<RawMessage>.Continuation
    public nonisolated let messages: AsyncStream<RawMessage>

    private var serial: UInt64 = 1
    private var ackWindow: UInt32 = 0
    private var sinceAck: UInt32 = 0
    public private(set) var lastRTTMillis: Double?

    public init(source: any ByteSource, sink: any ByteSink, miniHeader: Bool, channel: ChannelDescriptor) {
        self.source = source; self.sink = sink; self.miniHeader = miniHeader; self.channel = channel
        (messages, continuation) = AsyncStream.makeStream(of: RawMessage.self)
    }

    public func send(type: UInt16, payload: [UInt8]) async throws {
        try await sink.write(ClientMessage.frame(type: type, payload: payload, mini: miniHeader, serial: serial))
        serial += 1
    }

    public func run() async {
        defer { continuation.finish() }
        do {
            while !Task.isCancelled {
                let header = try await readHeader()
                guard header.size <= Self.maxMessageSize else {
                    log.error("\(self.channel.type.rawValue)/\(self.channel.id): message size \(header.size) exceeds limit")
                    return
                }
                let payload = try await source.read(exactly: Int(header.size))
                if try await handleCommon(type: header.type, payload: payload) { continue }
                continuation.yield(RawMessage(type: header.type, payload: payload))
                if ackWindow > 0 {
                    sinceAck += 1
                    if sinceAck >= ackWindow { sinceAck = 0; try await send(type: CommonClientMsg.ack.rawValue, payload: ClientMessage.ack()) }
                }
            }
        } catch {
            log.info("\(self.channel.type.rawValue)/\(self.channel.id): loop ended: \(String(describing: error))")
        }
    }

    private func readHeader() async throws -> DataHeader {
        if miniHeader {
            var r = SpiceReader(try await source.read(exactly: DataHeader.miniSize)); return try DataHeader(mini: &r)
        } else {
            var r = SpiceReader(try await source.read(exactly: DataHeader.fullSize)); return try DataHeader(full: &r)
        }
    }

    /// Returns true if the message was consumed here.
    private func handleCommon(type: UInt16, payload: [UInt8]) async throws -> Bool {
        var r = SpiceReader(payload)
        switch CommonServerMsg(rawValue: type) {
        case .setAck:
            let a = try SetAck(reader: &r)
            ackWindow = a.window; sinceAck = 0
            try await send(type: CommonClientMsg.ackSync.rawValue, payload: ClientMessage.ackSync(generation: a.generation))
            return true
        case .ping:
            let p = try Ping(reader: &r)
            let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            if p.timestamp > 0, now > p.timestamp { lastRTTMillis = Double(now - p.timestamp) / 1000 }
            try await send(type: CommonClientMsg.pong.rawValue, payload: ClientMessage.pong(p))
            return true
        case .notify:
            let n = try Notify(reader: &r)
            log.notice("server notify (\(n.severity)): \(n.message)")
            return true
        case .disconnecting:
            log.notice("server disconnecting")
            return false
        default:
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ChannelReaderTests`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): channel read loop with ack window and ping/pong"
```

---

### Task 11: MainChannel actor

**Files:**
- Create: `Sources/SpiceCore/MainChannel.swift`
- Test: `Tests/SpiceCoreTests/MainChannelTests.swift`

**Interfaces:**
- Consumes: `LinkHandshake.perform`, `ChannelReader`, `MainMessage`.
- Produces:
  ```swift
  public struct SessionInfo: Sendable { public var connectionID: UInt32; public var mainInit: MainInit; public var channels: [ChannelDescriptor] }
  public actor MainChannel {
      /// Link, wait for MAIN_INIT, send ATTACH_CHANNELS, wait for CHANNELS_LIST.
      public static func open(transport: any Transport, password: String?) async throws -> MainChannel
      public var info: SessionInfo { get }
      public nonisolated let events: AsyncStream<MainMessage>   // everything after CHANNELS_LIST
      public func requestMouseMode(_ mode: UInt32) async throws
  }
  ```

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Security
import SpiceWire
@testable import SpiceCore

@Test func mainChannelBringUp() async throws {
    var err: Unmanaged<CFError>?
    let priv = try #require(SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(try #require(SecKeyCopyPublicKey(priv)), &err)) as Data
    let spki = Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1))

    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(spki); w.u32(1); w.u32(0); w.u32(178); w.u32(1 << CommonCap.miniHeader | 1 << CommonCap.authSpice)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0)                                                        // link result
    var mi = SpiceWriter(); [42, 1, 3, 2, 0, 10, 0, 0].forEach { mi.u32(UInt32($0)) }
    w.bytes(ClientMessage.frame(type: MainServerMsg.init.rawValue, payload: mi.bytes, mini: true, serial: 0))
    var cl = SpiceWriter(); cl.u32(2); cl.u8(2); cl.u8(0); cl.u8(3); cl.u8(0)
    w.bytes(ClientMessage.frame(type: MainServerMsg.channelsList.rawValue, payload: cl.bytes, mini: true, serial: 0))
    var mm = SpiceWriter(); mm.u32(777)
    w.bytes(ClientMessage.frame(type: MainServerMsg.multiMediaTime.rawValue, payload: mm.bytes, mini: true, serial: 0))

    let t = InMemoryTransport(input: w.bytes)
    let main = try await MainChannel.open(transport: t, password: nil)
    let info = await main.info
    #expect(info.connectionID == 42)
    #expect(info.mainInit.agentTokens == 10)
    #expect(info.channels == [.init(type: .display, id: 0), .init(type: .inputs, id: 0)])

    var events: [MainMessage] = []
    for await e in main.events { events.append(e) }
    guard case let .multiMediaTime(m)? = events.first else { Issue.record("expected mm time"); return }
    #expect(m.time == 777)

    // ATTACH_CHANNELS was sent after MAIN_INIT
    let written = await t.written
    let attach = ClientMessage.frame(type: MainClientMsg.attachChannels.rawValue, payload: [], mini: true, serial: 1)
    #expect(written.suffix(attach.count) == ArraySlice(attach))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter MainChannelTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

```swift
import os
import SpiceWire

public struct SessionInfo: Sendable {
    public var connectionID: UInt32
    public var mainInit: MainInit
    public var channels: [ChannelDescriptor]
}

public actor MainChannel {
    public static let descriptor = ChannelDescriptor(type: .main, id: 0)
    public let info: SessionInfo
    public nonisolated let events: AsyncStream<MainMessage>
    private let reader: ChannelReader
    private let pump: Task<Void, Never>
    private let log = Logger(subsystem: "com.spicesee", category: "main")

    public static func open(transport: any Transport, password: String?) async throws -> MainChannel {
        let link = try await LinkHandshake.perform(on: transport, connectionID: 0, channel: descriptor,
                                                   channelCaps: CapabilitySet(), password: password)
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: descriptor)
        let loop = Task { await reader.run() }
        var iterator = reader.messages.makeAsyncIterator()

        func next() async throws -> MainMessage {
            guard let raw = await iterator.next() else { throw SpiceError(.closed, channel: descriptor) }
            do { return try MainMessage(type: raw.type, payload: raw.payload) }
            catch let e as WireError { throw SpiceError(.protocolError(e), channel: descriptor) }
        }

        guard case let .`init`(mainInit) = try await next() else { throw SpiceError(.protocolError(.unsupported("expected MAIN_INIT")), channel: descriptor) }
        try await reader.send(type: MainClientMsg.attachChannels.rawValue, payload: ClientMessage.attachChannels())

        var channels: [ChannelDescriptor] = []
        var pending: [MainMessage] = []
        while true {
            let m = try await next()
            if case let .channelsList(l) = m { channels = l.channels; break }
            pending.append(m)
        }
        let info = SessionInfo(connectionID: mainInit.sessionID, mainInit: mainInit, channels: channels)
        return MainChannel(info: info, reader: reader, loop: loop, iterator: iterator, pending: pending)
    }

    private init(info: SessionInfo, reader: ChannelReader, loop: Task<Void, Never>,
                 iterator: AsyncStream<RawMessage>.Iterator, pending: [MainMessage]) {
        self.info = info
        self.reader = reader
        let (stream, cont) = AsyncStream.makeStream(of: MainMessage.self)
        events = stream
        pump = Task {
            pending.forEach { cont.yield($0) }
            var it = iterator
            while let raw = await it.next() {
                if let m = try? MainMessage(type: raw.type, payload: raw.payload) { cont.yield(m) }
            }
            cont.finish()
            _ = await loop.value
        }
    }

    public func requestMouseMode(_ mode: UInt32) async throws {
        try await reader.send(type: MainClientMsg.mouseModeRequest.rawValue, payload: ClientMessage.mouseModeRequest(mode))
    }

    public func close() { pump.cancel() }
}
```

> If the compiler rejects capturing `iterator` (non-Sendable) into the `pump` task, move the pump into a `nonisolated` static helper that takes the `ChannelReader` and re-creates the iterator from `reader.messages` — an `AsyncStream` can only be iterated once, so in that case hold pending messages and consume via the same stream object rather than a copied iterator. Resolve whichever way compiles under strict concurrency; the test pins the behaviour.

- [ ] **Step 4: Run tests**

Run: `swift test --filter MainChannelTests`
Expected: 1 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): main channel bring-up (MAIN_INIT, ATTACH_CHANNELS, CHANNELS_LIST)"
```

---

### Task 12: M0 spike — dev server, spicerec, spicesee-cli

**Files:**
- Create: `scripts/dev-server.sh`, `Sources/spicerec/main.swift`, `Sources/spicesee-cli/main.swift` (replace placeholder), `docs/dev-server.md`

**Interfaces:**
- Produces: `spicerec <listen-port> <host> <port> <out-dir>` writes `<out-dir>/conn-N.s2c.bin` and `conn-N.c2s.bin` per accepted TCP connection (one per SPICE channel). `spicesee-cli connect <host> <port> [password]` prints `MAIN_INIT` fields and the channel list. `spicesee-cli dump <host> <port> [password] <out.png>` (filled in Task 16).

- [ ] **Step 1: Find where the dev server lives**

Run, in order, and record the outcome in `docs/dev-server.md`:
```bash
brew install qemu
qemu-system-x86_64 -spice help 2>&1 | head -3
```
If the second command prints SPICE options (not "Unknown option"), Homebrew QEMU has SPICE support — write `scripts/dev-server.sh` as:
```bash
#!/bin/sh
# Boots a tiny Linux ISO with a QXL display and SPICE on :5900, no ticket.
set -e
ISO=${ISO:-$HOME/.cache/spicesee/alpine-virt.iso}
mkdir -p "$(dirname "$ISO")"
[ -f "$ISO" ] || curl -L -o "$ISO" https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-virt-3.21.0-x86_64.iso
exec qemu-system-x86_64 -m 1024 -cdrom "$ISO" -boot d \
  -vga qxl -spice port=5900,addr=127.0.0.1,disable-ticketing=on \
  -device virtio-serial-pci -chardev spicevmc,id=vdagent,name=vdagent \
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 "$@"
```
If it prints "Unknown option" (expected — Homebrew builds without `--enable-spice`), the dev server is a Linux VM. Write `scripts/dev-server.sh` to drive Lima:
```bash
#!/bin/sh
# Runs the SPICE dev server inside a Lima Ubuntu VM. Port 5900 is forwarded to the host.
set -e
brew list lima >/dev/null 2>&1 || brew install lima
limactl list -q | grep -qx spicesee || limactl start --name=spicesee --tty=false \
  --set '.portForwards=[{"guestPort":5900,"hostPort":5900}]' template://ubuntu-lts
limactl shell spicesee sudo apt-get install -y qemu-system-x86 2>/dev/null
limactl shell spicesee sh -c '
  ISO=$HOME/alpine-virt.iso
  [ -f $ISO ] || curl -L -o $ISO https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-virt-3.21.0-x86_64.iso
  exec qemu-system-x86_64 -m 1024 -cdrom $ISO -boot d -vga qxl \
    -spice port=5900,addr=0.0.0.0,disable-ticketing=on \
    -device virtio-serial-pci -chardev spicevmc,id=vdagent,name=vdagent \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0'
```
Either way: `chmod +x scripts/dev-server.sh`, run it, confirm with `nc -vz 127.0.0.1 5900`.

- [ ] **Step 2: Write spicerec**

`Sources/spicerec/main.swift`:
```swift
import Foundation
import Network

let args = CommandLine.arguments
guard args.count == 5, let listen = UInt16(args[1]), let upstreamPort = UInt16(args[3]) else {
    print("usage: spicerec <listen-port> <upstream-host> <upstream-port> <out-dir>"); exit(2)
}
let upstreamHost = args[2], outDir = args[4]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let queue = DispatchQueue(label: "spicerec")
var count = 0

func pump(_ from: NWConnection, _ to: NWConnection, _ file: FileHandle) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
        if let data, !data.isEmpty {
            file.write(data)
            to.send(content: data, completion: .contentProcessed { _ in pump(from, to, file) })
        } else if done || error != nil {
            to.cancel(); file.closeFile()
        }
    }
}

let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: listen)!)
listener.newConnectionHandler = { client in
    count += 1
    let n = count
    let s2c = "\(outDir)/conn-\(n).s2c.bin", c2s = "\(outDir)/conn-\(n).c2s.bin"
    FileManager.default.createFile(atPath: s2c, contents: nil); FileManager.default.createFile(atPath: c2s, contents: nil)
    let server = NWConnection(host: NWEndpoint.Host(upstreamHost), port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
    server.stateUpdateHandler = { state in
        if case .ready = state {
            print("conn \(n): proxying")
            pump(client, server, FileHandle(forWritingAtPath: c2s)!)
            pump(server, client, FileHandle(forWritingAtPath: s2c)!)
        }
    }
    client.start(queue: queue); server.start(queue: queue)
}
listener.start(queue: queue)
print("spicerec listening on \(listen) -> \(upstreamHost):\(upstreamPort), writing \(outDir)")
dispatchMain()
```

- [ ] **Step 3: Write spicesee-cli connect**

`Sources/spicesee-cli/main.swift`:
```swift
import Foundation
import SpiceCore
import SpiceWire

let args = CommandLine.arguments
guard args.count >= 4, args[1] == "connect", let port = UInt16(args[3]) else {
    print("usage: spicesee-cli connect <host> <port> [password]"); exit(2)
}
let password = args.count > 4 ? args[4] : nil

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let t = try await NWTransport.connect(host: args[2], port: port)
        let main = try await MainChannel.open(transport: t, password: password)
        let info = await main.info
        print("MAIN_INIT session=\(info.mainInit.sessionID) mouse=\(info.mainInit.currentMouseMode) agent=\(info.mainInit.agentConnected) tokens=\(info.mainInit.agentTokens) mmtime=\(info.mainInit.multiMediaTime)")
        print("channels: \(info.channels.map { "\($0.type)/\($0.id)" }.joined(separator: " "))")
    } catch {
        print("error: \(error)"); exit(1)
    }
    sem.signal()
}
sem.wait()
```

- [ ] **Step 4: Verify M0 exit criterion**

Run, with the dev server up:
```bash
swift run spicesee-cli connect 127.0.0.1 5900
```
Expected: `MAIN_INIT session=... mouse=...` and `channels: display/0 inputs/0 cursor/0 playback/0 record/0`. Paste the actual output into `docs/dev-server.md`.

- [ ] **Step 5: Record a fixture for later tasks**

```bash
mkdir -p recordings/alpine-boot
swift run spicerec 5901 127.0.0.1 5900 recordings/alpine-boot &
# connect a reference client through the proxy so the recording is complete:
brew install --cask utm 2>/dev/null; # or use remote-viewer from a Linux VM, or spicy from `brew install spice-gtk`
remote-viewer spice://127.0.0.1:5901   # let the Alpine login prompt render, then quit
kill %1
ls -la recordings/alpine-boot
```
Note which `conn-N` is the display channel (its `c2s.bin` begins with the link mess whose byte 20 is `0x02`). Copy `conn-N.s2c.bin` to `Tests/SpiceKitTests/Fixtures/alpine-display.s2c.bin` and the main channel's to `Tests/SpiceKitTests/Fixtures/alpine-main.s2c.bin`. If `remote-viewer` is unavailable on macOS, record from inside the Lima VM instead (`apt-get install virt-viewer`, run spicerec there, copy files out with `limactl copy`).

> Recording a reference client (not our own) means the fixture exercises caps we also advertise (MINI_HEADER) — check the display `c2s.bin` caps words and, if the reference client lacked MINI_HEADER, the replay test in Task 15 must pass `miniHeader: false`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: M0 spike — dev server script, spicerec proxy, spicesee-cli connect"
```

---

### Task 13: CSpiceCodec — vendored QUIC, LZ, GLZ behind a C API

**Files:**
- Create: `Sources/CSpiceCodec/vendor/**` (fetched), `Sources/CSpiceCodec/shim/config.h`, `Sources/CSpiceCodec/shim/spice_common.h`, `Sources/CSpiceCodec/include/spice_codec.h`, `Sources/CSpiceCodec/codec_bridge.c`, `Sources/CSpiceCodec/LICENSE.LGPL-2.1`, `Sources/CSpiceCodec/VENDORED.md`
- Test: `Tests/SpiceCanvasTests/CodecTests.swift`

**Interfaces:**
- Produces (`spice_codec.h`):
  ```c
  typedef enum { SC_IMAGE_INVALID = 0, SC_IMAGE_GRAY, SC_IMAGE_RGB16, SC_IMAGE_RGB24, SC_IMAGE_RGB32, SC_IMAGE_RGBA,
                 SC_IMAGE_PLT1_LE, SC_IMAGE_PLT1_BE, SC_IMAGE_PLT4_LE, SC_IMAGE_PLT4_BE, SC_IMAGE_PLT8, SC_IMAGE_XXXA } sc_image_type;
  typedef struct sc_quic sc_quic;
  sc_quic *sc_quic_create(void);
  void     sc_quic_destroy(sc_quic *);
  /* 0 on success, <0 on corrupt input. Fills width/height/type. */
  int      sc_quic_begin(sc_quic *, const uint8_t *data, size_t len, int *width, int *height, sc_image_type *type);
  /* Writes BGRA (RGB32) or BGRA-with-alpha (RGBA) rows into out; stride may be negative for bottom-up. */
  int      sc_quic_decode(sc_quic *, uint8_t *out, int stride);
  /* Test helper: encodes 32bpp BGRA rows. Returns bytes written or <0. */
  int      sc_quic_encode_rgb32(const uint8_t *pixels, int width, int height, int stride, uint8_t *out, size_t out_cap);

  typedef struct sc_lz sc_lz;
  sc_lz   *sc_lz_create(void);
  void     sc_lz_destroy(sc_lz *);
  /* palette: up to 256 BGRx entries for PLT types, may be NULL otherwise. */
  int      sc_lz_begin(sc_lz *, const uint8_t *data, size_t len, const uint32_t *palette, int palette_count,
                       int *width, int *height, sc_image_type *type, int *top_down);
  /* out must hold width*height*4 bytes; written as RGB32 (or RGBA when type is RGBA). */
  int      sc_lz_decode(sc_lz *, uint8_t *out);
  int      sc_lz_encode_rgb32(const uint8_t *pixels, int width, int height, int stride, uint8_t *out, size_t out_cap);

  typedef struct sc_glz_window sc_glz_window;
  typedef struct sc_glz sc_glz;
  sc_glz_window *sc_glz_window_create(void);
  void           sc_glz_window_clear(sc_glz_window *);
  void           sc_glz_window_destroy(sc_glz_window *);
  sc_glz  *sc_glz_create(sc_glz_window *);
  void     sc_glz_destroy(sc_glz *);
  /* On success *out points at BGRA pixels owned by the window; copy before the next decode. */
  int      sc_glz_decode(sc_glz *, const uint8_t *data, size_t len, const uint8_t **out, int *width, int *height, int *stride);
  ```

- [ ] **Step 1: Fetch pinned sources**

```bash
cd "$(mktemp -d)" && git clone --depth 1 --branch v0.42 --recurse-submodules https://gitlab.freedesktop.org/spice/spice-gtk.git
V=/Users/aaronpollock/code/spicesee/Sources/CSpiceCodec/vendor
mkdir -p $V/common $V/spice
C=spice-gtk/subprojects/spice-common
cp $C/common/quic.c $C/common/quic.h $C/common/quic_config.h $C/common/quic_family_tmpl.c $C/common/quic_rgb_tmpl.c $C/common/quic_tmpl.c $V/common/
cp $C/common/lz.c $C/common/lz.h $C/common/lz_common.h $C/common/lz_config.h $C/common/lz_compress_tmpl.c $C/common/lz_decompress_tmpl.c $V/common/
cp $C/common/bitops.h $C/common/macros.h $V/common/ 2>/dev/null || true
cp $C/spice-protocol/spice/macros.h $C/spice-protocol/spice/types.h $C/spice-protocol/spice/draw.h $C/spice-protocol/spice/enums.h $C/spice-protocol/spice/start-packed.h $C/spice-protocol/spice/end-packed.h $V/spice/
cp spice-gtk/src/decode-glz.c spice-gtk/src/decode-glz-tmpl.c spice-gtk/src/decode.h $V/
cp $C/COPYING $V/../LICENSE.LGPL-2.1 2>/dev/null || cp spice-gtk/COPYING $V/../LICENSE.LGPL-2.1
git -C spice-gtk rev-parse HEAD; git -C $C rev-parse HEAD
```
Write `Sources/CSpiceCodec/VENDORED.md` listing each file, its origin repo, tag `v0.42`, both commit hashes, and the local modifications from Step 2 (this is the LGPL source-publication record).

**Copy these files verbatim — never strip or reflow the header comments.** Every vendored `.c`/`.h`
carries an upstream copyright line and licence grant, and those notices are the LGPL obligation, not
decoration. Reformatters, "tidy the imports" passes, and hand-retyping a file all quietly remove
them. Step 2's shims and the GLZ accessor in Step 5 are the only edits permitted inside `vendor/`,
and neither touches a header block. Step 7 verifies this held.

- [ ] **Step 2: Shim out glib and pixman**

`shim/config.h`: empty file (the sources `#include <config.h>`).

`shim/spice_common.h` (also save copies as `shim/spice-common.h` and `shim/common/log.h`, `shim/common/mem.h` so every include spelling the vendored files use resolves here — check with `grep -h '#include' vendor/common/*.c vendor/*.c | sort -u` and add a forwarding header per spelling):
```c
#ifndef SC_SHIM_H
#define SC_SHIM_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <setjmp.h>
#include <spice/macros.h>

/* Fatal-path trampoline: codec_bridge.c installs a jmp_buf before every decode. */
extern _Thread_local jmp_buf *sc_fatal_env;
void sc_fatal(const char *fmt, ...);

#define spice_error(...)   sc_fatal(__VA_ARGS__)
#define spice_critical(...) sc_fatal(__VA_ARGS__)
#define spice_warning(...) ((void)0)
#define spice_debug(...)   ((void)0)
#define spice_info(...)    ((void)0)
#define spice_assert(x)    do { if (!(x)) sc_fatal("assert: " #x); } while (0)
#define spice_return_if_fail(x) do { if (!(x)) return; } while (0)
#define spice_return_val_if_fail(x, v) do { if (!(x)) return (v); } while (0)

#define spice_malloc(n)      malloc(n)
#define spice_malloc0(n)     calloc(1, (n))
#define spice_free(p)        free(p)
#define spice_new(t, n)      ((t *)malloc(sizeof(t) * (n)))
#define spice_new0(t, n)     ((t *)calloc((n), sizeof(t)))
#define spice_realloc(p, n)  realloc((p), (n))
#define g_malloc(n)          malloc(n)
#define g_malloc0(n)         calloc(1, (n))
#define g_free(p)            free(p)
#define g_new(t, n)          spice_new(t, n)
#define g_new0(t, n)         spice_new0(t, n)
#define g_warning(...)       ((void)0)
#define g_return_if_fail(x)  spice_return_if_fail(x)
#define g_return_val_if_fail(x, v) spice_return_val_if_fail(x, v)
#define G_GNUC_UNUSED        __attribute__((unused))
#define SPICE_GNUC_UNUSED    __attribute__((unused))
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#endif
```

Then edit `vendor/decode-glz.c` (record every change in `VENDORED.md`):
1. Remove `#include <glib.h>`, `#include <pixman.h>`, and the `spice-util`/`spice-common` includes; add `#include "spice_common.h"` and `#include "decode.h"`.
2. `struct glz_image` holds a `pixman_image_t *surface`. Replace with `uint8_t *data; int width, height, stride;`. In `glz_image_new`, replace `pixman_image_create_bits(...)` with `img->stride = width * 4; img->data = malloc((size_t)img->stride * height);` (keep the `gross_pixels`/`id` bookkeeping). In `glz_image_destroy`, `free(img->data)`. Where the template writes decoded pixels, the destination pointer came from `pixman_image_get_data(...)` — replace with `img->data`.
3. Any `GMutex`/`g_mutex_*` becomes a no-op (single decoder per window, driven from one actor).
4. Where `decode()` signals the result back (spice-gtk calls `glz_decoder_window_bind`/`glz_image_new` with `usr_data` being the destination), make the last decoded image reachable: add `struct glz_image *last;` to `SpiceGlzDecoderWindow` and set it in `glz_decoder_window_add`.

`vendor/common/quic.c` and `lz.c` should need no edits beyond the shim; if `#include "common/xyz.h"` spellings appear, add the forwarding headers under `shim/common/` rather than editing the vendored files.

- [ ] **Step 3: Write the failing test**

`Tests/SpiceCanvasTests/CodecTests.swift`:
```swift
import Testing
import CSpiceCodec

private func gradient(_ w: Int, _ h: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0 ..< h { for x in 0 ..< w {
        let i = (y * w + x) * 4
        p[i] = UInt8(x & 0xFF); p[i + 1] = UInt8(y & 0xFF); p[i + 2] = UInt8((x + y) & 0xFF); p[i + 3] = 0xFF
    } }
    return p
}

@Test func quicRoundTripsRGB32() throws {
    let (w, h) = (37, 23)
    let src = gradient(w, h)
    var enc = [UInt8](repeating: 0, count: 1 << 20)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in
        sc_quic_encode_rgb32(s.baseAddress, Int32(w), Int32(h), Int32(w * 4), e.baseAddress, e.count) } }
    #expect(n > 0)
    let ctx = sc_quic_create()!; defer { sc_quic_destroy(ctx) }
    var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID
    #expect(enc.withUnsafeBufferPointer { sc_quic_begin(ctx, $0.baseAddress, Int(n), &ow, &oh, &type) } == 0)
    #expect(ow == Int32(w) && oh == Int32(h) && type == SC_IMAGE_RGB32)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    #expect(out.withUnsafeMutableBufferPointer { sc_quic_decode(ctx, $0.baseAddress, Int32(w * 4)) } == 0)
    for i in stride(from: 0, to: out.count, by: 4) { #expect(out[i ..< i + 3] == src[i ..< i + 3]) }  // alpha byte is undefined for RGB32
}

@Test func quicRejectsGarbage() {
    let ctx = sc_quic_create()!; defer { sc_quic_destroy(ctx) }
    var w: Int32 = 0, h: Int32 = 0, t = SC_IMAGE_INVALID
    let junk = [UInt8](repeating: 0xA5, count: 64)
    #expect(junk.withUnsafeBufferPointer { sc_quic_begin(ctx, $0.baseAddress, 64, &w, &h, &t) } < 0)
}

@Test func lzRoundTripsRGB32() throws {
    let (w, h) = (40, 9)
    let src = gradient(w, h)
    var enc = [UInt8](repeating: 0, count: 1 << 20)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in
        sc_lz_encode_rgb32(s.baseAddress, Int32(w), Int32(h), Int32(w * 4), e.baseAddress, e.count) } }
    #expect(n > 0)
    let ctx = sc_lz_create()!; defer { sc_lz_destroy(ctx) }
    var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID, topDown: Int32 = 0
    #expect(enc.withUnsafeBufferPointer { sc_lz_begin(ctx, $0.baseAddress, Int(n), nil, 0, &ow, &oh, &type, &topDown) } == 0)
    #expect(ow == Int32(w) && oh == Int32(h))
    var out = [UInt8](repeating: 0, count: w * h * 4)
    #expect(out.withUnsafeMutableBufferPointer { sc_lz_decode(ctx, $0.baseAddress) } == 0)
    for i in stride(from: 0, to: out.count, by: 4) { #expect(out[i ..< i + 3] == src[i ..< i + 3]) }
}

@Test func glzWindowLifecycle() {
    let win = sc_glz_window_create()!
    let dec = sc_glz_create(win)!
    var out: UnsafePointer<UInt8>? = nil; var w: Int32 = 0, h: Int32 = 0, s: Int32 = 0
    let junk = [UInt8](repeating: 0xFF, count: 32)
    #expect(junk.withUnsafeBufferPointer { sc_glz_decode(dec, $0.baseAddress, 32, &out, &w, &h, &s) } < 0)
    sc_glz_destroy(dec); sc_glz_window_destroy(win)
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --filter CodecTests`
Expected: link errors for `sc_quic_*`.

- [ ] **Step 5: Implement the bridge**

`codec_bridge.c` (QUIC and LZ parts; the usr-context pattern is the same for both):
```c
#include "spice_codec.h"
#include "spice_common.h"
#include "common/quic.h"
#include "common/lz.h"
#include "decode.h"
#include <stdarg.h>

_Thread_local jmp_buf *sc_fatal_env;
void sc_fatal(const char *fmt, ...) {
    (void)fmt;
    if (sc_fatal_env) longjmp(*sc_fatal_env, 1);
    abort();
}
#define SC_GUARD(env) jmp_buf env; jmp_buf *sc_prev = sc_fatal_env; sc_fatal_env = &env; \
    if (setjmp(env)) { sc_fatal_env = sc_prev; return -1; }
#define SC_UNGUARD() sc_fatal_env = sc_prev

/* ---- QUIC ---- */
struct sc_quic { QuicUsrContext usr; QuicContext *ctx; QuicImageType type; int width, height; };

static void q_error(QuicUsrContext *u, const char *fmt, ...) { (void)u; sc_fatal(fmt); }
static void q_warn(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void q_info(QuicUsrContext *u, const char *fmt, ...) { (void)u; (void)fmt; }
static void *q_malloc(QuicUsrContext *u, int n) { (void)u; return malloc(n); }
static void q_free(QuicUsrContext *u, void *p) { (void)u; free(p); }
static int q_more_space(QuicUsrContext *u, uint32_t **io, int rows_completed) { (void)u; (void)io; (void)rows_completed; return 0; }
static int q_more_lines(QuicUsrContext *u, uint8_t **lines) { (void)u; (void)lines; return 0; }

sc_quic *sc_quic_create(void) {
    sc_quic *q = calloc(1, sizeof *q);
    q->usr.error = q_error; q->usr.warn = q_warn; q->usr.info = q_info;
    q->usr.malloc = q_malloc; q->usr.free = q_free;
    q->usr.more_space = q_more_space; q->usr.more_lines = q_more_lines;
    q->ctx = quic_create(&q->usr);
    return q;
}
void sc_quic_destroy(sc_quic *q) { if (q) { quic_destroy(q->ctx); free(q); } }

static sc_image_type from_quic(QuicImageType t) {
    switch (t) { case QUIC_IMAGE_TYPE_GRAY: return SC_IMAGE_GRAY; case QUIC_IMAGE_TYPE_RGB16: return SC_IMAGE_RGB16;
        case QUIC_IMAGE_TYPE_RGB24: return SC_IMAGE_RGB24; case QUIC_IMAGE_TYPE_RGB32: return SC_IMAGE_RGB32;
        case QUIC_IMAGE_TYPE_RGBA: return SC_IMAGE_RGBA; default: return SC_IMAGE_INVALID; }
}

int sc_quic_begin(sc_quic *q, const uint8_t *data, size_t len, int *w, int *h, sc_image_type *type) {
    SC_GUARD(env);
    int r = quic_decode_begin(q->ctx, (uint32_t *)data, (unsigned)(len / 4), &q->type, &q->width, &q->height);
    SC_UNGUARD();
    if (r != QUIC_OK) return -1;
    *w = q->width; *h = q->height; *type = from_quic(q->type);
    return *type == SC_IMAGE_INVALID ? -1 : 0;
}
int sc_quic_decode(sc_quic *q, uint8_t *out, int stride) {
    SC_GUARD(env);
    QuicImageType to = q->type == QUIC_IMAGE_TYPE_RGBA ? QUIC_IMAGE_TYPE_RGBA : QUIC_IMAGE_TYPE_RGB32;
    int r = quic_decode(q->ctx, to, out, stride);
    SC_UNGUARD();
    return r == QUIC_OK ? 0 : -1;
}
int sc_quic_encode_rgb32(const uint8_t *px, int w, int h, int stride, uint8_t *out, size_t cap) {
    sc_quic *q = sc_quic_create();
    uint8_t **lines = malloc(sizeof(uint8_t *) * h);
    for (int y = 0; y < h; y++) lines[y] = (uint8_t *)px + (size_t)y * stride;
    SC_GUARD(env);
    int words = quic_encode(q->ctx, QUIC_IMAGE_TYPE_RGB32, w, h, lines[0], h, stride, (uint32_t *)out, (unsigned)(cap / 4));
    SC_UNGUARD();
    free(lines); sc_quic_destroy(q);
    return words > 0 ? words * 4 : -1;
}
```
The LZ section mirrors it with `LzUsrContext` (`error/warn/info/malloc/free/more_space/more_lines`), `lz_create/lz_destroy`, `lz_decode_begin(ctx, (uint8_t*)data, len, &type, &w, &h, &n_pixels, &top_down, palette)` where `palette` is a `SpicePalette` built from the caller's entries (`spice_malloc` a `SpicePalette` with `num_ents` and copy), and `lz_decode(ctx, to_type, out)` with `to_type = LZ_IMAGE_TYPE_RGBA` for RGBA sources else `LZ_IMAGE_TYPE_RGB32`. `sc_lz_encode_rgb32` calls `lz_encode(ctx, LZ_IMAGE_TYPE_RGB32, w, h, lines, h, stride, out, cap)`, returning bytes. Map `LzImageType` → `sc_image_type` one-to-one (PLT1_LE…XXXA).

GLZ section:
```c
struct sc_glz_window { SpiceGlzDecoderWindow *w; };
struct sc_glz { SpiceGlzDecoder *d; sc_glz_window *win; };
sc_glz_window *sc_glz_window_create(void) { sc_glz_window *w = calloc(1, sizeof *w); w->w = glz_decoder_window_new(); return w; }
void sc_glz_window_clear(sc_glz_window *w) { glz_decoder_window_clear(w->w); }
void sc_glz_window_destroy(sc_glz_window *w) { if (w) { glz_decoder_window_destroy(w->w); free(w); } }
sc_glz *sc_glz_create(sc_glz_window *w) { sc_glz *g = calloc(1, sizeof *g); g->win = w; g->d = glz_decoder_new(w->w); return g; }
void sc_glz_destroy(sc_glz *g) { if (g) { glz_decoder_destroy(g->d); free(g); } }
int sc_glz_decode(sc_glz *g, const uint8_t *data, size_t len, const uint8_t **out, int *w, int *h, int *stride) {
    SC_GUARD(env);
    g->d->ops->decode(g->d, (uint8_t *)data, len, NULL, NULL);
    SC_UNGUARD();
    struct glz_image *img = glz_decoder_window_last(g->win->w);   /* add this accessor to decode-glz.c: returns window->last */
    if (!img) return -1;
    *out = img->data; *w = img->width; *h = img->height; *stride = img->stride;
    return 0;
}
```
Add `struct glz_image *glz_decoder_window_last(SpiceGlzDecoderWindow *w);` to `vendor/decode.h` and make `struct glz_image` visible there.

- [ ] **Step 6: Run tests**

Run: `swift test --filter CodecTests`
Expected: 4 pass. Build warnings from vendored C are acceptable; errors are not — fix by adding forwarding headers under `shim/`, never by editing `quic.c`/`lz.c`.

- [ ] **Step 7: Verify the licence notices survived**

The whole LGPL position rests on these notices being intact and on `VENDORED.md` naming the exact
upstream revision. Run this before committing — it must print nothing and exit 0:

```bash
cd Sources/CSpiceCodec
status=0
for f in $(find vendor -type f \( -name '*.c' -o -name '*.h' \)); do
  head -40 "$f" | grep -qiE 'copyright|SPDX-License-Identifier|General Public License' \
    || { echo "STRIPPED NOTICE: $f"; status=1; }
done
[ -s LICENSE.LGPL-2.1 ] || { echo "MISSING: LICENSE.LGPL-2.1"; status=1; }
for f in $(find vendor -type f \( -name '*.c' -o -name '*.h' \)); do
  grep -q "$(basename $f)" VENDORED.md || { echo "UNDISCLOSED: $f"; status=1; }
done
exit $status
```

Then read `VENDORED.md` once by eye for what the script cannot check: tag `v0.42`, both upstream
commit hashes from Step 1, and the Step 2/Step 5 modifications described in prose. A file on disk
but absent from that list is the failure mode that matters — undisclosed LGPL source in a shipped
binary.

Re-run this check after any later task edits `vendor/` (Task 14 may add accessors) and before
cutting a release DMG.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(codec): vendor QUIC/LZ/GLZ decoders (LGPL-2.1) behind spice_codec.h"
```

---

### Task 14: SpiceCanvas — surfaces, image decoding, tier-1 draws

**Files:**
- Create: `Sources/SpiceCanvas/DecodedImage.swift`, `Sources/SpiceCanvas/Surface.swift`, `Sources/SpiceCanvas/ImageCache.swift`, `Sources/SpiceCanvas/ImageDecoder.swift`, `Sources/SpiceCanvas/Tier1.swift`, `Sources/SpiceCanvas/Canvas.swift`, `Sources/SpiceCanvas/PNG.swift`
- Test: `Tests/SpiceCanvasTests/CanvasTests.swift`, `Tests/SpiceCanvasTests/ImageDecoderTests.swift`
- Delete: `Sources/SpiceCanvas/SpiceCanvas.swift`

**Interfaces:**
- Consumes: `DisplayMessage` and image types from `SpiceWire`; `sc_*` from `CSpiceCodec`.
- Produces:
  ```swift
  public struct DecodedImage: Sendable, Equatable { public var width: Int; public var height: Int; public var pixels: [UInt8] /* BGRA, stride = width*4, straight alpha */; public var hasAlpha: Bool
      public func pixel(x: Int, y: Int) -> UInt32 }                       // 0xAARRGGBB
  public struct SurfaceUpdate: Sendable { public var surfaceID: UInt32; public var surfaceWidth: Int; public var surfaceHeight: Int; public var rect: SpiceRect; public var pixels: [UInt8] /* rect.width*4 stride */; public var isPrimary: Bool }
  public struct SurfaceDescriptor: Sendable, Equatable { surfaceID: UInt32; width: Int; height: Int; isPrimary: Bool }
  public enum CanvasEvent: Sendable { case surfaceCreated(SurfaceDescriptor), surfaceDestroyed(UInt32), updated(SurfaceUpdate), unsupported(String) }
  public actor Canvas {
      public init()
      public nonisolated let events: AsyncStream<CanvasEvent>
      public func apply(_ message: DisplayMessage)          // never throws: decode errors → .unsupported event + skip
      public func snapshot(surfaceID: UInt32) -> DecodedImage?
      public var primarySurfaceID: UInt32? { get } }
  public enum PNG { public static func encode(_ image: DecodedImage) throws -> Data; public static func decode(_ data: Data) throws -> DecodedImage }
  ```

- [ ] **Step 1: Write failing tests**

`Tests/SpiceCanvasTests/CanvasTests.swift`:
```swift
import Testing
import SpiceWire
@testable import SpiceCanvas

private func create(_ w: UInt32, _ h: UInt32) -> DisplayMessage {
    var b = SpiceWriter(); b.u32(0); b.u32(w); b.u32(h); b.u32(32); b.u32(1)
    return try! DisplayMessage(type: DisplayServerMsg.surfaceCreate.rawValue, payload: b.bytes)
}
private func drawBase(_ w: inout SpiceWriter, _ box: SpiceRect, clip: [SpiceRect]? = nil) {
    w.u32(0); w.i32(box.top); w.i32(box.left); w.i32(box.bottom); w.i32(box.right)
    if let clip { w.u8(1); w.u32(UInt32(clip.count)); clip.forEach { w.i32($0.top); w.i32($0.left); w.i32($0.bottom); w.i32($0.right) } } else { w.u8(0) }
}
private func noMask(_ w: inout SpiceWriter) { w.u8(0); w.i32(0); w.i32(0); w.u32(0) }
private func fill(_ box: SpiceRect, color: UInt32, clip: [SpiceRect]? = nil) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box, clip: clip); w.u8(1); w.u32(color); w.u16(ROPD.opPut); noMask(&w)
    return try! DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes)
}
private func copyBitmap(_ box: SpiceRect, id: UInt64, flags: UInt8, pixels: [UInt8], w pw: UInt32, h ph: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(Int32(ph)); w.i32(Int32(pw)); w.u16(ROPD.opPut); w.u8(0); noMask(&w)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(id); w.u8(ImageType.bitmap.rawValue); w.u8(flags); w.u32(pw); w.u32(ph)
    w.u8(BitmapFormat.bit32.rawValue); w.u8(BitmapFlags.topDown); w.u32(pw); w.u32(ph); w.u32(pw * 4); w.u32(0); w.bytes(pixels)
    return try! DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
}
private func copyFromCache(_ box: SpiceRect, id: UInt64, w pw: UInt32, h ph: UInt32) -> DisplayMessage {
    var w = SpiceWriter(); drawBase(&w, box)
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(Int32(ph)); w.i32(Int32(pw)); w.u16(ROPD.opPut); w.u8(0); noMask(&w)
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(id); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(pw); w.u32(ph)
    return try! DisplayMessage(type: DisplayServerMsg.drawCopy.rawValue, payload: w.bytes)
}

@Test func surfaceCreateStartsBlack() async throws {
    let c = Canvas(); await c.apply(create(4, 4))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.width == 4 && s.pixel(x: 3, y: 3) == 0xFF000000)
}

@Test func fillClipsToBoxAndClipRects() async throws {
    let c = Canvas(); await c.apply(create(8, 8))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 8, right: 8), color: 0x00FF00, clip: [SpiceRect(top: 2, left: 2, bottom: 4, right: 4)]))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 2, y: 2) == 0xFF00FF00)
    #expect(s.pixel(x: 3, y: 3) == 0xFF00FF00)
    #expect(s.pixel(x: 4, y: 4) == 0xFF000000)
    #expect(s.pixel(x: 1, y: 2) == 0xFF000000)
}

@Test func copyBitmapThenFromCache() async throws {
    let c = Canvas(); await c.apply(create(8, 8))
    let px: [UInt8] = [0, 0, 255, 255,  0, 255, 0, 255,  255, 0, 0, 255,  255, 255, 255, 255]   // BGRA: red, green, blue, white
    await c.apply(copyBitmap(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), id: 9, flags: ImageFlags.cacheMe, pixels: px, w: 2, h: 2))
    await c.apply(copyFromCache(SpiceRect(top: 4, left: 4, bottom: 6, right: 6), id: 9, w: 2, h: 2))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 0, y: 0) == 0xFFFF0000)
    #expect(s.pixel(x: 1, y: 0) == 0xFF00FF00)
    #expect(s.pixel(x: 4, y: 4) == 0xFFFF0000)
    #expect(s.pixel(x: 5, y: 5) == 0xFFFFFFFF)
}

@Test func copyBitsMovesWithinSurface() async throws {
    let c = Canvas(); await c.apply(create(8, 8))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), color: 0xFF00FF))
    var w = SpiceWriter(); drawBase(&w, SpiceRect(top: 6, left: 6, bottom: 8, right: 8)); w.i32(0); w.i32(0)
    await c.apply(try DisplayMessage(type: DisplayServerMsg.copyBits.rawValue, payload: w.bytes))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 7, y: 7) == 0xFFFF00FF)
}

@Test func updatesAreEmittedPerDraw() async throws {
    let c = Canvas()
    await c.apply(create(8, 8))
    await c.apply(fill(SpiceRect(top: 1, left: 1, bottom: 3, right: 5), color: 0xFFFFFF))
    var it = c.events.makeAsyncIterator()
    guard case .surfaceCreated(let d)? = await it.next() else { Issue.record("expected created"); return }
    #expect(d.width == 8 && d.isPrimary)
    guard case .updated(let u)? = await it.next() else { Issue.record("expected update"); return }   // surfaceCreate also emits a full-rect update; accept either order for the first two
    #expect(u.surfaceID == 0)
}

@Test func unsupportedMessageEmitsEventAndKeepsGoing() async throws {
    let c = Canvas(); await c.apply(create(2, 2))
    await c.apply(.unsupported(type: 310, payload: []))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), color: 0x0000FF))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 1, y: 1) == 0xFF0000FF)
}

@Test func pngRoundTrip() throws {
    let img = DecodedImage(width: 2, height: 1, pixels: [0, 0, 255, 255, 0, 255, 0, 255], hasAlpha: false)
    let back = try PNG.decode(try PNG.encode(img))
    #expect(back.pixel(x: 0, y: 0) == 0xFFFF0000 && back.pixel(x: 1, y: 0) == 0xFF00FF00)
}
```

`Tests/SpiceCanvasTests/ImageDecoderTests.swift`:
```swift
import Testing
import SpiceWire
@testable import SpiceCanvas

private func img(_ type: ImageType, w: UInt32, h: UInt32, body: (inout SpiceWriter) -> Void) throws -> SpiceImage {
    var wr = SpiceWriter(); wr.u64(1); wr.u8(type.rawValue); wr.u8(0); wr.u32(w); wr.u32(h); body(&wr)
    return try SpiceImage(reader: SpiceReader(wr.bytes), base: SpiceReader(wr.bytes))
}

@Test func decodes24BitBottomUpBitmap() throws {
    let i = try img(.bitmap, w: 1, h: 2) { w in
        w.u8(BitmapFormat.bit24.rawValue); w.u8(0); w.u32(1); w.u32(2); w.u32(4); w.u32(0)   // stride 4 (padded)
        w.bytes([0, 0, 255, 0]); w.bytes([255, 0, 0, 0])      // row0 (bottom) red, row1 (top) blue
    }
    var d = ImageDecoder()
    let out = try d.decode(i, cache: nil)
    #expect(out.pixel(x: 0, y: 0) == 0xFF0000FF)   // top row = last in bottom-up data = blue
    #expect(out.pixel(x: 0, y: 1) == 0xFFFF0000)
}

@Test func decodes8BitPalette() throws {
    let i = try img(.bitmap, w: 2, h: 1) { w in
        w.u8(BitmapFormat.bit8.rawValue); w.u8(BitmapFlags.topDown); w.u32(2); w.u32(1); w.u32(2)
        let palPtr = w.bytes.count; w.u32(0)
        w.bytes([0, 1])
        w.patchU32(at: palPtr, UInt32(w.bytes.count))
        w.u64(5); w.u16(2); w.u32(0x00FF0000); w.u32(0x0000FF00)
    }
    var d = ImageDecoder()
    let out = try d.decode(i, cache: nil)
    #expect(out.pixel(x: 0, y: 0) == 0xFFFF0000 && out.pixel(x: 1, y: 0) == 0xFF00FF00)
}

@Test func decodesQuicViaCodec() throws {
    // Encode a 3x2 red image with the vendored encoder, then decode through ImageDecoder.
    let src: [UInt8] = Array(repeating: [0, 0, 255, 255], count: 6).flatMap { $0 }
    var enc = [UInt8](repeating: 0, count: 4096)
    let n = src.withUnsafeBufferPointer { s in enc.withUnsafeMutableBufferPointer { e in sc_quic_encode_rgb32(s.baseAddress, 3, 2, 12, e.baseAddress, e.count) } }
    let i = try img(.quic, w: 3, h: 2) { w in w.u32(UInt32(n)); w.bytes(Array(enc[0 ..< Int(n)])) }
    var d = ImageDecoder()
    #expect(try d.decode(i, cache: nil).pixel(x: 2, y: 1) == 0xFFFF0000)
}

@Test func fromCacheMissThrows() throws {
    let i = try img(.fromCache, w: 1, h: 1) { _ in }
    var d = ImageDecoder()
    var cache = ImageCache()
    #expect(throws: CanvasError.self) { _ = try d.decode(i, cache: cache) }
    _ = cache
}
```
(Import `CSpiceCodec` in that test file for `sc_quic_encode_rgb32`.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CanvasTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

`DecodedImage.swift`:
```swift
public struct DecodedImage: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]   // BGRA, tightly packed
    public var hasAlpha: Bool
    public init(width: Int, height: Int, pixels: [UInt8], hasAlpha: Bool) {
        self.width = width; self.height = height; self.pixels = pixels; self.hasAlpha = hasAlpha
    }
    public func pixel(x: Int, y: Int) -> UInt32 {
        let i = (y * width + x) * 4
        return UInt32(pixels[i + 3]) << 24 | UInt32(pixels[i + 2]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i])
    }
}

public enum CanvasError: Error, Sendable {
    case cacheMiss(UInt64), noSurface(UInt32), decode(String), unsupported(String)
}
```

`Surface.swift` (not Sendable; owned by the `Canvas` actor):
```swift
import SpiceWire

final class Surface {
    let id: UInt32
    let width: Int, height: Int
    let isPrimary: Bool
    let stride: Int
    var pixels: [UInt8]

    init(id: UInt32, width: Int, height: Int, isPrimary: Bool) {
        self.id = id; self.width = width; self.height = height; self.isPrimary = isPrimary
        stride = width * 4
        pixels = [UInt8](repeating: 0, count: stride * height)
        for i in Swift.stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 0xFF }
    }

    var bounds: SpiceRect { SpiceRect(top: 0, left: 0, bottom: Int32(height), right: Int32(width)) }

    func snapshot() -> DecodedImage { DecodedImage(width: width, height: height, pixels: pixels, hasAlpha: false) }

    func extract(_ r: SpiceRect) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(Int(r.width) * Int(r.height) * 4)
        for y in Int(r.top) ..< Int(r.bottom) {
            let s = y * stride + Int(r.left) * 4
            out.append(contentsOf: pixels[s ..< s + Int(r.width) * 4])
        }
        return out
    }
}
```

`ImageCache.swift`:
```swift
public struct ImageCache: Sendable {
    private var images: [UInt64: DecodedImage] = [:]
    public init() {}
    public subscript(id: UInt64) -> DecodedImage? { images[id] }
    public mutating func store(_ img: DecodedImage, id: UInt64) { images[id] = img }
    public mutating func remove(_ id: UInt64) { images[id] = nil }
    public mutating func removeAll() { images.removeAll() }
}
```

`ImageDecoder.swift`:
```swift
import Foundation
import Compression
import ImageIO
import CSpiceCodec
import SpiceWire

/// Stateful (owns the GLZ window) — one per display channel, for the life of the session.
public struct ImageDecoder: ~Copyable {
    private let quic = sc_quic_create()!
    private let lz = sc_lz_create()!
    private let glzWindow = sc_glz_window_create()!
    private let glz: OpaquePointer

    public init() { glz = sc_glz_create(glzWindow)! }
    deinit { sc_glz_destroy(glz); sc_glz_window_destroy(glzWindow); sc_lz_destroy(lz); sc_quic_destroy(quic) }

    public mutating func clearGLZWindow() { sc_glz_window_clear(glzWindow) }

    /// `cache` may be nil in unit tests; FROM_CACHE then throws.
    public mutating func decode(_ image: SpiceImage, cache: ImageCache?) throws -> DecodedImage {
        let w = Int(image.descriptor.width), h = Int(image.descriptor.height)
        switch image.payload {
        case .fromCache, .fromCacheLossless:
            guard let c = cache?[image.descriptor.id] else { throw CanvasError.cacheMiss(image.descriptor.id) }
            return c
        case let .bitmap(b): return try Self.decodeBitmap(b)
        case let .quic(data): return try decodeQuic(data, w, h)
        case let .lzRGB(data): return try decodeLZ(data, palette: nil, w, h)
        case let .lzPlt(_, palette, _, data): return try decodeLZ(data, palette: palette, w, h)
        case let .glzRGB(data): return try decodeGLZ(data)
        case let .zlibGlzRGB(data): return try decodeGLZ(try Self.inflate(data))
        case let .jpeg(data): return try Self.decodeJPEG(data, w, h)
        case .jpegAlpha, .lz4: throw CanvasError.unsupported("image type \(image.descriptor.type)")
        case .surface: throw CanvasError.unsupported("surface-as-image is resolved by Canvas")
        }
    }

    private func decodeQuic(_ data: [UInt8], _ w: Int, _ h: Int) throws -> DecodedImage {
        var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID
        guard data.withUnsafeBufferPointer({ sc_quic_begin(quic, $0.baseAddress, data.count, &ow, &oh, &type) }) == 0,
              Int(ow) == w, Int(oh) == h else { throw CanvasError.decode("quic header") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard out.withUnsafeMutableBufferPointer({ sc_quic_decode(quic, $0.baseAddress, Int32(w * 4)) }) == 0 else { throw CanvasError.decode("quic") }
        let alpha = type == SC_IMAGE_RGBA
        if !alpha { for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF } }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: alpha)
    }

    private func decodeLZ(_ data: [UInt8], palette: SpicePalette?, _ w: Int, _ h: Int) throws -> DecodedImage {
        var ow: Int32 = 0, oh: Int32 = 0, type = SC_IMAGE_INVALID, topDown: Int32 = 1
        let entries = palette?.entries ?? []
        let ok = data.withUnsafeBufferPointer { d in entries.withUnsafeBufferPointer { p in
            sc_lz_begin(lz, d.baseAddress, data.count, p.baseAddress, Int32(entries.count), &ow, &oh, &type, &topDown) } }
        guard ok == 0, Int(ow) == w, Int(oh) == h else { throw CanvasError.decode("lz header") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard out.withUnsafeMutableBufferPointer({ sc_lz_decode(lz, $0.baseAddress) }) == 0 else { throw CanvasError.decode("lz") }
        if topDown == 0 { out = Self.flipRows(out, width: w, height: h) }
        let alpha = type == SC_IMAGE_RGBA
        if !alpha { for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF } }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: alpha)
    }

    private func decodeGLZ(_ data: [UInt8]) throws -> DecodedImage {
        var p: UnsafePointer<UInt8>? = nil; var w: Int32 = 0, h: Int32 = 0, s: Int32 = 0
        guard data.withUnsafeBufferPointer({ sc_glz_decode(glz, $0.baseAddress, data.count, &p, &w, &h, &s) }) == 0, let p else { throw CanvasError.decode("glz") }
        var out = [UInt8](repeating: 0, count: Int(w) * Int(h) * 4)
        for y in 0 ..< Int(h) { out.replaceSubrange(y * Int(w) * 4 ..< (y + 1) * Int(w) * 4, with: UnsafeBufferPointer(start: p + y * Int(s), count: Int(w) * 4)) }
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF }
        return DecodedImage(width: Int(w), height: Int(h), pixels: out, hasAlpha: false)
    }

    static func inflate(_ zlib: [UInt8]) throws -> [UInt8] {
        guard zlib.count > 6 else { throw CanvasError.decode("zlib too short") }
        let raw = Array(zlib[2 ..< zlib.count - 4])             // strip 2-byte zlib header and adler32 trailer
        var out = [UInt8](repeating: 0, count: max(raw.count * 8, 1 << 16))
        let n = raw.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
        guard n > 0 else { throw CanvasError.decode("zlib") }
        return Array(out[0 ..< n])
    }

    static func flipRows(_ px: [UInt8], width: Int, height: Int) -> [UInt8] {
        let s = width * 4
        var out = [UInt8](repeating: 0, count: px.count)
        for y in 0 ..< height { out.replaceSubrange(y * s ..< (y + 1) * s, with: px[(height - 1 - y) * s ..< (height - y) * s]) }
        return out
    }

    static func decodeBitmap(_ b: SpiceBitmap) throws -> DecodedImage {
        let w = Int(b.width), h = Int(b.height), stride = Int(b.stride)
        var out = [UInt8](repeating: 0xFF, count: w * h * 4)
        let topDown = b.flags & BitmapFlags.topDown != 0
        let pal = b.palette?.entries ?? []
        func palette(_ i: Int) throws -> UInt32 { guard i < pal.count else { throw CanvasError.decode("palette index") }; return pal[i] }
        for y in 0 ..< h {
            let srcRow = (topDown ? y : h - 1 - y) * stride
            let dstRow = y * w * 4
            switch b.format {
            case .bit32:
                out.replaceSubrange(dstRow ..< dstRow + w * 4, with: b.data[srcRow ..< srcRow + w * 4])
                for x in 0 ..< w { out[dstRow + x * 4 + 3] = 0xFF }
            case .rgba:
                out.replaceSubrange(dstRow ..< dstRow + w * 4, with: b.data[srcRow ..< srcRow + w * 4])
            case .bit24:
                for x in 0 ..< w { for c in 0 ..< 3 { out[dstRow + x * 4 + c] = b.data[srcRow + x * 3 + c] } }
            case .bit16:
                for x in 0 ..< w {
                    let v = UInt16(b.data[srcRow + x * 2]) | UInt16(b.data[srcRow + x * 2 + 1]) << 8   // RGB555
                    out[dstRow + x * 4] = UInt8((v & 0x1F) << 3); out[dstRow + x * 4 + 1] = UInt8(((v >> 5) & 0x1F) << 3); out[dstRow + x * 4 + 2] = UInt8(((v >> 10) & 0x1F) << 3)
                }
            case .bit8, .bit8A:
                for x in 0 ..< w { Self.put(&out, dstRow + x * 4, try palette(Int(b.data[srcRow + x]))) }
            case .bit4LE, .bit4BE:
                for x in 0 ..< w {
                    let byte = b.data[srcRow + x / 2]
                    let idx = (b.format == .bit4BE) == (x % 2 == 0) ? byte >> 4 : byte & 0x0F
                    Self.put(&out, dstRow + x * 4, try palette(Int(idx)))
                }
            case .bit1LE, .bit1BE:
                for x in 0 ..< w {
                    let byte = b.data[srcRow + x / 8]
                    let bit = b.format == .bit1BE ? (byte >> (7 - x % 8)) & 1 : (byte >> (x % 8)) & 1
                    Self.put(&out, dstRow + x * 4, try palette(Int(bit)))
                }
            }
        }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: b.format == .rgba)
    }

    private static func put(_ out: inout [UInt8], _ i: Int, _ argb: UInt32) {
        out[i] = UInt8(argb & 0xFF); out[i + 1] = UInt8((argb >> 8) & 0xFF); out[i + 2] = UInt8((argb >> 16) & 0xFF); out[i + 3] = 0xFF
    }

    static func decodeJPEG(_ data: [UInt8], _ w: Int, _ h: Int) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CanvasError.decode("jpeg") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { throw CanvasError.decode("jpeg context") }
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 0xFF }
        return DecodedImage(width: w, height: h, pixels: out, hasAlpha: false)
    }
}
```

> If `~Copyable` structs cause friction inside the actor, make `ImageDecoder` a `final class` instead — it is only ever owned by one `Canvas`.

`Tier1.swift`:
```swift
import SpiceWire

enum Tier1 {
    /// Copies `src` (tight BGRA) at `srcOrigin` into `dst` over `rect`. Alpha ignored.
    static func copy(into dst: Surface, rect: SpiceRect, src: DecodedImage, srcOrigin: SpicePoint) {
        let rowBytes = Int(rect.width) * 4
        for y in 0 ..< Int(rect.height) {
            let sy = Int(srcOrigin.y) + y
            guard sy >= 0, sy < src.height else { continue }
            let sx = Int(srcOrigin.x)
            let visible = max(0, min(rowBytes / 4, src.width - sx)) * 4
            guard visible > 0, sx >= 0 else { continue }
            let s = (sy * src.width + sx) * 4
            let d = (Int(rect.top) + y) * dst.stride + Int(rect.left) * 4
            dst.pixels.replaceSubrange(d ..< d + visible, with: src.pixels[s ..< s + visible])
        }
    }

    static func fill(_ dst: Surface, rect: SpiceRect, color: UInt32) {
        let b = UInt8(color & 0xFF), g = UInt8((color >> 8) & 0xFF), r = UInt8((color >> 16) & 0xFF)
        for y in Int(rect.top) ..< Int(rect.bottom) {
            var i = y * dst.stride + Int(rect.left) * 4
            for _ in 0 ..< Int(rect.width) { dst.pixels[i] = b; dst.pixels[i + 1] = g; dst.pixels[i + 2] = r; dst.pixels[i + 3] = 0xFF; i += 4 }
        }
    }

    static func invert(_ dst: Surface, rect: SpiceRect) {
        for y in Int(rect.top) ..< Int(rect.bottom) {
            var i = y * dst.stride + Int(rect.left) * 4
            for _ in 0 ..< Int(rect.width) { dst.pixels[i] = ~dst.pixels[i]; dst.pixels[i + 1] = ~dst.pixels[i + 1]; dst.pixels[i + 2] = ~dst.pixels[i + 2]; i += 4 }
        }
    }

    /// Straight-alpha "over" with a constant multiplier (0...255).
    static func alphaBlend(into dst: Surface, rect: SpiceRect, src: DecodedImage, srcOrigin: SpicePoint, alpha: UInt8) {
        for y in 0 ..< Int(rect.height) {
            let sy = Int(srcOrigin.y) + y; guard sy >= 0, sy < src.height else { continue }
            for x in 0 ..< Int(rect.width) {
                let sx = Int(srcOrigin.x) + x; guard sx >= 0, sx < src.width else { continue }
                let s = (sy * src.width + sx) * 4, d = (Int(rect.top) + y) * dst.stride + (Int(rect.left) + x) * 4
                let a = Int(src.hasAlpha ? src.pixels[s + 3] : 255) * Int(alpha) / 255
                for c in 0 ..< 3 { dst.pixels[d + c] = UInt8((Int(src.pixels[s + c]) * a + Int(dst.pixels[d + c]) * (255 - a)) / 255) }
            }
        }
    }

    /// In-surface move; handles overlap by extracting first.
    static func copyBits(_ dst: Surface, rect: SpiceRect, from: SpicePoint) {
        let srcRect = SpiceRect(top: from.y, left: from.x, bottom: from.y + rect.height, right: from.x + rect.width)
        guard let clipped = srcRect.intersection(dst.bounds) else { return }
        let img = DecodedImage(width: Int(clipped.width), height: Int(clipped.height), pixels: dst.extract(clipped), hasAlpha: false)
        let target = SpiceRect(top: rect.top + (clipped.top - srcRect.top), left: rect.left + (clipped.left - srcRect.left),
                               bottom: rect.top + (clipped.bottom - srcRect.top), right: rect.left + (clipped.right - srcRect.left))
        copy(into: dst, rect: target, src: img, srcOrigin: SpicePoint(x: 0, y: 0))
    }
}
```

`Canvas.swift`:
```swift
import os
import SpiceWire

public struct SurfaceUpdate: Sendable {
    public var surfaceID: UInt32, surfaceWidth: Int, surfaceHeight: Int
    public var rect: SpiceRect, pixels: [UInt8], isPrimary: Bool
}
public struct SurfaceDescriptor: Sendable, Equatable { public var surfaceID: UInt32, width: Int, height: Int, isPrimary: Bool }
public enum CanvasEvent: Sendable {
    case surfaceCreated(SurfaceDescriptor), surfaceDestroyed(UInt32), updated(SurfaceUpdate), unsupported(String)
}

public actor Canvas {
    public nonisolated let events: AsyncStream<CanvasEvent>
    private let cont: AsyncStream<CanvasEvent>.Continuation
    private var surfaces: [UInt32: Surface] = [:]
    private var cache = ImageCache()
    private var decoder = ImageDecoder()
    private let log = Logger(subsystem: "com.spicesee", category: "canvas")
    public private(set) var primarySurfaceID: UInt32?

    public init() { (events, cont) = AsyncStream.makeStream(of: CanvasEvent.self, bufferingPolicy: .unbounded) }

    public func snapshot(surfaceID: UInt32) -> DecodedImage? { surfaces[surfaceID]?.snapshot() }

    public func apply(_ m: DisplayMessage) {
        do { try applyThrowing(m) } catch {
            log.error("canvas: \(String(describing: error))")
            cont.yield(.unsupported(String(describing: error)))
        }
    }

    private func applyThrowing(_ m: DisplayMessage) throws {
        switch m {
        case let .surfaceCreate(s):
            let surf = Surface(id: s.surfaceID, width: Int(s.width), height: Int(s.height), isPrimary: s.isPrimary)
            surfaces[s.surfaceID] = surf
            if s.isPrimary { primarySurfaceID = s.surfaceID }
            cont.yield(.surfaceCreated(SurfaceDescriptor(surfaceID: s.surfaceID, width: surf.width, height: surf.height, isPrimary: s.isPrimary)))
            emit(surf, surf.bounds)
        case let .surfaceDestroy(id):
            surfaces[id] = nil
            if primarySurfaceID == id { primarySurfaceID = nil }
            cont.yield(.surfaceDestroyed(id))
        case .mode, .mark, .reset, .monitorsConfig: break
        case .invalAllPixmaps: cache.removeAll()
        case let .invalList(list): list.forEach { cache.remove($0.id) }
        case .invalPalette, .invalAllPalettes: break
        case let .fill(f):
            guard case let .solid(color) = f.brush else { throw CanvasError.unsupported("pattern brush") }
            try forEachClipRect(f.base) { s, r in Tier1.fill(s, rect: r, color: color) }
            if f.rop != ROPD.opPut || f.mask.bitmap != nil { cont.yield(.unsupported("fill rop \(f.rop)/mask → drawn as PUT")) }
        case let .copy(c), let .blend(c):
            let src = try resolve(c.source)
            try forEachClipRect(c.base) { s, r in
                let origin = SpicePoint(x: c.sourceArea.left + (r.left - c.base.box.left), y: c.sourceArea.top + (r.top - c.base.box.top))
                Tier1.copy(into: s, rect: r, src: src, srcOrigin: origin)
            }
            if c.rop != ROPD.opPut || c.mask.bitmap != nil || c.sourceArea.width != c.base.box.width { cont.yield(.unsupported("copy rop/mask/scale → drawn as PUT")) }
        case let .opaque(o):
            let src = try resolve(o.source)
            try forEachClipRect(o.base) { s, r in
                let origin = SpicePoint(x: o.sourceArea.left + (r.left - o.base.box.left), y: o.sourceArea.top + (r.top - o.base.box.top))
                Tier1.copy(into: s, rect: r, src: src, srcOrigin: origin)
            }
        case let .blackness(b): try forEachClipRect(b.base) { s, r in Tier1.fill(s, rect: r, color: 0) }
        case let .whiteness(w): try forEachClipRect(w.base) { s, r in Tier1.fill(s, rect: r, color: 0xFFFFFF) }
        case let .invers(i): try forEachClipRect(i.base) { s, r in Tier1.invert(s, rect: r) }
        case let .copyBits(c):
            try forEachClipRect(c.base) { s, r in
                Tier1.copyBits(s, rect: r, from: SpicePoint(x: c.sourcePos.x + (r.left - c.base.box.left), y: c.sourcePos.y + (r.top - c.base.box.top)))
            }
        case let .alphaBlend(a):
            let src = try resolve(a.source)
            try forEachClipRect(a.base) { s, r in
                let origin = SpicePoint(x: a.sourceArea.left + (r.left - a.base.box.left), y: a.sourceArea.top + (r.top - a.base.box.top))
                Tier1.alphaBlend(into: s, rect: r, src: src, srcOrigin: origin, alpha: a.alpha)
            }
        case let .unsupported(type, _):
            throw CanvasError.unsupported("display message \(type)")
        }
    }

    /// Decodes, honouring cache flags and surface-as-image.
    private func resolve(_ image: SpiceImage?) throws -> DecodedImage {
        guard let image else { throw CanvasError.decode("missing source image") }
        if case let .surface(id) = image.payload {
            guard let s = surfaces[id] else { throw CanvasError.noSurface(id) }
            return s.snapshot()
        }
        let img = try decoder.decode(image, cache: cache)
        if image.descriptor.flags & (ImageFlags.cacheMe | ImageFlags.cacheReplaceMe) != 0 { cache.store(img, id: image.descriptor.id) }
        return img
    }

    /// Runs `body` for each (surface, clipped rect) and emits one update per rect.
    private func forEachClipRect(_ base: DrawBase, _ body: (Surface, SpiceRect) -> Void) throws {
        guard let s = surfaces[base.surfaceID] else { throw CanvasError.noSurface(base.surfaceID) }
        guard let box = base.box.intersection(s.bounds) else { return }
        let rects: [SpiceRect]
        switch base.clip {
        case .none: rects = [box]
        case let .rects(list): rects = list.compactMap { $0.intersection(box) }
        }
        for r in rects { body(s, r); emit(s, r) }
    }

    private func emit(_ s: Surface, _ r: SpiceRect) {
        cont.yield(.updated(SurfaceUpdate(surfaceID: s.id, surfaceWidth: s.width, surfaceHeight: s.height,
                                          rect: r, pixels: s.extract(r), isPrimary: s.isPrimary)))
    }
}
```

`PNG.swift`:
```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNG {
    public static func encode(_ img: DecodedImage) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | (img.hasAlpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData),
              let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                               space: cs, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw CanvasError.decode("png encode") }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw CanvasError.decode("png finalize") }
        return out as Data
    }

    public static func decode(_ data: Data) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CanvasError.decode("png") }
        var out = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return DecodedImage(width: cg.width, height: cg.height, pixels: out, hasAlpha: true)
    }
}
```
> `byteOrder32Little` + `alphaInfo` on an 8-bit context means memory order B,G,R,A — matching our buffers. The PNG round-trip test pins this; if channels come out swapped, the fix is the `bitmapInfo`, not the buffer.

- [ ] **Step 4: Run tests**

Run: `swift test --filter "CanvasTests|ImageDecoderTests"`
Expected: 11 pass.

- [ ] **Step 5: Commit**

```bash
git rm -q Sources/SpiceCanvas/SpiceCanvas.swift
git add -A && git commit -m "feat(canvas): surfaces, image cache, codec routing and tier-1 draws"
```

---

### Task 15: DisplayChannel and replay golden test

**Files:**
- Create: `Sources/SpiceCore/DisplayChannel.swift`
- Test: `Tests/SpiceKitTests/ReplayTests.swift`, fixtures `Tests/SpiceKitTests/Fixtures/alpine-display.s2c.bin` (from Task 12), `alpine-display.golden.png` (generated here)

**Interfaces:**
- Produces:
  ```swift
  public actor DisplayChannel {
      public static func clientCaps() -> CapabilitySet  // sizedStream, monitorsConfig, streamReport, multiCodec, codecMjpeg, codecH264
      public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?) async throws -> DisplayChannel
      public nonisolated let messages: AsyncStream<DisplayMessage>   // parsed; parse failures are logged and skipped
      public func close()
  }
  ```

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import Testing
import SpiceWire
import SpiceCanvas
@testable import SpiceCore

@Test func alpineDisplayReplayMatchesGolden() async throws {
    let url = try #require(Bundle.module.url(forResource: "alpine-display.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let bytes = [UInt8](try Data(contentsOf: url))
    let t = InMemoryTransport(input: bytes)
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    for await m in channel.messages { await canvas.apply(m) }
    let id = try #require(await canvas.primarySurfaceID)
    let frame = try #require(await canvas.snapshot(surfaceID: id))

    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/alpine-display.golden.png")
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        try PNG.encode(frame).write(to: goldenURL)
        Issue.record("golden written to \(goldenURL.path) — review it visually, then re-run")
        return
    }
    let golden = try PNG.decode(try Data(contentsOf: goldenURL))
    #expect(golden.width == frame.width && golden.height == frame.height)
    var mismatches = 0
    for y in 0 ..< frame.height { for x in 0 ..< frame.width where frame.pixel(x: x, y: y) & 0xFFFFFF != golden.pixel(x: x, y: y) & 0xFFFFFF { mismatches += 1 } }
    #expect(mismatches == 0, "\(mismatches) pixels differ")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ReplayTests`
Expected: compile error `DisplayChannel` not found.

- [ ] **Step 3: Implement**

```swift
import os
import SpiceWire

public actor DisplayChannel {
    public nonisolated let messages: AsyncStream<DisplayMessage>
    private let reader: ChannelReader
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func clientCaps() -> CapabilitySet {
        CapabilitySet(bits: [DisplayCap.sizedStream, DisplayCap.monitorsConfig, DisplayCap.streamReport,
                             DisplayCap.multiCodec, DisplayCap.codecMjpeg, DisplayCap.codecH264])
    }

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?) async throws -> DisplayChannel {
        let desc = ChannelDescriptor(type: .display, id: id)
        let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                   channelCaps: clientCaps(), password: password)
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
        let loop = Task { await reader.run() }
        try await reader.send(type: DisplayClientMsg.init.rawValue,
                              payload: ClientMessage.displayInit(cacheSize: 40 << 20, glzWindowSize: 16 << 20))
        return DisplayChannel(reader: reader, loop: loop, descriptor: desc)
    }

    private init(reader: ChannelReader, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: DisplayMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "display")
        pump = Task {
            for await raw in reader.messages {
                do { cont.yield(try DisplayMessage(type: raw.type, payload: raw.payload)) }
                catch { log.error("display/\(descriptor.id): drop type \(raw.type): \(String(describing: error))") }
            }
            cont.finish()
        }
    }

    public func close() { pump.cancel(); loop.cancel() }
}
```

> In replay, the recording's link reply was produced for the *reference client's* link mess; our handshake only reads the reply, so caps mismatch is harmless except MINI_HEADER: `LinkResult.miniHeader` is derived from the server's caps, and the server sent mini headers only if the reference client also advertised it. If the fixture's `c2s.bin` shows the reference client lacked MINI_HEADER, add `static func open(..., forceFullHeader: Bool = false)` and pass `true` from the test.

- [ ] **Step 4: Run, review the golden, run again**

Run: `swift test --filter ReplayTests` — first run writes `alpine-display.golden.png`. Open it (`open Tests/SpiceKitTests/Fixtures/alpine-display.golden.png`): it must show the Alpine boot/login text legibly. If it is black, garbled, or partially drawn, that is a real bug in Task 13/14 — fix there, delete the golden, re-run. Only commit a golden you have looked at.
Run again: `swift test --filter ReplayTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): display channel; replay golden test from Alpine recording"
```

---

### Task 16: SpiceKit facade and `spicesee-cli dump`

**Files:**
- Create: `Sources/SpiceKit/SpiceSession.swift`; modify `Sources/spicesee-cli/main.swift`
- Test: `Tests/SpiceKitTests/SpiceSessionTests.swift`
- Delete: `Sources/SpiceKit/SpiceKit.swift`

**Interfaces:**
- Consumes: `MainChannel.open`, `DisplayChannel.open`, `Canvas`, `NWTransport.connect`.
- Produces:
  ```swift
  public struct ConnectionConfig: Sendable { public var host: String; public var port: UInt16; public var password: String?; public init(host:port:password:) }
  public enum SessionEvent: Sendable { case connected(SessionInfo), canvas(CanvasEvent), channelFailed(ChannelDescriptor, SpiceError), disconnected(SpiceError?) }
  public actor SpiceSession {
      /// Injectable transport factory so tests replay recordings; production uses NWTransport.
      public typealias TransportFactory = @Sendable (ChannelDescriptor) async throws -> any Transport
      public static func connect(_ config: ConnectionConfig) async throws -> SpiceSession
      public static func connect(password: String?, transports: @escaping TransportFactory) async throws -> SpiceSession
      public nonisolated let events: AsyncStream<SessionEvent>
      public let info: SessionInfo
      public func snapshotPrimary() async -> DecodedImage?
      public func disconnect()
  }
  ```

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

@Test func sessionBringsUpMainAndDisplayFromRecordings() async throws {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))))
    }
    let main = try fixture("alpine-main.s2c"), display = try fixture("alpine-display.s2c")
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return InMemoryTransport(input: main)
        case .display: return InMemoryTransport(input: display)
        default: throw SpiceError(.unsupported("not in M1"), channel: desc)
        }
    }
    #expect(session.info.channels.contains(ChannelDescriptor(type: .display, id: 0)))
    var sawSurface = false
    for await e in session.events {
        if case .canvas(.surfaceCreated(let d)) = e, d.isPrimary { sawSurface = true }
        if case .disconnected = e { break }
    }
    #expect(sawSurface)
    let frame = try #require(await session.snapshotPrimary())
    #expect(frame.width > 0)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SpiceSessionTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

```swift
import os
import SpiceCanvas
import SpiceCore
import SpiceWire

public struct ConnectionConfig: Sendable {
    public var host: String, port: UInt16, password: String?
    public init(host: String, port: UInt16, password: String?) { self.host = host; self.port = port; self.password = password }
}

public enum SessionEvent: Sendable {
    case connected(SessionInfo)
    case canvas(CanvasEvent)
    case channelFailed(ChannelDescriptor, SpiceError)
    case disconnected(SpiceError?)
}

public actor SpiceSession {
    public typealias TransportFactory = @Sendable (ChannelDescriptor) async throws -> any Transport

    public let info: SessionInfo
    public nonisolated let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    private let main: MainChannel
    private let canvas = Canvas()
    private var displays: [DisplayChannel] = []
    private var tasks: [Task<Void, Never>] = []
    private let log = Logger(subsystem: "com.spicesee", category: "session")

    public static func connect(_ config: ConnectionConfig) async throws -> SpiceSession {
        try await connect(password: config.password) { _ in try await NWTransport.connect(host: config.host, port: config.port) }
    }

    public static func connect(password: String?, transports: @escaping TransportFactory) async throws -> SpiceSession {
        let mainTransport = try await transports(MainChannel.descriptor)
        let main = try await MainChannel.open(transport: mainTransport, password: password)
        let session = SpiceSession(main: main)
        await session.start(password: password, transports: transports)
        return session
    }

    private init(main: MainChannel) {
        self.main = main
        info = main.info
        (events, cont) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
    }

    private func start(password: String?, transports: @escaping TransportFactory) async {
        cont.yield(.connected(info))
        tasks.append(Task { [canvas, cont] in
            for await e in canvas.events { cont.yield(.canvas(e)) }
        })
        for desc in info.channels where desc.type == .display {
            do {
                let t = try await transports(desc)
                let d = try await DisplayChannel.open(transport: t, connectionID: info.connectionID, id: desc.id, password: password)
                displays.append(d)
                tasks.append(Task { [canvas] in for await m in d.messages { await canvas.apply(m) } })
            } catch let e as SpiceError {
                cont.yield(.channelFailed(desc, e))
            } catch {
                cont.yield(.channelFailed(desc, SpiceError(.connect, channel: desc, underlying: String(describing: error))))
            }
        }
        tasks.append(Task { [main, cont] in
            for await _ in main.events {}          // main events are consumed in M2+ (mouse mode, agent)
            cont.yield(.disconnected(nil))
        })
    }

    public func snapshotPrimary() async -> DecodedImage? {
        guard let id = await canvas.primarySurfaceID else { return nil }
        return await canvas.snapshot(surfaceID: id)
    }

    public func disconnect() {
        tasks.forEach { $0.cancel() }
        displays.forEach { Task { await $0.close() } }
        Task { await main.close() }
        cont.yield(.disconnected(nil)); cont.finish()
    }
}
```

Add to `spicesee-cli/main.swift` a `dump` subcommand — replace the argument guard with:
```swift
// usage: spicesee-cli connect <host> <port> [password]
//        spicesee-cli dump <host> <port> <seconds> <out.png> [password]
```
and for `dump`: `SpiceSession.connect(ConnectionConfig(...))`, `try await Task.sleep(for: .seconds(n))`, `PNG.encode(await session.snapshotPrimary()!)` written to the path, then `disconnect()`. (Import `SpiceKit` and `SpiceCanvas`.)

- [ ] **Step 4: Run tests and the live dump**

Run: `swift test --filter SpiceSessionTests` → PASS.
Run (dev server up): `swift run spicesee-cli dump 127.0.0.1 5900 5 /tmp/frame.png && open /tmp/frame.png` → the Alpine console renders.

- [ ] **Step 5: Commit**

```bash
git rm -q Sources/SpiceKit/SpiceKit.swift
git add -A && git commit -m "feat(kit): SpiceSession facade; spicesee-cli dump"
```

---

### Task 17: App bundle via xcodegen

**Files:**
- Create: `project.yml`, `Sources/SpiceSee/SpiceSeeApp.swift`, `Sources/SpiceSee/Info.plist`, `Sources/SpiceSee/SpiceSee.entitlements`, `Sources/SpiceSee/Assets.xcassets/` (empty catalog with `Contents.json`)
- Modify: `Package.swift` (exclude `Sources/SpiceSee` from SPM: add `exclude` is not needed because no target references it — but add it to `.gitignore`? No: the app sources are committed; only `*.xcodeproj` is ignored.)

**Interfaces:**
- Produces: `SpiceSee.xcodeproj` (generated, git-ignored) with a macOS app target linking the local SPM package's `SpiceKit` product and embedding `CSpiceCodec.framework`.

- [ ] **Step 1: Write project.yml**

```yaml
name: SpiceSee
options:
  bundleIdPrefix: com.spicesee
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "26.0"
packages:
  SpiceSee:
    path: .
targets:
  SpiceSee:
    type: application
    platform: macOS
    sources: [Sources/SpiceSee]
    dependencies:
      - package: SpiceSee
        product: SpiceKit
      - package: SpiceSee
        product: CSpiceCodec
        embed: true
    info:
      path: Sources/SpiceSee/Info.plist
      properties:
        CFBundleName: SpiceSee
        CFBundleDisplayName: SpiceSee
        LSMinimumSystemVersion: "14.0"
        NSPrincipalClass: NSApplication
    entitlements:
      path: Sources/SpiceSee/SpiceSee.entitlements
      properties:
        com.apple.security.cs.disable-library-validation: true
        com.apple.security.network.client: true
    settings:
      base:
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        ARCHS: arm64 x86_64
        ONLY_ACTIVE_ARCH: NO
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic
        PRODUCT_BUNDLE_IDENTIFIER: com.spicesee.app
```

- [ ] **Step 2: Minimal app**

`Sources/SpiceSee/SpiceSeeApp.swift`:
```swift
import SwiftUI

@main
struct SpiceSeeApp: App {
    var body: some Scene {
        WindowGroup("SpiceSee") { ConnectView() }
    }
}
```
`Sources/SpiceSee/ConnectView.swift` (placeholder for this task; Task 18 fills it):
```swift
import SwiftUI
struct ConnectView: View { var body: some View { Text("SpiceSee").padding(40) } }
```
`Assets.xcassets/Contents.json`: `{ "info": { "author": "xcode", "version": 1 } }`.

- [ ] **Step 3: Generate and build**

```bash
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Verify embedding: `ls "$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/SpiceSee.app/Contents/Frameworks"` lists `CSpiceCodec.framework`. If xcodegen's `embed: true` on a package product does not produce an embed phase, add a `Copy Files` build phase (destination Frameworks) manually in `project.yml` under `buildPhases` — or drop the dynamic product and revisit in M7; note whichever in `docs/dev-server.md`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "build: xcodegen app project with hardened runtime and codec framework embedding"
```

---

### Task 18: Connect view, session window, Metal surface view (M1 exit)

**Files:**
- Create: `Sources/SpiceSee/MetalSurfaceView.swift`, `Sources/SpiceSee/SessionWindow.swift`, `Sources/SpiceSee/SessionModel.swift`; replace `Sources/SpiceSee/ConnectView.swift`

**Interfaces:**
- Consumes: `SpiceSession`, `SessionEvent`, `SurfaceUpdate`, `SurfaceDescriptor`.
- Produces (app-internal):
  ```swift
  @MainActor @Observable final class SessionModel { var state: State; func connect(host:port:password:) ; func disconnect(); let updates: AsyncStream<SurfaceUpdate>; var primary: SurfaceDescriptor? }
  final class MetalSurfaceView: NSView   // owns CAMetalLayer + MTLTexture; apply(_ update: SurfaceUpdate) on main
  struct SurfaceViewRepresentable: NSViewRepresentable
  ```

- [ ] **Step 1: SessionModel**

```swift
import Observation
import SpiceKit
import SpiceCanvas
import SpiceCore
import SpiceWire

@MainActor @Observable
final class SessionModel {
    enum State: Equatable { case idle, connecting, connected, failed(String) }
    var state: State = .idle
    var primary: SurfaceDescriptor?
    let updates: AsyncStream<SurfaceUpdate>
    private let updateCont: AsyncStream<SurfaceUpdate>.Continuation
    private var session: SpiceSession?
    private var pump: Task<Void, Never>?

    init() { (updates, updateCont) = AsyncStream.makeStream(of: SurfaceUpdate.self, bufferingPolicy: .unbounded) }

    func connect(host: String, port: UInt16, password: String) {
        state = .connecting
        pump = Task {
            do {
                let s = try await SpiceSession.connect(ConnectionConfig(host: host, port: port, password: password.isEmpty ? nil : password))
                session = s
                state = .connected
                for await e in s.events {
                    switch e {
                    case .canvas(.surfaceCreated(let d)) where d.isPrimary: primary = d
                    case .canvas(.updated(let u)) where u.isPrimary: updateCont.yield(u)
                    case .channelFailed(let c, let err): state = .failed("\(c.type) channel: \(err.underlying ?? "\(err.kind)")")
                    case .disconnected: state = .idle; primary = nil
                    default: break
                    }
                }
            } catch let e as SpiceError {
                state = .failed(e.underlying ?? "\(e.kind)")
            } catch { state = .failed(String(describing: error)) }
        }
    }

    func disconnect() { pump?.cancel(); Task { await session?.disconnect() }; state = .idle }
}
```

- [ ] **Step 2: MetalSurfaceView**

```swift
import AppKit
import Metal
import QuartzCore
import SpiceCanvas
import SpiceWire

@MainActor
final class MetalSurfaceView: NSView {
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var texture: MTLTexture?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let l = CAMetalLayer()
        l.device = device; l.pixelFormat = .bgra8Unorm; l.framebufferOnly = false; l.isOpaque = true
        layer = l
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: d)
        metalLayer.drawableSize = CGSize(width: width, height: height)
    }

    func apply(_ u: SurfaceUpdate) {
        if texture == nil || texture!.width != u.surfaceWidth || texture!.height != u.surfaceHeight { configure(width: u.surfaceWidth, height: u.surfaceHeight) }
        guard let texture else { return }
        let region = MTLRegionMake2D(Int(u.rect.left), Int(u.rect.top), Int(u.rect.width), Int(u.rect.height))
        u.pixels.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: Int(u.rect.width) * 4) }
        present()
    }

    private func present() {
        guard let texture, let drawable = metalLayer.nextDrawable(), let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        let w = min(texture.width, drawable.texture.width), h = min(texture.height, drawable.texture.height)
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.present(drawable); cmd.commit()
    }

    override func layout() { super.layout(); if let texture { metalLayer.drawableSize = CGSize(width: texture.width, height: texture.height) } ; present() }
}

struct SurfaceViewRepresentable: NSViewRepresentable {
    let model: SessionModel
    func makeNSView(context: Context) -> MetalSurfaceView {
        let v = MetalSurfaceView(frame: .zero)
        context.coordinator.task = Task { @MainActor in for await u in model.updates { v.apply(u) } }
        return v
    }
    func updateNSView(_ v: MetalSurfaceView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var task: Task<Void, Never>?; deinit { task?.cancel() } }
}
```
> 1:1 presentation only — the drawable is the surface size and the window sizes itself to it. Fit-to-window scaling is M7 (it needs a render pass with a sampler instead of a blit).

- [ ] **Step 3: ConnectView and SessionWindow**

`ConnectView.swift`:
```swift
import SwiftUI

struct ConnectView: View {
    @State private var model = SessionModel()
    @State private var host = "127.0.0.1"
    @State private var port = "5900"
    @State private var password = ""

    var body: some View {
        Group {
            if model.state == .connected, let p = model.primary {
                SessionWindow(model: model, surface: p)
            } else {
                Form {
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    SecureField("Password", text: $password)
                    if case .failed(let msg) = model.state { Text(msg).foregroundStyle(.red) }
                    Button(model.state == .connecting ? "Connecting…" : "Connect") {
                        guard let p = UInt16(port) else { return }
                        model.connect(host: host, port: p, password: password)
                    }.disabled(model.state == .connecting)
                }
                .padding(24).frame(width: 360)
            }
        }
    }
}
```
`SessionWindow.swift`:
```swift
import SwiftUI
import SpiceCanvas

struct SessionWindow: View {
    let model: SessionModel
    let surface: SurfaceDescriptor
    var body: some View {
        SurfaceViewRepresentable(model: model)
            .frame(width: CGFloat(surface.width), height: CGFloat(surface.height))
            .toolbar { Button("Disconnect") { model.disconnect() } }
    }
}
```

- [ ] **Step 4: Verify M1 exit criterion**

```bash
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
open "$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/SpiceSee.app"
```
With `scripts/dev-server.sh` running: Connect to 127.0.0.1:5900 → the Alpine console appears and updates live as the VM boots (cursor blink, text scroll). Take a screenshot to `docs/m1-alpine.png`.

Also run the full suite: `swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(app): connect view and Metal-presented session window — M1 Pixels"
```

---

## Self-review notes

- **Spec coverage (M0–M1):** §2 layout (T1), security-boundary reader (T2), link/ticket/caps (T3, T7, T9), MAIN_INIT/CHANNELS_LIST/PING (T4, T10, T11), TLS/`.vv`/migration → M3 plan, §4 tier 1 + cache + GLZ window + codec routing (T13, T14), Metal present on dirty rects (T18), §7 replay + per-op goldens + spicerec (T12, T14, T15), libFuzzer → add to M4 plan once `SpiceWire` is complete, §8 bundle/entitlement/embedding (T17), signing/notarization → M7.
- **Known deviations:** surfaces are copied per dirty rect into `[UInt8]` for the Metal upload instead of shared zero-copy (spec §4) — keeps the no-`@unchecked Sendable` rule; revisit with a custom serial executor + `IOSurface` in M4 if profiling demands. Non-PUT ROPs / masks / scaled copies draw as PUT with an `.unsupported` event in M1; M4 replaces them with tier 2/3.
- **Type consistency check:** `ChannelDescriptor(type:id:)`, `Transport` = `ByteSource & ByteSink`, `ClientMessage.frame(type:payload:mini:serial:)`, `DisplayMessage(type:payload:)`, `Canvas.apply(_:)` / `snapshot(surfaceID:)` / `primarySurfaceID`, `SurfaceUpdate.isPrimary`, `SessionInfo.connectionID` are used with the same spelling in every task.

---

## Amendment — 2026-08-22: UI built ahead of the engine

The finalized Claude Design project (`docs/design/SpiceSee UI.dc.html`, text extract at
`docs/design/design-text.txt`) arrived before execution started, so the app layer was built first,
from the design, rather than from Tasks 17–18's placeholders.

**Tasks 17 and 18 above are superseded.** What shipped instead:

- `project.yml` / xcodegen app target — as Task 17 specified, plus the `.vv` document type and UTI
  (`org.spice-space.vv`), the `ChiliRed` accent colorset, and `Sources/SpiceSee/Licenses` as bundled
  resources. `CSpiceCodec.framework` embedding is NOT yet wired — it lands with Task 13, which is
  when the framework first exists.
- The full UI from the design: connection manager, inline connect progress, the three failure sheets,
  migration sheet, session window with the responsive toolbar and captured-pointer HUD, preferences,
  acknowledgements, and the app/document icons.

**The one architectural deviation.** Task 18 had `SessionModel` talk to `SpiceKit.SpiceSession`
directly. `SpiceKit` does not exist until Task 16, so the UI is written against a seam:

```swift
protocol SessionBackend: Sendable {
    func connect(host: String, port: UInt16, tlsPort: UInt16?, password: String?) -> AsyncStream<BackendEvent>
    func disconnect() async
    func sendCtrlAltDel() async
}
```

`MockSessionBackend` implements it today (`--mock`, `--scenario <name>`), which is what makes every
screen reviewable before a single byte of SPICE has been parsed. This is one protocol and one mock,
not a speculative abstraction layer: without it the UI could not be run or verified at all.

**Therefore add, after Task 16:**

### Task 16b: SpiceKitBackend — replace the mock

**Files:**
- Create: `Sources/SpiceSee/SpiceKitBackend.swift`
- Modify: `Sources/SpiceSee/SpiceSeeApp.swift` (select the real backend unless `--mock`)
- Test: `Tests/SpiceKitTests/SpiceKitBackendTests.swift`

**Interfaces:**
- Consumes: `SpiceSession.connect(_:)`, `SessionEvent`, `SurfaceUpdate`, `SurfaceDescriptor`, `SpiceError`.
- Produces: `struct SpiceKitBackend: SessionBackend`.

The mapping is mechanical, and each line is pinned by an existing UI state:

| `SessionEvent` | `BackendEvent` |
|---|---|
| `.connected(SessionInfo)` | `.connected(viewports:)` — one `ViewportInfo` per display channel in `info.channels` |
| `.canvas(.surfaceCreated(d))` where `d.isPrimary` | update that viewport's `width`/`height` |
| `.canvas(.updated(u))` | `.frame(FrameUpdate(...))` — `u.rect` → `x/y/width/height`, `u.pixels` verbatim (both are tightly packed BGRA) |
| `.channelFailed(desc, err)` | `.failed(...)` for the main channel; a failed *secondary* channel degrades the session and must NOT produce `.failed` (spec §3) |
| `.disconnected` | `.disconnected` |

`SpiceError` → `ConnectFailure` mapping, since the design's failure copy is keyed to these:
`.link(.permissionDenied)` and `.auth` → `.passwordRejected`; `.connect` → `.refused(endpoint:)`;
`.tls` → `.hostSubjectMismatch(expected:presented:host:)` (M3, when the verify block can report both
subjects); everything else → `.other(title:message:)`. The raw `SpiceError` goes to `os.Logger`, never
into the sheet text — the design is explicit that the SPICE error code never reaches the user.

No view changes when this lands. If a view needs editing to accommodate the real backend, the seam is
wrong — fix the adapter, not the view.
