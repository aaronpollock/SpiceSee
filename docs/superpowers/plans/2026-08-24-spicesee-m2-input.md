# SpiceSee M2 (Input) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The session window drives the guest — keyboard (positional kVK → XT scancodes, modifier mapping, lock-key sync, Ctrl-Alt-Del), mouse in both modes (absolute `MOUSE_POSITION` in client mode; captured, relative `MOUSE_MOTION` in server mode with a release chord), and the guest's own cursor shape (native `NSCursor` in client mode, composited in Metal in server mode).

**Architecture:** Two new channel actors in `SpiceCore` (`InputsChannel`, `CursorChannel`) over the existing `ChannelReader`; wire types in `SpiceWire`; cursor-shape decoding and cache in `SpiceCanvas`; the kVK table, wheel accumulator, viewport transform and an *ordered, non-blocking* `SpiceSession.send(_:)` in `SpiceKit`. The app gains one `SessionBackend` method (`sendInput`), two `BackendEvent` cases (`pointerMode`, `cursor`), and one AppKit input view. Everything below the app is tested headless; the two encodings a self-consistent test cannot catch (scancode packing, mouse messages) are pinned against a recording of `remote-viewer`.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, AppKit event handling (`NSEvent`, `NSTrackingArea`, `NSCursor`, `CGAssociateMouseAndMouseCursorPosition`), Metal alpha-blended overlay quad, `spicerec` + `xdotool` for fixtures.

**Spec:** `docs/superpowers/specs/2026-08-22-spicesee-design.md` — this plan implements §6 (keyboard, mouse, cursor), the mouse-mode paragraph of §5, and milestone M2. Previous plan: `2026-08-22-spicesee-m0-m1-pixels.md` (all tasks shipped; read its Global Constraints and the Task 16b amendment — the `SessionBackend` seam rules still apply).

## Global Constraints

- Swift 6 language mode, strict concurrency. No locks, no `@unchecked Sendable`. (Input ordering is solved with `AsyncStream` continuations, never with a lock.)
- `platforms: [.macOS(.v14)]`. Universal binary — no arch-specific code.
- `SpiceWire` is the security boundary: every reader accessor throws; a malformed message must never trap. No `!` unwraps, no unchecked subscripts on wire data. Cursor bitmaps are wire data: **check `data.count` before every read.**
- Dependency rule strictly downward: `SpiceWire` ← `SpiceCore` ← `SpiceKit`; `SpiceCanvas` imports nothing from `SpiceCore`. Nothing below `Sources/SpiceSee` imports AppKit, SwiftUI or Carbon — the kVK table is written with numeric key codes.
- `SessionBackend` is the seam: views never see SPICE types. `MockSessionBackend` must keep driving every `--mock --scenario` state, including the new pointer-mode behaviour. If a *view* needs editing to accommodate the engine, fix the adapter (new input UI is new functionality, not accommodation).
- Spec §6, verbatim: "Static table: macOS `kVK_*` (physical, layout-independent) -> XT set-1 scancodes with `0xE0` extended prefix (~110 entries). Modifiers via `flagsChanged`. On window-resign-key, release every held key. Lock keys synced both ways with `INPUTS_KEY_MODIFIERS`. Default positional mapping Cmd->Super, Option->Alt, swappable in preferences. OS-reserved combos stay with macOS in v1."
- Spec §6, verbatim: "Wheel = button 4/5 press/release pairs; trackpad deltas accumulate and emit one click per N units. Server mode hides the cursor, pins it with `CGAssociateMouseAndMouseCursorPosition(false)`, releases on a configurable chord (default Ctrl+Option)."
- Spec §5, verbatim: "Request client mode (absolute `MOUSE_POSITION`) when the agent is up; server mode (relative `MOUSE_MOTION`, pointer captured) for agent-less states." Implemented as: request client mode whenever the server reports it *supported* (that is exactly when spice-server has an agent or a tablet).
- UI: `Theme.swift` owns dimensions; chili red is accent only; no custom toolbar backgrounds. The captured-pointer HUD and release cue already exist and must become honest, not redrawn.
- Tests use Swift Testing. Fixtures in `Tests/SpiceKitTests/Fixtures/`. Commit after every task with conventional-commit prefixes. Library code logs via `os.Logger(subsystem: "com.spicesee", category:)`.
- Verification habit (memory `spicesee-verification-habits`): an encoder tested only against our own decoder proves nothing. Task 3 records the reference client and every wire encoder is compared to those bytes.

## Protocol reference (spice-protocol `spice.proto`, `enums.h`)

Everything below is what the tasks encode; keep it here so no task has to guess.

```
Inputs channel (type 3)             Cursor channel (type 4)
server → client                     server → client
  INIT            = 101  u16 modifiers          INIT      = 101  Point16 pos; u16 trail_len; u16 trail_freq; u8 visible; Cursor
  KEY_MODIFIERS   = 102  u16 modifiers          RESET     = 102
  MOUSE_MOTION_ACK= 111  (empty)                SET       = 103  Point16 pos; u8 visible; Cursor
client → server                                 MOVE      = 104  Point16 pos
  KEY_DOWN        = 101  u32 code               HIDE      = 105
  KEY_UP          = 102  u32 code               TRAIL     = 106  u16 length; u16 frequency
  KEY_MODIFIERS   = 103  u16 modifiers          INVAL_ONE = 107  u64 id
  MOUSE_MOTION    = 111  i32 dx; i32 dy; u16 buttons_state     INVAL_ALL = 108
  MOUSE_POSITION  = 112  u32 x; u32 y; u16 buttons_state; u8 display_id
  MOUSE_PRESS     = 113  u8 button; u16 buttons_state
  MOUSE_RELEASE   = 114  u8 button; u16 buttons_state

Cursor = u16 flags; [CursorHeader header; u8 data[] to end of message]   — header+data only when !(flags & NONE)
CursorHeader = u64 unique; u8 type; u16 width; u16 height; u16 hot_spot_x; u16 hot_spot_y
cursor flags: NONE = 1, CACHE_ME = 2, FROM_CACHE = 4        cursor types: ALPHA 0, MONO 1, COLOR4 2, COLOR8 3, COLOR16 4, COLOR24 5, COLOR32 6
Point16 = i16 x; i16 y

modifiers bits: SCROLL_LOCK = 1, NUM_LOCK = 2, CAPS_LOCK = 4
mouse buttons: LEFT 1, MIDDLE 2, RIGHT 3, UP 4, DOWN 5     buttons_state masks: LEFT 1, MIDDLE 2, RIGHT 4
mouse modes (MAIN_INIT.supported/current, MAIN_MOUSE_MODE, MOUSE_MODE_REQUEST): SERVER = 1, CLIENT = 2
inputs client cap: KEY_SCANCODE = bit 0 (advertise it, as spice-gtk does)
server sends MOUSE_MOTION_ACK after every 4 motion/position messages; spice-gtk holds at 8 in flight.
```

**KEY_DOWN/KEY_UP `code`**: spice-server's `kbd_push_scan` loop reads the u32 as up to four scancode bytes, low byte first, stopping at a zero byte. So plain `0x1E` (A) down = `0x0000001E`, up = `0x0000009E`; extended `E0 53` (Delete) down = `0x000053E0`, up = `0x0000D3E0`. Pause (`E1 1D 45`) has no Mac key and is not mapped.

## File Structure

```
Sources/
  SpiceWire/
    InputsMessages.swift     InputsServerMsg/ClientMsg ids, InputsCap, SpiceMouseMode, MouseButton, LockKeys,
                             XTScancode, InputsMessage (server→client), ClientMessage.keyDown/…/mouseRelease
    CursorMessages.swift     CursorServerMsg ids, CursorFlags, CursorType, SpicePoint16, CursorHeader, SpiceCursor, CursorMessage
  SpiceCore/
    MotionThrottle.swift     pure in-flight/coalescing state for motion + position (tested without a transport)
    InputsChannel.swift      actor: link, key/mouse senders, held-key set, buttons_state, ack handling, guest lock keys
    CursorChannel.swift      actor: link, CursorMessage stream (mirrors DisplayChannel)
  SpiceCanvas/
    CursorShape.swift        CursorShape (BGRA straight alpha) + CursorDecoder (ALPHA/MONO/COLOR16/24/32)
    CursorTracker.swift      CursorCache + CursorTracker: CursorMessage → [CursorChange]
  SpiceKit/
    KeyMap.swift             kVK → XTScancode table, ModifierTarget, named scancodes (ctrl/alt/delete…)
    WheelAccumulator.swift   trackpad delta → wheel clicks
    ViewportTransform.swift  guest↔view geometry for fit / 1:1 (shared by Metal present, mouse mapping, cursor overlay)
    SpiceSession.swift       + inputs/cursor channels, GuestInput, send(_:), PointerMode, mouse-mode negotiation
  SpiceSee/
    SessionBackend.swift     + sendInput, InputEvent, KeyboardMapping, PointerButton, PointerMode, CursorImage, CursorChange, ViewportEvent
    SpiceKitBackend.swift    + input relay, kVK translation, event mapping, real Ctrl-Alt-Del
    MockSessionBackend.swift + pointerMode per scenario, a mock cursor shape
    SessionModel.swift       + pointerMode, keyboardMapping, sendLockKeys, sendInput, honest pointerCaptured, viewportEvents(for:)
    MetalSurfaceView.swift   uses ViewportTransform; cursor overlay; hosts GuestInputView
    GuestInputView.swift     NSView: keyboard, mouse (both modes), capture/release, NSCursor
    SpiceSeeApp.swift        sendLockKeys plumbing
Tests/
  SpiceWireTests/InputsMessageTests.swift  CursorMessageTests.swift
  SpiceCoreTests/MotionThrottleTests.swift InputsChannelTests.swift CursorChannelTests.swift  (+ TestSupport.fakeLink)
  SpiceCanvasTests/CursorDecoderTests.swift CursorTrackerTests.swift
  SpiceKitTests/KeyMapTests.swift WheelAccumulatorTests.swift ViewportTransformTests.swift SessionInputTests.swift
                ReferenceClientTests.swift (Task 3) + Fixtures/win-inputs.{s2c,c2s}.bin, win-cursor.s2c.bin
```

---

### Task 1: Inputs wire types and client encoders

**Files:**
- Create: `Sources/SpiceWire/InputsMessages.swift`
- Test: `Tests/SpiceWireTests/InputsMessageTests.swift`

**Interfaces:**
- Consumes: `SpiceReader`, `SpiceWriter`, `WireError`, `ClientMessage` (`Sources/SpiceWire/ClientMessages.swift`).
- Produces: `InputsServerMsg`, `InputsClientMsg`, `InputsCap.keyScancode`, `SpiceMouseMode.server/.client: UInt32`, `MouseButton` (`.left .middle .right .up .down`, `.mask`), `LockKeys` (OptionSet: `.scrollLock .numLock .capsLock`), `XTScancode(code:extended:)` + `wireCode(pressed:)`, `InputsMessage` (`.init(LockKeys)`, `.keyModifiers(LockKeys)`, `.mouseMotionAck`, `.other(type:)`), and `ClientMessage.keyDown(_:) / keyUp(_:) / keyModifiers(_:) / mouseMotion(dx:dy:buttons:) / mousePosition(x:y:buttons:displayID:) / mousePress(_:buttons:) / mouseRelease(_:buttons:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SpiceWireTests/InputsMessageTests.swift
import Testing
@testable import SpiceWire

@Test func scancodePackingMatchesKbdPushScan() {
    // spice-server reads `code` low byte first and stops at a zero byte.
    #expect(XTScancode(0x1E).wireCode(pressed: true) == 0x1E)
    #expect(XTScancode(0x1E).wireCode(pressed: false) == 0x9E)
    #expect(XTScancode(0x53, extended: true).wireCode(pressed: true) == 0x53E0)
    #expect(XTScancode(0x53, extended: true).wireCode(pressed: false) == 0xD3E0)
    // The break bit is ours to set; a caller passing it is not trusted.
    #expect(XTScancode(0x9E).wireCode(pressed: true) == 0x1E)
}

@Test func clientEncodersAreLittleEndianAndPacked() {
    #expect(ClientMessage.keyDown(XTScancode(0x1D, extended: true)) == [0xE0, 0x1D, 0, 0])
    #expect(ClientMessage.keyUp(XTScancode(0x1D, extended: true)) == [0xE0, 0x9D, 0, 0])
    #expect(ClientMessage.keyModifiers([.capsLock, .numLock]) == [6, 0])
    #expect(ClientMessage.mouseMotion(dx: -1, dy: 2, buttons: [.left]) == [0xFF, 0xFF, 0xFF, 0xFF, 2, 0, 0, 0, 1, 0])
    #expect(ClientMessage.mousePosition(x: 640, y: 3, buttons: [], displayID: 1) == [0x80, 2, 0, 0, 3, 0, 0, 0, 0, 0, 1])
    #expect(ClientMessage.mousePress(.right, buttons: [.right]) == [3, 4, 0])
    #expect(ClientMessage.mouseRelease(.up, buttons: []) == [4, 0, 0])
}

@Test func buttonMasks() {
    #expect(MouseButton.left.mask == 1 && MouseButton.middle.mask == 2 && MouseButton.right.mask == 4)
    #expect(MouseButton.up.mask == 0 && MouseButton.down.mask == 0)   // wheel buttons never enter buttons_state
    var state = MouseButtonState()
    state.insert(.left); state.insert(.right); state.remove(.left)
    #expect(state.rawValue == 4)
}

@Test func serverMessagesParse() throws {
    #expect(try InputsMessage(type: 101, payload: [5, 0]) == .`init`([.scrollLock, .capsLock]))
    #expect(try InputsMessage(type: 102, payload: [2, 0]) == .keyModifiers([.numLock]))
    #expect(try InputsMessage(type: 111, payload: []) == .mouseMotionAck)
    #expect(try InputsMessage(type: 150, payload: [1, 2]) == .other(type: 150))
    #expect(throws: WireError.self) { try InputsMessage(type: 101, payload: [5]) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InputsMessageTests`
Expected: compile error — `XTScancode`, `InputsMessage`, `MouseButtonState` do not exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SpiceWire/InputsMessages.swift
public enum InputsServerMsg: UInt16, Sendable { case `init` = 101, keyModifiers = 102, mouseMotionAck = 111 }
public enum InputsClientMsg: UInt16, Sendable {
    case keyDown = 101, keyUp = 102, keyModifiers = 103
    case mouseMotion = 111, mousePosition = 112, mousePress = 113, mouseRelease = 114
}
public enum InputsCap { public static let keyScancode: UInt32 = 0 }
public enum SpiceMouseMode { public static let server: UInt32 = 1, client: UInt32 = 2 }

public enum MouseButton: UInt8, Sendable, CaseIterable {
    case left = 1, middle = 2, right = 3, up = 4, down = 5
    /// Bit in `buttons_state`; the wheel "buttons" have none.
    public var mask: UInt16 {
        switch self { case .left: 1; case .middle: 2; case .right: 4; case .up, .down: 0 }
    }
}

/// The `buttons_state` word: which physical buttons are currently held.
public struct MouseButtonState: Sendable, Equatable {
    public private(set) var rawValue: UInt16 = 0
    public init() {}
    public mutating func insert(_ b: MouseButton) { rawValue |= b.mask }
    public mutating func remove(_ b: MouseButton) { rawValue &= ~b.mask }
}

public struct LockKeys: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let scrollLock = LockKeys(rawValue: 1)
    public static let numLock = LockKeys(rawValue: 2)
    public static let capsLock = LockKeys(rawValue: 4)
}

/// An XT set-1 make code; `extended` keys are sent with the 0xE0 prefix.
public struct XTScancode: Sendable, Hashable {
    public let code: UInt8
    public let extended: Bool
    public init(_ code: UInt8, extended: Bool = false) { self.code = code & 0x7F; self.extended = extended }

    /// The u32 `code` of KEY_DOWN/KEY_UP: scancode bytes packed low byte first, zero-terminated —
    /// the layout spice-server's `kbd_push_scan` loop unpacks.
    public func wireCode(pressed: Bool) -> UInt32 {
        let byte = UInt32(code) | (pressed ? 0 : 0x80)
        return extended ? 0xE0 | byte << 8 : byte
    }
}

public enum InputsMessage: Sendable, Equatable {
    case `init`(LockKeys), keyModifiers(LockKeys), mouseMotionAck, other(type: UInt16)
    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        switch InputsServerMsg(rawValue: type) {
        case .`init`: self = .`init`(LockKeys(rawValue: try r.u16()))
        case .keyModifiers: self = .keyModifiers(LockKeys(rawValue: try r.u16()))
        case .mouseMotionAck: self = .mouseMotionAck
        case nil: self = .other(type: type)
        }
    }
}

extension ClientMessage {
    public static func keyDown(_ s: XTScancode) -> [UInt8] { var w = SpiceWriter(); w.u32(s.wireCode(pressed: true)); return w.bytes }
    public static func keyUp(_ s: XTScancode) -> [UInt8] { var w = SpiceWriter(); w.u32(s.wireCode(pressed: false)); return w.bytes }
    public static func keyModifiers(_ k: LockKeys) -> [UInt8] { var w = SpiceWriter(); w.u16(k.rawValue); return w.bytes }
    public static func mouseMotion(dx: Int32, dy: Int32, buttons: MouseButtonState) -> [UInt8] {
        var w = SpiceWriter(); w.i32(dx); w.i32(dy); w.u16(buttons.rawValue); return w.bytes
    }
    public static func mousePosition(x: UInt32, y: UInt32, buttons: MouseButtonState, displayID: UInt8) -> [UInt8] {
        var w = SpiceWriter(); w.u32(x); w.u32(y); w.u16(buttons.rawValue); w.u8(displayID); return w.bytes
    }
    public static func mousePress(_ b: MouseButton, buttons: MouseButtonState) -> [UInt8] {
        var w = SpiceWriter(); w.u8(b.rawValue); w.u16(buttons.rawValue); return w.bytes
    }
    public static func mouseRelease(_ b: MouseButton, buttons: MouseButtonState) -> [UInt8] {
        var w = SpiceWriter(); w.u8(b.rawValue); w.u16(buttons.rawValue); return w.bytes
    }
}
```

The tests pass `[.left]`-style literals for `buttons:`; add this so they read well:

```swift
extension MouseButtonState: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MouseButton...) { self.init(); elements.forEach { insert($0) } }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter InputsMessageTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceWire/InputsMessages.swift Tests/SpiceWireTests/InputsMessageTests.swift
git commit -m "feat(wire): inputs channel messages and scancode packing"
```

---

### Task 2: Cursor wire types

**Files:**
- Create: `Sources/SpiceWire/CursorMessages.swift`
- Test: `Tests/SpiceWireTests/CursorMessageTests.swift`

**Interfaces:**
- Produces: `CursorServerMsg`, `CursorFlags.none/.cacheMe/.fromCache: UInt16`, `CursorType`, `SpicePoint16(x:y:)`, `CursorHeader(unique:type:width:height:hotX:hotY:)`, `SpiceCursor(flags:header:data:)`, `CursorMessage` (`.init(position:visible:cursor:)`, `.reset`, `.set(position:visible:cursor:)`, `.move(SpicePoint16)`, `.hide`, `.trail(length:frequency:)`, `.invalOne(UInt64)`, `.invalAll`, `.other(type:)`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SpiceWireTests/CursorMessageTests.swift
import Testing
@testable import SpiceWire

private func header(unique: UInt64 = 7, type: UInt8 = 0, w: UInt16 = 2, h: UInt16 = 1, hx: UInt16 = 0, hy: UInt16 = 0) -> [UInt8] {
    var b = SpiceWriter(); b.u64(unique); b.u8(type); b.u16(w); b.u16(h); b.u16(hx); b.u16(hy); return b.bytes
}

@Test func cursorSetWithShapeParsesHeaderAndTrailingData() throws {
    var w = SpiceWriter()
    w.u16(UInt16(bitPattern: -3)); w.u16(9)    // position (-3, 9)
    w.u8(1)                                    // visible
    w.u16(CursorFlags.cacheMe)
    w.bytes(header()); w.bytes([1, 2, 3, 4, 5, 6, 7, 8])   // 2×1 ALPHA = 8 bytes
    guard case let .set(position, visible, cursor) = try CursorMessage(type: 103, payload: w.bytes) else { Issue.record("not set"); return }
    #expect(position == SpicePoint16(x: -3, y: 9) && visible)
    #expect(cursor.flags == CursorFlags.cacheMe)
    #expect(cursor.header == CursorHeader(unique: 7, type: .alpha, width: 2, height: 1, hotX: 0, hotY: 0))
    #expect(cursor.data == [1, 2, 3, 4, 5, 6, 7, 8])
}

@Test func cursorFlagsNoneCarriesNoHeader() throws {
    var w = SpiceWriter()
    w.u16(10); w.u16(20); w.u16(0); w.u16(0); w.u8(0); w.u16(CursorFlags.none)   // INIT: pos, trail len/freq, visible, flags
    guard case let .`init`(position, visible, cursor) = try CursorMessage(type: 101, payload: w.bytes) else { Issue.record("not init"); return }
    #expect(position == SpicePoint16(x: 10, y: 20) && !visible)
    #expect(cursor.header == nil && cursor.data.isEmpty)
}

@Test func fromCacheHasHeaderButNoData() throws {
    var w = SpiceWriter(); w.u16(0); w.u16(0); w.u8(1); w.u16(CursorFlags.fromCache); w.bytes(header(unique: 99))
    guard case let .set(_, _, cursor) = try CursorMessage(type: 103, payload: w.bytes) else { Issue.record("not set"); return }
    #expect(cursor.header?.unique == 99 && cursor.data.isEmpty)
}

@Test func simpleCursorMessages() throws {
    var mv = SpiceWriter(); mv.u16(5); mv.u16(6)
    #expect(try CursorMessage(type: 104, payload: mv.bytes) == .move(SpicePoint16(x: 5, y: 6)))
    #expect(try CursorMessage(type: 102, payload: []) == .reset)
    #expect(try CursorMessage(type: 105, payload: []) == .hide)
    var tr = SpiceWriter(); tr.u16(3); tr.u16(50)
    #expect(try CursorMessage(type: 106, payload: tr.bytes) == .trail(length: 3, frequency: 50))
    var inv = SpiceWriter(); inv.u64(0xABCD)
    #expect(try CursorMessage(type: 107, payload: inv.bytes) == .invalOne(0xABCD))
    #expect(try CursorMessage(type: 108, payload: []) == .invalAll)
    #expect(try CursorMessage(type: 140, payload: [0]) == .other(type: 140))
}

@Test func malformedCursorThrowsInsteadOfTrapping() {
    #expect(throws: WireError.self) { try CursorMessage(type: 104, payload: [1]) }
    var w = SpiceWriter(); w.u16(0); w.u16(0); w.u8(1); w.u16(0); w.bytes(header(type: 9))   // unknown type
    #expect(throws: WireError.self) { try CursorMessage(type: 103, payload: w.bytes) }
    var big = SpiceWriter(); big.u16(0); big.u16(0); big.u8(1); big.u16(0); big.bytes(header(w: 5000, h: 5000))
    #expect(throws: WireError.self) { try CursorMessage(type: 103, payload: big.bytes) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CursorMessageTests`
Expected: compile error — `CursorMessage` does not exist.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SpiceWire/CursorMessages.swift
public enum CursorServerMsg: UInt16, Sendable {
    case `init` = 101, reset, set, move, hide, trail, invalOne, invalAll
}
public enum CursorFlags { public static let none: UInt16 = 1, cacheMe: UInt16 = 2, fromCache: UInt16 = 4 }
public enum CursorType: UInt8, Sendable { case alpha = 0, mono, color4, color8, color16, color24, color32 }

public struct SpicePoint16: Sendable, Equatable {
    public var x: Int16, y: Int16
    public init(x: Int16, y: Int16) { self.x = x; self.y = y }
    public init(reader r: inout SpiceReader) throws {
        x = Int16(bitPattern: try r.u16()); y = Int16(bitPattern: try r.u16())
    }
}

public struct CursorHeader: Sendable, Equatable {
    public var unique: UInt64, type: CursorType, width: UInt16, height: UInt16, hotX: UInt16, hotY: UInt16
    public static let maxDimension: UInt16 = 1024
    public init(unique: UInt64, type: CursorType, width: UInt16, height: UInt16, hotX: UInt16, hotY: UInt16) {
        self.unique = unique; self.type = type; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
    }
    public init(reader r: inout SpiceReader) throws {
        unique = try r.u64()
        let t = try r.u8()
        guard let type = CursorType(rawValue: t) else { throw WireError.badValue(field: "cursor_type", value: UInt64(t)) }
        self.type = type
        width = try r.u16(); height = try r.u16(); hotX = try r.u16(); hotY = try r.u16()
        guard width <= Self.maxDimension, height <= Self.maxDimension else {
            throw WireError.badValue(field: "cursor_size", value: UInt64(width) << 16 | UInt64(height))
        }
    }
}

/// `header`/`data` are absent when `flags` has NONE; FROM_CACHE carries a header and no data.
/// `data` runs to the end of the message (`@end` in spice.proto) — its meaning depends on `header.type`.
public struct SpiceCursor: Sendable, Equatable {
    public var flags: UInt16
    public var header: CursorHeader?
    public var data: [UInt8]
    public init(flags: UInt16, header: CursorHeader?, data: [UInt8]) { self.flags = flags; self.header = header; self.data = data }
    public init(reader r: inout SpiceReader) throws {
        flags = try r.u16()
        guard flags & CursorFlags.none == 0 else { header = nil; data = []; return }
        header = try CursorHeader(reader: &r)
        data = try r.bytes(r.remaining)
    }
}

public enum CursorMessage: Sendable, Equatable {
    case `init`(position: SpicePoint16, visible: Bool, cursor: SpiceCursor)
    case reset
    case set(position: SpicePoint16, visible: Bool, cursor: SpiceCursor)
    case move(SpicePoint16)
    case hide
    case trail(length: UInt16, frequency: UInt16)
    case invalOne(UInt64)
    case invalAll
    case other(type: UInt16)

    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        switch CursorServerMsg(rawValue: type) {
        case .`init`:
            let p = try SpicePoint16(reader: &r)
            _ = try r.u16(); _ = try r.u16()            // trail length / frequency: not rendered
            let visible = try r.u8() != 0
            self = .`init`(position: p, visible: visible, cursor: try SpiceCursor(reader: &r))
        case .reset: self = .reset
        case .set:
            let p = try SpicePoint16(reader: &r)
            let visible = try r.u8() != 0
            self = .set(position: p, visible: visible, cursor: try SpiceCursor(reader: &r))
        case .move: self = .move(try SpicePoint16(reader: &r))
        case .hide: self = .hide
        case .trail: self = .trail(length: try r.u16(), frequency: try r.u16())
        case .invalOne: self = .invalOne(try r.u64())
        case .invalAll: self = .invalAll
        case nil: self = .other(type: type)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CursorMessageTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceWire/CursorMessages.swift Tests/SpiceWireTests/CursorMessageTests.swift
git commit -m "feat(wire): cursor channel messages"
```

---
### Task 3: Reference-client recording — inputs and cursor fixtures

The one thing Tasks 1–2 cannot prove is that our bytes match what spice-server actually receives from a real client. This task records `remote-viewer` typing and clicking into the dev guest, keeps the inputs/cursor captures as fixtures, and pins our encoders against them.

**Files:**
- Create: `Tests/SpiceKitTests/Fixtures/win-inputs.s2c.bin`, `win-inputs.c2s.bin`, `win-cursor.s2c.bin`
- Create: `Tests/SpiceKitTests/ReferenceClientTests.swift`
- Modify: `docs/dev-server.md` (fixtures table)

**Interfaces:**
- Consumes: `spicerec`, `SpiceLinkReply.parseHeader`, `DataHeader(mini:)`, `ClientMessage.*` from Task 1, `CursorMessage` from Task 2.
- Produces: the three fixtures, referenced by Tasks 5, 8 and 9.

- [ ] **Step 1: Check the dev server and the Ubuntu box**

```bash
scripts/dev-server.sh                      # TCP reachability of 192.168.50.6:5930
ssh nuc2 'which remote-viewer xvfb-run xdotool'
```

If `xdotool` is missing: `ssh nuc2 'sudo apt-get install -y xdotool'`. If `ssh nuc2` is not set up, hand the two remote commands below to the user verbatim and wait — do not skip this task; the whole point is a foreign implementation's bytes.

- [ ] **Step 2: Record**

Terminal 1, here (leave running until the remote session exits):

```bash
swift run spicerec 5901 192.168.50.6 5930 recordings/win-input
```

Terminal 2, on the box (`<mac-ip>` is this Mac's LAN address — `ipconfig getifaddr en0`). The script connects, waits for the window, clicks to grab the pointer (server mode), moves, clicks, types, scrolls, then quits:

```bash
ssh nuc2 'cat > /tmp/drive.sh' <<'EOF'
#!/bin/sh
remote-viewer spice://MACIP:5901 &
sleep 8
W=$(xdotool search --sync --classname remote-viewer | tail -1)
xdotool windowactivate --sync $W
xdotool mousemove --window $W 400 300; sleep 0.5
xdotool click 1;                 sleep 0.5     # grabs the pointer in server mode
xdotool mousemove_relative 10 5; sleep 0.3     # MOUSE_MOTION dx=10 dy=5
xdotool click 1;                 sleep 0.3     # PRESS 1 / RELEASE 1
xdotool click 3;                 sleep 0.3     # PRESS 3 / RELEASE 3
xdotool key a;                   sleep 0.3     # KEY_DOWN 0x1E / KEY_UP 0x9E
xdotool key Delete;              sleep 0.3     # extended: 0x53E0 / 0xD3E0
xdotool key Left;                sleep 0.3     # extended: 0x4BE0 / 0xCBE0
xdotool click 4;                 sleep 0.3     # wheel up: PRESS 4 / RELEASE 4
sleep 2
kill %1
EOF
ssh nuc2 "sed -i 's/MACIP/$(ipconfig getifaddr en0)/' /tmp/drive.sh && timeout 40 xvfb-run -a -s '-screen 0 1280x1024x24' sh /tmp/drive.sh"
```

- [ ] **Step 3: Identify the channels and keep the fixtures**

Each connection's first c2s bytes are the link mess; byte 20 is the channel type (3 = inputs, 4 = cursor):

```bash
for f in recordings/win-input/conn-*.c2s.bin; do printf '%s type=%d\n' "$f" "$(xxd -s 20 -l 1 -p "$f" | sed 's/^/0x/' | xargs printf '%d')"; done
```

Copy the inputs pair and the cursor s2c into `Tests/SpiceKitTests/Fixtures/win-inputs.s2c.bin`, `win-inputs.c2s.bin`, `win-cursor.s2c.bin`. `recordings/` is gitignored; only these three are committed.

- [ ] **Step 4: Decode the c2s inputs capture by hand**

```bash
python3 - <<'EOF'
import struct
b = open('Tests/SpiceKitTests/Fixtures/win-inputs.c2s.bin','rb').read()
size = struct.unpack_from('<I', b, 12)[0]; off = 16 + size          # link mess
off += 4 + 128                                                        # auth mechanism + ticket (client advertised AUTH_SELECTION)
while off + 6 <= len(b):
    t, n = struct.unpack_from('<HI', b, off); p = b[off+6:off+6+n]; off += 6 + n
    print(t, p.hex())
EOF
```

Expected (common messages 1–3 interleaved): `103` KEY_MODIFIERS at start; then `111` motion `0a000000 05000000 0000`; `113`/`114` with `01 0100`/`01 0000`; `113`/`114` with `03 0400`/`03 0000`; `101 1e000000` / `102 9e000000` for "a"; `101 e0530000` / `102 e0d30000` for Delete — the E0 prefix is the **first** byte on the wire (little-endian `0x000053E0`); `101 e04b0000` / `102 e0cb0000` for Left; `113 04 0000` / `114 04 0000` for wheel up. If the reference client puts E0 anywhere else, stop and fix `XTScancode.wireCode` (Task 1) before building on it. Also confirm the link mess channel caps word for inputs has bit 0 (KEY_SCANCODE) set.

- [ ] **Step 5: Pin the encodings against the recording**

```swift
// Tests/SpiceKitTests/ReferenceClientTests.swift
import Foundation
import Testing
import SpiceWire

/// Frames the reference client (remote-viewer, driven by xdotool) sent on its inputs channel,
/// in order, skipping ACK_SYNC/ACK/PONG. If our encoders agree with these bytes they agree with
/// spice-server; our own decoder is not a witness.
private func referenceInputFrames() throws -> [(type: UInt16, payload: [UInt8])] {
    let url = try #require(Bundle.module.url(forResource: "win-inputs.c2s", withExtension: "bin", subdirectory: "Fixtures"))
    let b = [UInt8](try Data(contentsOf: url))
    var r = SpiceReader(b)
    try r.skip(12); let linkSize = Int(try r.u32()); try r.skip(linkSize)
    try r.skip(4 + Link.ticketBytes)
    var out: [(UInt16, [UInt8])] = []
    while r.remaining >= DataHeader.miniSize {
        let h = try DataHeader(mini: &r)
        let p = try r.bytes(Int(h.size))
        if h.type > 100 { out.append((h.type, p)) }
    }
    return out
}

@Test func referenceClientKeyAndMouseEncodings() throws {
    let frames = try referenceInputFrames()
    func payloads(_ type: InputsClientMsg) -> [[UInt8]] { frames.filter { $0.type == type.rawValue }.map(\.payload) }

    #expect(payloads(.keyDown).contains(ClientMessage.keyDown(XTScancode(0x1E))))                       // a
    #expect(payloads(.keyUp).contains(ClientMessage.keyUp(XTScancode(0x1E))))
    #expect(payloads(.keyDown).contains(ClientMessage.keyDown(XTScancode(0x53, extended: true))))       // Delete
    #expect(payloads(.keyUp).contains(ClientMessage.keyUp(XTScancode(0x53, extended: true))))
    #expect(payloads(.keyDown).contains(ClientMessage.keyDown(XTScancode(0x4B, extended: true))))       // Left
    #expect(payloads(.mouseMotion).contains(ClientMessage.mouseMotion(dx: 10, dy: 5, buttons: [])))
    #expect(payloads(.mousePress).contains(ClientMessage.mousePress(.left, buttons: [.left])))
    #expect(payloads(.mouseRelease).contains(ClientMessage.mouseRelease(.left, buttons: [])))
    #expect(payloads(.mousePress).contains(ClientMessage.mousePress(.right, buttons: [.right])))
    #expect(payloads(.mousePress).contains(ClientMessage.mousePress(.up, buttons: [])))
    #expect(!payloads(.keyModifiers).isEmpty)
}

@Test func referenceClientAdvertisesKeyScancode() throws {
    let url = try #require(Bundle.module.url(forResource: "win-inputs.c2s", withExtension: "bin", subdirectory: "Fixtures"))
    var r = SpiceReader([UInt8](try Data(contentsOf: url)))
    try r.skip(16 + 4 + 2)                    // header, connection id, type/id
    let nCommon = try r.u32(), nChannel = try r.u32(); _ = try r.u32()
    try r.skip(Int(nCommon) * 4)
    let channelCaps = CapabilitySet(words: try (0 ..< nChannel).map { _ in try r.u32() })
    #expect(channelCaps.contains(InputsCap.keyScancode))
}
```

If xdotool's motion arrived split across several `MOUSE_MOTION` frames (X may deliver 10,5 as two events), relax the motion expectation to "the dx sum of consecutive motion frames after the grab is 10 and the dy sum is 5", computed with `SpiceReader` — but keep the exact-bytes checks for keys and buttons.

- [ ] **Step 6: Run**

Run: `swift test --filter ReferenceClientTests`
Expected: 2 tests pass. If the scancode test fails, the fix is in `XTScancode.wireCode` (Task 1), not in the test.

- [ ] **Step 7: Document and commit**

Add three rows to the fixtures table in `docs/dev-server.md` (name, source connection, contents — list the message types seen in Step 4 and the cursor s2c: expect `CURSOR_INIT` with flags NONE from a VGA guest, plus pings), and the xdotool recipe under "Recorded fixtures".

```bash
git add Tests/SpiceKitTests/Fixtures/win-inputs.s2c.bin Tests/SpiceKitTests/Fixtures/win-inputs.c2s.bin \
        Tests/SpiceKitTests/Fixtures/win-cursor.s2c.bin Tests/SpiceKitTests/ReferenceClientTests.swift docs/dev-server.md
git commit -m "test(kit): pin inputs encoders against a remote-viewer recording; cursor fixture"
```

---

### Task 4: MotionThrottle and InputsChannel

**Files:**
- Create: `Sources/SpiceCore/MotionThrottle.swift`, `Sources/SpiceCore/InputsChannel.swift`
- Modify: `Tests/SpiceCoreTests/TestSupport.swift` (add `fakeLink`)
- Test: `Tests/SpiceCoreTests/MotionThrottleTests.swift`, `Tests/SpiceCoreTests/InputsChannelTests.swift`

**Interfaces:**
- Consumes: `LinkHandshake.perform`, `ChannelReader`, `InMemoryTransport`, Task 1 types.
- Produces: `MotionThrottle` (`offer(_:) -> Pending?`, `acked() -> Pending?`), `actor InputsChannel` with `static func open(transport:connectionID:password:)`, `keyDown(_:)`, `keyUp(_:)`, `releaseAllKeys()`, `setLockKeys(_:)`, `syncCapsLock(_ on: Bool)`, `mouseMotion(dx:dy:)`, `mousePosition(x:y:displayID:)`, `buttonDown(_:)`, `buttonUp(_:)`, `guestLockKeys: LockKeys`, `heldKeys: Set<XTScancode>`, `close()`.

- [ ] **Step 1: Write the failing throttle tests**

```swift
// Tests/SpiceCoreTests/MotionThrottleTests.swift
import Testing
@testable import SpiceCore

@Test func holdsAtEightInFlightAndCoalesces() {
    var t = MotionThrottle()
    for i in 0 ..< 8 { #expect(t.offer(.motion(dx: 1, dy: Int32(i))) != nil) }
    #expect(t.offer(.motion(dx: 2, dy: 3)) == nil)
    #expect(t.offer(.motion(dx: 4, dy: 5)) == nil)
    #expect(t.pending == .motion(dx: 6, dy: 8))            // deltas sum while held
    #expect(t.acked() == .motion(dx: 6, dy: 8))            // one ack frees a bunch of 4 and flushes
    #expect(t.pending == nil && t.inFlight == 5)
}

@Test func positionReplacesInsteadOfSumming() {
    var t = MotionThrottle()
    for _ in 0 ..< 8 { _ = t.offer(.position(x: 0, y: 0, displayID: 0)) }
    _ = t.offer(.position(x: 10, y: 10, displayID: 0))
    _ = t.offer(.position(x: 20, y: 30, displayID: 0))
    #expect(t.pending == .position(x: 20, y: 30, displayID: 0))
    _ = t.offer(.motion(dx: 1, dy: 1))                      // mode switched mid-hold: newest wins
    #expect(t.pending == .motion(dx: 1, dy: 1))
}

@Test func ackWithNothingPendingJustDecrements() {
    var t = MotionThrottle()
    _ = t.offer(.motion(dx: 1, dy: 1))
    #expect(t.acked() == nil && t.inFlight == 0)           // never below zero
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MotionThrottleTests`
Expected: compile error.

- [ ] **Step 3: Implement MotionThrottle**

```swift
// Sources/SpiceCore/MotionThrottle.swift
/// spice-server answers every 4 motion/position messages with MOUSE_MOTION_ACK. Sending without
/// bound floods a slow guest with stale positions, so like spice-gtk we hold at 8 in flight and
/// coalesce what arrives meanwhile: deltas add up, positions replace each other.
struct MotionThrottle: Sendable, Equatable {
    static let ackBunch = 4
    static let maxInFlight = ackBunch * 2

    enum Pending: Sendable, Equatable {
        case motion(dx: Int32, dy: Int32)
        case position(x: UInt32, y: UInt32, displayID: UInt8)
    }

    private(set) var inFlight = 0
    private(set) var pending: Pending?

    /// The message to send now, or nil if it was held.
    mutating func offer(_ p: Pending) -> Pending? {
        guard inFlight < Self.maxInFlight else {
            if case let .motion(dx, dy) = p, case let .motion(px, py)? = pending {
                pending = .motion(dx: px &+ dx, dy: py &+ dy)
            } else {
                pending = p
            }
            return nil
        }
        inFlight += 1
        return p
    }

    /// Call on MOUSE_MOTION_ACK; returns the held message to send now, if any.
    mutating func acked() -> Pending? {
        inFlight = max(0, inFlight - Self.ackBunch)
        guard let p = pending else { return nil }
        pending = nil
        inFlight += 1
        return p
    }
}
```

- [ ] **Step 4: Run the throttle tests**

Run: `swift test --filter MotionThrottleTests`
Expected: 3 pass.

- [ ] **Step 5: Add the link-preamble helper**

`MainChannelTests` builds a fake link reply inline; the new channel tests need the same bytes. Add to `Tests/SpiceCoreTests/TestSupport.swift` (leave `MainChannelTests` untouched):

```swift
import Foundation
import Security
@testable import SpiceCore

/// Link header + reply (fresh RSA key, MINI_HEADER + AUTH_SPICE) + link result OK, so a
/// channel's `open` succeeds against an `InMemoryTransport`. `body` follows as mini-header frames.
func fakeLink(channelCaps: UInt32 = 0, body: [UInt8]) throws -> [UInt8] {
    var err: Unmanaged<CFError>?
    guard let priv = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024] as CFDictionary, &err),
          let pub = SecKeyCopyPublicKey(priv),
          let pkcs1 = SecKeyCopyExternalRepresentation(pub, &err) as Data? else { throw SpiceError(.auth, underlying: "keygen") }
    var w = SpiceWriter()
    w.u32(Link.magic); w.u32(2); w.u32(2); w.u32(0)
    let start = w.bytes.count
    w.u32(0); w.bytes(Ticket.wrapSPKI(pkcs1: [UInt8](pkcs1)))
    w.u32(1); w.u32(1); w.u32(178)
    w.u32(1 << CommonCap.miniHeader | 1 << CommonCap.authSpice); w.u32(channelCaps)
    w.patchU32(at: 12, UInt32(w.bytes.count - start))
    w.u32(0)                                   // link result
    w.bytes(body)
    return w.bytes
}

func frame(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
    ClientMessage.frame(type: type, payload: payload, mini: true, serial: 0)
}
```

Note the reply now has one channel-caps word (`w.u32(1); w.u32(1); w.u32(178)` = 1 common, 1 channel, offset 178) — `SpiceLinkReply` reads `nChannel` words, so this is consistent.

- [ ] **Step 6: Write the failing InputsChannel tests**

```swift
// Tests/SpiceCoreTests/InputsChannelTests.swift
import Testing
import SpiceWire
@testable import SpiceCore

/// Bytes the channel wrote after the link exchange, split into (type, payload) mini-header frames.
private func sentFrames(_ t: InMemoryTransport) async throws -> [(UInt16, [UInt8])] {
    let all = await t.written
    var r = SpiceReader(all)
    try r.skip(12); let n = Int(try r.u32()); try r.skip(n)      // link header size field, then the mess
    try r.skip(4 + Link.ticketBytes)                              // auth mechanism + ticket
    var out: [(UInt16, [UInt8])] = []
    while r.remaining >= DataHeader.miniSize {
        let h = try DataHeader(mini: &r); out.append((h.type, try r.bytes(Int(h.size))))
    }
    return out
}

private func openInputs(_ body: [UInt8] = frame(InputsServerMsg.`init`.rawValue, [2, 0])) async throws -> (InputsChannel, InMemoryTransport) {
    let t = InMemoryTransport(input: try fakeLink(body: body))
    return (try await InputsChannel.open(transport: t, connectionID: 1, password: nil), t)
}

@Test func advertisesKeyScancodeAndReadsInit() async throws {
    let (ch, t) = try await openInputs()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await ch.guestLockKeys == [.numLock])
    var r = SpiceReader(await t.written); try r.skip(16 + 4 + 2 + 4 + 4 + 4 + 4)   // header, conn id, type/id, ncommon, nchannel, offset, common word
    #expect(CapabilitySet(words: [try r.u32()]).contains(InputsCap.keyScancode))
}

@Test func keysTrackHeldSetAndReleaseAll() async throws {
    let (ch, t) = try await openInputs()
    let a = XTScancode(0x1E), ctrl = XTScancode(0x1D, extended: true)
    try await ch.keyDown(ctrl); try await ch.keyDown(a); try await ch.keyUp(a)
    #expect(await ch.heldKeys == [ctrl])
    try await ch.releaseAllKeys()
    #expect(await ch.heldKeys.isEmpty)
    let f = try await sentFrames(t).filter { $0.0 == InputsClientMsg.keyDown.rawValue || $0.0 == InputsClientMsg.keyUp.rawValue }
    #expect(f.map(\.1) == [ClientMessage.keyDown(ctrl), ClientMessage.keyDown(a), ClientMessage.keyUp(a), ClientMessage.keyUp(ctrl)])
}

@Test func buttonsStateAccumulates() async throws {
    let (ch, t) = try await openInputs()
    try await ch.buttonDown(.left); try await ch.buttonDown(.right); try await ch.mouseMotion(dx: 1, dy: 0); try await ch.buttonUp(.left)
    let f = try await sentFrames(t).filter { $0.0 >= 111 }
    #expect(f.map(\.1) == [ClientMessage.mousePress(.left, buttons: [.left]),
                           ClientMessage.mousePress(.right, buttons: [.left, .right]),
                           ClientMessage.mouseMotion(dx: 1, dy: 0, buttons: [.left, .right]),
                           ClientMessage.mouseRelease(.left, buttons: [.right])])
}

@Test func motionIsThrottledUntilAck() async throws {
    // No ACK in the input: the 9th and 10th motions must be held, coalesced, and not written.
    let (ch, t) = try await openInputs()
    for _ in 0 ..< 10 { try await ch.mouseMotion(dx: 1, dy: 1) }
    let before = try await sentFrames(t).filter { $0.0 == InputsClientMsg.mouseMotion.rawValue }
    #expect(before.count == 8)
    await ch.handleForTesting(.mouseMotionAck)
    let after = try await sentFrames(t).filter { $0.0 == InputsClientMsg.mouseMotion.rawValue }
    #expect(after.count == 9 && after.last?.1 == ClientMessage.mouseMotion(dx: 2, dy: 2, buttons: []))
}

@Test func capsLockSyncPreservesGuestNumAndScroll() async throws {
    let (ch, t) = try await openInputs(frame(InputsServerMsg.`init`.rawValue, [3, 0]))   // guest: scroll + num
    try await Task.sleep(for: .milliseconds(50))
    try await ch.syncCapsLock(true)
    let f = try await sentFrames(t).filter { $0.0 == InputsClientMsg.keyModifiers.rawValue }
    #expect(f.last?.1 == ClientMessage.keyModifiers([.scrollLock, .numLock, .capsLock]))
}
```

- [ ] **Step 7: Run to verify they fail**

Run: `swift test --filter InputsChannelTests`
Expected: compile error — `InputsChannel` does not exist.

- [ ] **Step 8: Implement InputsChannel**

```swift
// Sources/SpiceCore/InputsChannel.swift
import os
import SpiceWire

/// The inputs channel: every key and pointer message the guest receives goes through here, in the
/// order it was called. The caller (SpiceSession's single input pump) serialises calls; this actor
/// owns the state the wire needs — held keys, buttons_state, motion flow control, guest lock keys.
public actor InputsChannel {
    public static let descriptor = ChannelDescriptor(type: .inputs, id: 0)
    private let reader: ChannelReader
    private let loop: Task<Void, Never>
    private var pump: Task<Void, Never>?
    private let log = Logger(subsystem: "com.spicesee", category: "inputs")

    public private(set) var heldKeys: Set<XTScancode> = []
    public private(set) var guestLockKeys: LockKeys = []
    private var buttons = MouseButtonState()
    private var throttle = MotionThrottle()

    public static func clientCaps() -> CapabilitySet { CapabilitySet(bits: [InputsCap.keyScancode]) }

    public static func open(transport: any Transport, connectionID: UInt32, password: String?) async throws -> InputsChannel {
        let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: descriptor,
                                                   channelCaps: clientCaps(), password: password)
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: descriptor)
        let loop = Task { await reader.run() }
        let channel = InputsChannel(reader: reader, loop: loop)
        await channel.startPump()
        return channel
    }

    private init(reader: ChannelReader, loop: Task<Void, Never>) { self.reader = reader; self.loop = loop }

    private func startPump() {
        let messages = reader.messages
        pump = Task { [weak self] in
            for await raw in messages {
                guard let self else { return }
                do { await self.handle(try InputsMessage(type: raw.type, payload: raw.payload)) }
                catch { await self.log.error("inputs: drop type \(raw.type): \(String(describing: error))") }
            }
        }
    }

    private func handle(_ m: InputsMessage) async {
        switch m {
        case let .`init`(k), let .keyModifiers(k): guestLockKeys = k
        case .mouseMotionAck:
            if let p = throttle.acked() { try? await send(p) }
        case .other: break
        }
    }

    /// Feeds a server message as if it had arrived on the wire (tests only).
    func handleForTesting(_ m: InputsMessage) async { await handle(m) }

    // MARK: Keyboard

    public func keyDown(_ s: XTScancode) async throws {
        heldKeys.insert(s)
        try await reader.send(type: InputsClientMsg.keyDown.rawValue, payload: ClientMessage.keyDown(s))
    }
    public func keyUp(_ s: XTScancode) async throws {
        heldKeys.remove(s)
        try await reader.send(type: InputsClientMsg.keyUp.rawValue, payload: ClientMessage.keyUp(s))
    }
    /// On focus loss: the guest must not be left with a stuck modifier.
    public func releaseAllKeys() async throws {
        for s in heldKeys.sorted(by: { ($0.extended ? 256 : 0) + Int($0.code) < ($1.extended ? 256 : 0) + Int($1.code) }) {
            try await reader.send(type: InputsClientMsg.keyUp.rawValue, payload: ClientMessage.keyUp(s))
        }
        heldKeys = []
    }
    public func setLockKeys(_ k: LockKeys) async throws {
        try await reader.send(type: InputsClientMsg.keyModifiers.rawValue, payload: ClientMessage.keyModifiers(k))
    }
    /// Caps lock is the only lock state macOS exposes; num and scroll keep what the guest reported.
    public func syncCapsLock(_ on: Bool) async throws {
        var k = guestLockKeys
        if on { k.insert(.capsLock) } else { k.remove(.capsLock) }
        try await setLockKeys(k)
    }

    // MARK: Pointer

    public func mouseMotion(dx: Int32, dy: Int32) async throws {
        if let p = throttle.offer(.motion(dx: dx, dy: dy)) { try await send(p) }
    }
    public func mousePosition(x: UInt32, y: UInt32, displayID: UInt8) async throws {
        if let p = throttle.offer(.position(x: x, y: y, displayID: displayID)) { try await send(p) }
    }
    public func buttonDown(_ b: MouseButton) async throws {
        buttons.insert(b)
        try await reader.send(type: InputsClientMsg.mousePress.rawValue, payload: ClientMessage.mousePress(b, buttons: buttons))
    }
    public func buttonUp(_ b: MouseButton) async throws {
        buttons.remove(b)
        try await reader.send(type: InputsClientMsg.mouseRelease.rawValue, payload: ClientMessage.mouseRelease(b, buttons: buttons))
    }

    private func send(_ p: MotionThrottle.Pending) async throws {
        switch p {
        case let .motion(dx, dy):
            try await reader.send(type: InputsClientMsg.mouseMotion.rawValue, payload: ClientMessage.mouseMotion(dx: dx, dy: dy, buttons: buttons))
        case let .position(x, y, id):
            try await reader.send(type: InputsClientMsg.mousePosition.rawValue, payload: ClientMessage.mousePosition(x: x, y: y, buttons: buttons, displayID: id))
        }
    }

    public func close() { pump?.cancel(); loop.cancel() }
}
```

- [ ] **Step 9: Run all core tests**

Run: `swift test --filter SpiceCoreTests`
Expected: all pass, including the 5 new `InputsChannelTests` and the untouched `MainChannelTests`.

- [ ] **Step 10: Commit**

```bash
git add Sources/SpiceCore/MotionThrottle.swift Sources/SpiceCore/InputsChannel.swift Tests/SpiceCoreTests/TestSupport.swift \
        Tests/SpiceCoreTests/MotionThrottleTests.swift Tests/SpiceCoreTests/InputsChannelTests.swift
git commit -m "feat(core): InputsChannel actor with motion flow control"
```

---

### Task 5: CursorChannel

**Files:**
- Create: `Sources/SpiceCore/CursorChannel.swift`
- Test: `Tests/SpiceCoreTests/CursorChannelTests.swift`

**Interfaces:**
- Consumes: `LinkHandshake`, `ChannelReader`, `CursorMessage` (Task 2), `fakeLink`/`frame` (Task 4).
- Produces: `actor CursorChannel` with `static func open(transport:connectionID:id:password:)`, `nonisolated let messages: AsyncStream<CursorMessage>`, `close()`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SpiceCoreTests/CursorChannelTests.swift
import Foundation
import Testing
import SpiceWire
@testable import SpiceCore

@Test func cursorChannelStreamsParsedMessages() async throws {
    var set = SpiceWriter(); set.u16(1); set.u16(2); set.u8(1); set.u16(CursorFlags.none)
    var mv = SpiceWriter(); mv.u16(7); mv.u16(8)
    let body = frame(CursorServerMsg.set.rawValue, set.bytes) + frame(CursorServerMsg.move.rawValue, mv.bytes)
             + frame(CursorServerMsg.hide.rawValue, []) + frame(CursorServerMsg.move.rawValue, [1])   // last one malformed: dropped, not fatal
    let t = InMemoryTransport(input: try fakeLink(body: body))
    let ch = try await CursorChannel.open(transport: t, connectionID: 1, id: 0, password: nil)
    var got: [CursorMessage] = []
    for await m in ch.messages { got.append(m) }
    #expect(got == [.set(position: SpicePoint16(x: 1, y: 2), visible: true, cursor: SpiceCursor(flags: 1, header: nil, data: [])),
                    .move(SpicePoint16(x: 7, y: 8)), .hide])
}

@Test func recordedCursorChannelReplays() async throws {
    // A VGA guest has no cursor commands: expect INIT with flags NONE and nothing else that matters.
    let url = try #require(Bundle.module.url(forResource: "win-cursor.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let t = InMemoryTransport(input: [UInt8](try Data(contentsOf: url)))
    let ch = try await CursorChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    var got: [CursorMessage] = []
    for await m in ch.messages { got.append(m) }
    guard case .`init`? = got.first else { Issue.record("expected CURSOR_INIT first, got \(String(describing: got.first))"); return }
}
```

The second test needs the fixture in `SpiceCoreTests`: add `resources: [.copy("Fixtures")]` to the `SpiceCoreTests` target in `Package.swift` and a symlink `Tests/SpiceCoreTests/Fixtures/win-cursor.s2c.bin -> ../../SpiceKitTests/Fixtures/win-cursor.s2c.bin` (SPM copies through symlinks). If SPM refuses the symlink on this toolchain, copy the file — it is small — and say so in the commit.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CursorChannelTests`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
// Sources/SpiceCore/CursorChannel.swift
import os
import SpiceWire

public actor CursorChannel {
    public nonisolated let messages: AsyncStream<CursorMessage>
    private let reader: ChannelReader
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?) async throws -> CursorChannel {
        let desc = ChannelDescriptor(type: .cursor, id: id)
        let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                   channelCaps: CapabilitySet(), password: password)
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
        let loop = Task { await reader.run() }
        return CursorChannel(reader: reader, loop: loop, descriptor: desc)
    }

    private init(reader: ChannelReader, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: CursorMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "cursor")
        let source = reader.messages
        pump = Task {
            for await raw in source {
                do { cont.yield(try CursorMessage(type: raw.type, payload: raw.payload)) }
                catch { log.error("cursor/\(descriptor.id): drop type \(raw.type): \(String(describing: error))") }
            }
            cont.finish()
        }
    }

    public func close() { pump.cancel(); loop.cancel() }
}
```

- [ ] **Step 4: Run**

Run: `swift test --filter CursorChannelTests`
Expected: 2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceCore/CursorChannel.swift Tests/SpiceCoreTests/CursorChannelTests.swift Package.swift Tests/SpiceCoreTests/Fixtures
git commit -m "feat(core): CursorChannel actor"
```

---
### Task 6: Cursor shape decoding, cache, and tracker

**Files:**
- Create: `Sources/SpiceCanvas/CursorShape.swift`, `Sources/SpiceCanvas/CursorTracker.swift`
- Test: `Tests/SpiceCanvasTests/CursorDecoderTests.swift`, `Tests/SpiceCanvasTests/CursorTrackerTests.swift`

**Interfaces:**
- Consumes: `CursorHeader`, `SpiceCursor`, `CursorMessage`, `CursorFlags`, `CursorType` (Task 2), `CanvasError`.
- Produces: `CursorShape(width:height:hotX:hotY:pixels:)` (BGRA, straight alpha, tightly packed), `CursorDecoder.decode(_:data:) throws -> CursorShape`, `CursorChange` (`.shape(CursorShape?)` — nil means hidden; `.moved(x:y:)`), `struct CursorTracker` with `mutating func apply(_: CursorMessage) -> [CursorChange]`.

- [ ] **Step 1: Write the failing decoder tests**

```swift
// Tests/SpiceCanvasTests/CursorDecoderTests.swift
import Testing
import SpiceWire
@testable import SpiceCanvas

private func hdr(_ type: CursorType, w: UInt16, h: UInt16) -> CursorHeader {
    CursorHeader(unique: 1, type: type, width: w, height: h, hotX: 1, hotY: 0)
}

@Test func alphaIsCopiedVerbatim() throws {
    let px: [UInt8] = [10, 20, 30, 255, 0, 0, 0, 0]
    let s = try CursorDecoder.decode(hdr(.alpha, w: 2, h: 1), data: px)
    #expect(s.pixels == px && s.width == 2 && s.height == 1 && s.hotX == 1)
}

@Test func monoUsesAndThenXorPlanesRowPadded() throws {
    // 9×1: AND plane is 2 bytes/row, XOR plane 2 bytes/row.
    // pixel 0: and=0,xor=0 → black; 1: and=0,xor=1 → white; 2: and=1,xor=0 → transparent; 3: and=1,xor=1 → invert (black @ 0x80)
    let and: [UInt8] = [0b0011_0000, 0]
    let xor: [UInt8] = [0b0101_0000, 0]
    let s = try CursorDecoder.decode(hdr(.mono, w: 9, h: 1), data: and + xor)
    func px(_ i: Int) -> [UInt8] { Array(s.pixels[i * 4 ..< i * 4 + 4]) }
    #expect(px(0) == [0, 0, 0, 255])
    #expect(px(1) == [255, 255, 255, 255])
    #expect(px(2)[3] == 0)
    #expect(px(3) == [0, 0, 0, 0x80])
    #expect(px(8)[3] == 255)   // 9th pixel lives in the second byte of each row
}

@Test func color32MaskBitHidesPixels() throws {
    // 2×1 BGRX then a 1-bit mask (linear over pixels, MSB first): pixel 1 masked out.
    let data: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0, 0b0100_0000]
    let s = try CursorDecoder.decode(hdr(.color32, w: 2, h: 1), data: data)
    #expect(s.pixels == [1, 2, 3, 255, 4, 5, 6, 0])
}

@Test func color24AndColor16Expand() throws {
    let c24 = try CursorDecoder.decode(hdr(.color24, w: 1, h: 1), data: [1, 2, 3, 0])
    #expect(c24.pixels == [1, 2, 3, 255])
    // RGB555 0x7C00 = red max → B 0, G 0, R 0xF8
    let c16 = try CursorDecoder.decode(hdr(.color16, w: 1, h: 1), data: [0x00, 0x7C, 0])
    #expect(c16.pixels == [0, 0, 0xF8, 255])
}

@Test func shortDataThrowsInsteadOfTrapping() {
    #expect(throws: CanvasError.self) { try CursorDecoder.decode(hdr(.alpha, w: 4, h: 4), data: [0, 0, 0]) }
    #expect(throws: CanvasError.self) { try CursorDecoder.decode(hdr(.mono, w: 8, h: 2), data: [0, 0, 0]) }
    #expect(throws: CanvasError.self) { try CursorDecoder.decode(hdr(.color32, w: 2, h: 1), data: [1, 2, 3, 0, 4, 5, 6, 0]) }   // no mask byte
    #expect(throws: CanvasError.self) { try CursorDecoder.decode(hdr(.color8, w: 1, h: 1), data: [0]) }                       // paletted: unsupported
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CursorDecoderTests`
Expected: compile error.

- [ ] **Step 3: Implement the decoder**

```swift
// Sources/SpiceCanvas/CursorShape.swift
import SpiceWire

/// A decoded cursor: BGRA, straight (non-premultiplied) alpha, `width * 4` bytes per row.
public struct CursorShape: Sendable, Equatable {
    public var width: Int, height: Int, hotX: Int, hotY: Int
    public var pixels: [UInt8]
    public init(width: Int, height: Int, hotX: Int, hotY: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY; self.pixels = pixels
    }
}

public enum CursorDecoder {
    public static func decode(_ h: CursorHeader, data: [UInt8]) throws -> CursorShape {
        let w = Int(h.width), ht = Int(h.height), n = w * ht
        var out = [UInt8](repeating: 0, count: n * 4)
        func need(_ bytes: Int) throws {
            guard data.count >= bytes else { throw CanvasError.decode("cursor \(h.type): need \(bytes) bytes, have \(data.count)") }
        }
        // Colour cursors trail a 1-bit AND mask indexed linearly over pixels, MSB first (spice-gtk's get_pix_mask).
        func masked(_ i: Int, at offset: Int) -> Bool { data[offset + i >> 3] & (0x80 >> (i & 7)) != 0 }
        let maskBytes = (n + 7) / 8

        switch h.type {
        case .alpha:
            try need(n * 4)
            out = Array(data[0 ..< n * 4])
        case .mono:
            let bpl = (w + 7) / 8
            try need(bpl * ht * 2)
            for y in 0 ..< ht {
                for x in 0 ..< w {
                    let byte = y * bpl + x >> 3, bit: UInt8 = 0x80 >> (x & 7)
                    let and = data[byte] & bit != 0, xor = data[bpl * ht + byte] & bit != 0
                    let o = (y * w + x) * 4
                    switch (and, xor) {
                    case (false, false): out[o + 3] = 0xFF                                       // black
                    case (false, true): out[o] = 0xFF; out[o + 1] = 0xFF; out[o + 2] = 0xFF; out[o + 3] = 0xFF   // white
                    case (true, false): break                                                    // transparent
                    case (true, true): out[o + 3] = 0x80                                         // "invert": spice-gtk draws half-black
                    }
                }
            }
        case .color32:
            try need(n * 4 + maskBytes)
            for i in 0 ..< n {
                let s = i * 4, o = i * 4
                out[o] = data[s]; out[o + 1] = data[s + 1]; out[o + 2] = data[s + 2]
                if masked(i, at: n * 4) {
                    // spice-gtk: a masked-out pure-white pixel is an XOR (inverting) pixel; draw it half-black.
                    if data[s] == 0xFF, data[s + 1] == 0xFF, data[s + 2] == 0xFF { out[o] = 0; out[o + 1] = 0; out[o + 2] = 0; out[o + 3] = 0x80 }
                } else {
                    out[o + 3] = 0xFF
                }
            }
        case .color24:
            try need(n * 3 + maskBytes)
            for i in 0 ..< n {
                let s = i * 3, o = i * 4
                out[o] = data[s]; out[o + 1] = data[s + 1]; out[o + 2] = data[s + 2]
                out[o + 3] = masked(i, at: n * 3) ? 0 : 0xFF
            }
        case .color16:
            try need(n * 2 + maskBytes)
            for i in 0 ..< n {
                let v = UInt16(data[i * 2]) | UInt16(data[i * 2 + 1]) << 8, o = i * 4
                out[o] = UInt8((v & 0x1F) << 3); out[o + 1] = UInt8(((v >> 5) & 0x1F) << 3); out[o + 2] = UInt8(((v >> 10) & 0x1F) << 3)
                out[o + 3] = masked(i, at: n * 2) ? 0 : 0xFF
            }
        case .color4, .color8:
            // Paletted cursors: no modern QXL driver emits them and spice-gtk does not decode them either.
            throw CanvasError.unsupported("cursor type \(h.type)")
        }
        return CursorShape(width: w, height: ht, hotX: Int(h.hotX), hotY: Int(h.hotY), pixels: out)
    }
}
```

- [ ] **Step 4: Run the decoder tests**

Run: `swift test --filter CursorDecoderTests`
Expected: 5 pass.

- [ ] **Step 5: Write the failing tracker tests**

```swift
// Tests/SpiceCanvasTests/CursorTrackerTests.swift
import Testing
import SpiceWire
@testable import SpiceCanvas

private let shapeHeader = CursorHeader(unique: 42, type: .alpha, width: 1, height: 1, hotX: 0, hotY: 0)
private let shapePixels: [UInt8] = [9, 8, 7, 255]
private let shape = CursorShape(width: 1, height: 1, hotX: 0, hotY: 0, pixels: shapePixels)

@Test func setDecodesCachesAndPositions() {
    var t = CursorTracker()
    let set = CursorMessage.set(position: SpicePoint16(x: 3, y: 4), visible: true,
                                cursor: SpiceCursor(flags: CursorFlags.cacheMe, header: shapeHeader, data: shapePixels))
    #expect(t.apply(set) == [.shape(shape), .moved(x: 3, y: 4)])
    let fromCache = CursorMessage.set(position: SpicePoint16(x: 0, y: 0), visible: true,
                                      cursor: SpiceCursor(flags: CursorFlags.fromCache, header: shapeHeader, data: []))
    #expect(t.apply(fromCache) == [.shape(shape), .moved(x: 0, y: 0)])
    _ = t.apply(.invalAll)
    #expect(t.apply(fromCache) == [.moved(x: 0, y: 0)])   // cache miss: keep the current shape, still move
}

@Test func visibilityAndNoneFlag() {
    var t = CursorTracker()
    let hidden = CursorMessage.`init`(position: SpicePoint16(x: 1, y: 1), visible: false,
                                      cursor: SpiceCursor(flags: CursorFlags.none, header: nil, data: []))
    #expect(t.apply(hidden) == [.shape(nil), .moved(x: 1, y: 1)])
    #expect(t.apply(.hide) == [.shape(nil)])
    #expect(t.apply(.move(SpicePoint16(x: 5, y: 6))) == [.moved(x: 5, y: 6)])
    #expect(t.apply(.reset) == [.shape(nil)])
    #expect(t.apply(.trail(length: 1, frequency: 1)).isEmpty)
}

@Test func undecodableShapeIsSkipped() {
    var t = CursorTracker()
    let bad = CursorMessage.set(position: SpicePoint16(x: 0, y: 0), visible: true,
                                cursor: SpiceCursor(flags: 0, header: CursorHeader(unique: 0, type: .alpha, width: 4, height: 4, hotX: 0, hotY: 0), data: [1]))
    #expect(t.apply(bad) == [.moved(x: 0, y: 0)])
}
```

- [ ] **Step 6: Implement the tracker**

```swift
// Sources/SpiceCanvas/CursorTracker.swift
import os
import SpiceWire

public enum CursorChange: Sendable, Equatable {
    /// The pointer's shape; nil hides it.
    case shape(CursorShape?)
    /// Server-mode pointer position in surface pixels (client mode ignores it).
    case moved(x: Int, y: Int)
}

/// Turns the cursor channel's message stream into shape/position changes, owning the cursor cache
/// (CACHE_ME / FROM_CACHE / INVAL_ONE / INVAL_ALL). Pure value type: a session keeps one per channel.
public struct CursorTracker: Sendable {
    private var cache: [UInt64: CursorShape] = [:]
    private static let log = Logger(subsystem: "com.spicesee", category: "cursor")
    public init() {}

    public mutating func apply(_ m: CursorMessage) -> [CursorChange] {
        switch m {
        case let .`init`(position, visible, cursor), let .set(position, visible, cursor):
            var out: [CursorChange] = []
            if !visible {
                out.append(.shape(nil))
            } else if let shape = resolve(cursor) {
                out.append(.shape(shape))
            }
            out.append(.moved(x: Int(position.x), y: Int(position.y)))
            return out
        case let .move(p): return [.moved(x: Int(p.x), y: Int(p.y))]
        case .hide: return [.shape(nil)]
        case .reset: cache.removeAll(); return [.shape(nil)]
        case let .invalOne(id): cache[id] = nil; return []
        case .invalAll: cache.removeAll(); return []
        case .trail, .other: return []
        }
    }

    /// nil when there is nothing to show yet: flags NONE, a cache miss, or a shape we cannot decode.
    private mutating func resolve(_ c: SpiceCursor) -> CursorShape? {
        guard let header = c.header else { return nil }
        if c.flags & CursorFlags.fromCache != 0 { return cache[header.unique] }
        do {
            let shape = try CursorDecoder.decode(header, data: c.data)
            if c.flags & CursorFlags.cacheMe != 0 { cache[header.unique] = shape }
            return shape
        } catch {
            Self.log.error("cursor: \(String(describing: error))")
            return nil
        }
    }
}
```

`os.Logger` is `Sendable`; a `static let` on a `Sendable` struct is fine under strict concurrency.

- [ ] **Step 7: Run**

Run: `swift test --filter SpiceCanvasTests`
Expected: all pass, including 3 `CursorTrackerTests`.

- [ ] **Step 8: Commit**

```bash
git add Sources/SpiceCanvas/CursorShape.swift Sources/SpiceCanvas/CursorTracker.swift \
        Tests/SpiceCanvasTests/CursorDecoderTests.swift Tests/SpiceCanvasTests/CursorTrackerTests.swift
git commit -m "feat(canvas): cursor shape decoding, cache and tracker"
```

---

### Task 7: KeyMap, WheelAccumulator, ViewportTransform

Three pure pieces of `SpiceKit`, each tested. `KeyMap` is the spec's static table; `WheelAccumulator` is the "one click per N units" rule; `ViewportTransform` is the fit/1:1 geometry that the Metal present, the mouse mapping and the cursor overlay must all agree on.

**Files:**
- Create: `Sources/SpiceKit/KeyMap.swift`, `Sources/SpiceKit/WheelAccumulator.swift`, `Sources/SpiceKit/ViewportTransform.swift`
- Test: `Tests/SpiceKitTests/KeyMapTests.swift`, `Tests/SpiceKitTests/WheelAccumulatorTests.swift`, `Tests/SpiceKitTests/ViewportTransformTests.swift`

**Interfaces:**
- Consumes: `XTScancode` (Task 1).
- Produces: `ModifierTarget` (`.super .ctrl .alt`), `KeyMap.scancode(keyCode:commandMapsTo:optionMapsTo:) -> XTScancode?`, `KeyMap.capsLockKeyCode: UInt16 = 0x39`, `KeyMap.isModifierKeyCode(_:)`, `XTScancode.leftControl/.leftAlt/.delete`; `WheelAccumulator` (`mutating func add(precise: Bool, delta: Double) -> Int`); `ViewportTransform(viewSize:surfaceSize:scaling:)` with `.fit/.oneToOne`, `scale`, `origin`, `guestPoint(fromView:)`, `viewRect(forGuest:)`.

- [ ] **Step 1: Write the failing KeyMap tests**

```swift
// Tests/SpiceKitTests/KeyMapTests.swift
import Testing
import SpiceWire
@testable import SpiceKit

@Test func lettersDigitsAndNavigation() {
    #expect(KeyMap.scancode(keyCode: 0x00) == XTScancode(0x1E))                     // A
    #expect(KeyMap.scancode(keyCode: 0x12) == XTScancode(0x02))                     // 1
    #expect(KeyMap.scancode(keyCode: 0x24) == XTScancode(0x1C))                     // Return
    #expect(KeyMap.scancode(keyCode: 0x35) == XTScancode(0x01))                     // Escape
    #expect(KeyMap.scancode(keyCode: 0x75) == XTScancode(0x53, extended: true))     // Forward delete
    #expect(KeyMap.scancode(keyCode: 0x7B) == XTScancode(0x4B, extended: true))     // Left
    #expect(KeyMap.scancode(keyCode: 0x4C) == XTScancode(0x1C, extended: true))     // Keypad enter
    #expect(KeyMap.scancode(keyCode: 0x7A) == XTScancode(0x3B))                     // F1
    #expect(KeyMap.scancode(keyCode: 0x6F) == XTScancode(0x58))                     // F12
    #expect(KeyMap.scancode(keyCode: 0x0A) == XTScancode(0x56))                     // ISO § key = 102nd key
}

@Test func modifierMappingIsPositionalAndSwappable() {
    #expect(KeyMap.scancode(keyCode: 0x37) == XTScancode(0x5B, extended: true))     // ⌘ → Super (default)
    #expect(KeyMap.scancode(keyCode: 0x36) == XTScancode(0x5C, extended: true))     // right ⌘ → right Super
    #expect(KeyMap.scancode(keyCode: 0x3A) == XTScancode(0x38))                     // ⌥ → Alt (default)
    #expect(KeyMap.scancode(keyCode: 0x3D) == XTScancode(0x38, extended: true))     // right ⌥ → right Alt
    #expect(KeyMap.scancode(keyCode: 0x37, commandMapsTo: .ctrl) == XTScancode(0x1D))
    #expect(KeyMap.scancode(keyCode: 0x36, commandMapsTo: .alt) == XTScancode(0x38, extended: true))
    #expect(KeyMap.scancode(keyCode: 0x3A, optionMapsTo: .super) == XTScancode(0x5B, extended: true))
    #expect(KeyMap.scancode(keyCode: 0x3B) == XTScancode(0x1D))                     // ⌃ always Ctrl
    #expect(KeyMap.scancode(keyCode: 0x3E) == XTScancode(0x1D, extended: true))
    #expect(KeyMap.scancode(keyCode: 0x38) == XTScancode(0x2A) && KeyMap.scancode(keyCode: 0x3C) == XTScancode(0x36))
}

@Test func keysWithNoGuestEquivalentReturnNil() {
    #expect(KeyMap.scancode(keyCode: 0x39) == nil)   // caps lock: synced via KEY_MODIFIERS, never as a scancode
    #expect(KeyMap.scancode(keyCode: 0x3F) == nil)   // fn
    #expect(KeyMap.scancode(keyCode: 0xFF) == nil)
}

@Test func tableHasNoDuplicateTargets() {
    // Two physical keys must not drive the same guest key; the modifiers are mapped by preference and excluded.
    var seen: Set<XTScancode> = []
    for code in UInt16(0) ... 0x7F where !KeyMap.isModifierKeyCode(code) {
        guard let s = KeyMap.scancode(keyCode: code) else { continue }
        #expect(seen.insert(s).inserted, "keyCode \(code) duplicates \(s)")
    }
    #expect(seen.count >= 100)
}

@Test func namedScancodes() {
    #expect(XTScancode.leftControl == XTScancode(0x1D) && XTScancode.leftAlt == XTScancode(0x38) && XTScancode.delete == XTScancode(0x53, extended: true))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter KeyMapTests`
Expected: compile error.

- [ ] **Step 3: Implement KeyMap**

```swift
// Sources/SpiceKit/KeyMap.swift
import SpiceWire

/// What a host modifier key drives in the guest (spec §6: "Cmd->Super, Option->Alt, swappable").
public enum ModifierTarget: Sendable, Equatable { case `super`, ctrl, alt }

extension XTScancode {
    public static let leftControl = XTScancode(0x1D)
    public static let rightControl = XTScancode(0x1D, extended: true)
    public static let leftAlt = XTScancode(0x38)
    public static let rightAlt = XTScancode(0x38, extended: true)
    public static let leftSuper = XTScancode(0x5B, extended: true)
    public static let rightSuper = XTScancode(0x5C, extended: true)
    public static let delete = XTScancode(0x53, extended: true)
}

/// macOS virtual key codes (Carbon `kVK_*`, written numerically so this module never imports
/// Carbon) → XT set-1 scancodes. Positional: the key at the physical "A" position sends 0x1E on
/// every layout, which is what a guest keymap expects.
public enum KeyMap {
    public static let capsLockKeyCode: UInt16 = 0x39
    private static let leftCommand: UInt16 = 0x37, rightCommand: UInt16 = 0x36
    private static let leftOption: UInt16 = 0x3A, rightOption: UInt16 = 0x3D
    private static let function: UInt16 = 0x3F

    public static func isModifierKeyCode(_ k: UInt16) -> Bool {
        [leftCommand, rightCommand, leftOption, rightOption, capsLockKeyCode, function, 0x38, 0x3C, 0x3B, 0x3E].contains(k)
    }

    public static func scancode(keyCode: UInt16, commandMapsTo: ModifierTarget = .super, optionMapsTo: ModifierTarget = .alt) -> XTScancode? {
        switch keyCode {
        case leftCommand: return target(commandMapsTo, right: false)
        case rightCommand: return target(commandMapsTo, right: true)
        case leftOption: return target(optionMapsTo, right: false)
        case rightOption: return target(optionMapsTo, right: true)
        case capsLockKeyCode, function: return nil
        default: return table[keyCode]
        }
    }

    private static func target(_ t: ModifierTarget, right: Bool) -> XTScancode {
        switch t {
        case .super: right ? .rightSuper : .leftSuper
        case .ctrl: right ? .rightControl : .leftControl
        case .alt: right ? .rightAlt : .leftAlt
        }
    }

    private static func x(_ c: UInt8) -> XTScancode { XTScancode(c, extended: true) }

    private static let table: [UInt16: XTScancode] = [
        // Letters
        0x00: XTScancode(0x1E), 0x0B: XTScancode(0x30), 0x08: XTScancode(0x2E), 0x02: XTScancode(0x20), 0x0E: XTScancode(0x12),
        0x03: XTScancode(0x21), 0x05: XTScancode(0x22), 0x04: XTScancode(0x23), 0x22: XTScancode(0x17), 0x26: XTScancode(0x24),
        0x28: XTScancode(0x25), 0x25: XTScancode(0x26), 0x2E: XTScancode(0x32), 0x2D: XTScancode(0x31), 0x1F: XTScancode(0x18),
        0x23: XTScancode(0x19), 0x0C: XTScancode(0x10), 0x0F: XTScancode(0x13), 0x01: XTScancode(0x1F), 0x11: XTScancode(0x14),
        0x20: XTScancode(0x16), 0x09: XTScancode(0x2F), 0x0D: XTScancode(0x11), 0x07: XTScancode(0x2D), 0x10: XTScancode(0x15),
        0x06: XTScancode(0x2C),
        // Digit row
        0x12: XTScancode(0x02), 0x13: XTScancode(0x03), 0x14: XTScancode(0x04), 0x15: XTScancode(0x05), 0x17: XTScancode(0x06),
        0x16: XTScancode(0x07), 0x1A: XTScancode(0x08), 0x1C: XTScancode(0x09), 0x19: XTScancode(0x0A), 0x1D: XTScancode(0x0B),
        0x1B: XTScancode(0x0C), 0x18: XTScancode(0x0D),
        // Punctuation and whitespace
        0x21: XTScancode(0x1A), 0x1E: XTScancode(0x1B), 0x2A: XTScancode(0x2B), 0x29: XTScancode(0x27), 0x27: XTScancode(0x28),
        0x32: XTScancode(0x29), 0x2B: XTScancode(0x33), 0x2F: XTScancode(0x34), 0x2C: XTScancode(0x35), 0x0A: XTScancode(0x56),
        0x24: XTScancode(0x1C), 0x30: XTScancode(0x0F), 0x31: XTScancode(0x39), 0x33: XTScancode(0x0E), 0x35: XTScancode(0x01),
        // Fixed modifiers (⌘/⌥ are mapped by preference above)
        0x38: XTScancode(0x2A), 0x3C: XTScancode(0x36), 0x3B: XTScancode(0x1D), 0x3E: x(0x1D),
        // Function keys
        0x7A: XTScancode(0x3B), 0x78: XTScancode(0x3C), 0x63: XTScancode(0x3D), 0x76: XTScancode(0x3E), 0x60: XTScancode(0x3F),
        0x61: XTScancode(0x40), 0x62: XTScancode(0x41), 0x64: XTScancode(0x42), 0x65: XTScancode(0x43), 0x6D: XTScancode(0x44),
        0x67: XTScancode(0x57), 0x6F: XTScancode(0x58), 0x69: XTScancode(0x64), 0x6B: XTScancode(0x65), 0x71: XTScancode(0x66),
        0x6A: XTScancode(0x67), 0x40: XTScancode(0x68), 0x4F: XTScancode(0x69), 0x50: XTScancode(0x6A), 0x5A: XTScancode(0x6B),
        // Navigation (extended)
        0x72: x(0x52), 0x73: x(0x47), 0x74: x(0x49), 0x75: x(0x53), 0x77: x(0x4F), 0x79: x(0x51),
        0x7B: x(0x4B), 0x7C: x(0x4D), 0x7D: x(0x50), 0x7E: x(0x48), 0x6E: x(0x5D),
        // Keypad
        0x52: XTScancode(0x52), 0x53: XTScancode(0x4F), 0x54: XTScancode(0x50), 0x55: XTScancode(0x51), 0x56: XTScancode(0x4B),
        0x57: XTScancode(0x4C), 0x58: XTScancode(0x4D), 0x59: XTScancode(0x47), 0x5B: XTScancode(0x48), 0x5C: XTScancode(0x49),
        0x41: XTScancode(0x53), 0x43: XTScancode(0x37), 0x45: XTScancode(0x4E), 0x4E: XTScancode(0x4A), 0x47: XTScancode(0x45),
        0x4B: x(0x35), 0x4C: x(0x1C), 0x51: XTScancode(0x59),
        // Media (extended)
        0x48: x(0x30), 0x49: x(0x2E), 0x4A: x(0x20),
        // JIS
        0x5D: XTScancode(0x7D), 0x5E: XTScancode(0x73), 0x5F: XTScancode(0x7E), 0x66: XTScancode(0x7B), 0x68: XTScancode(0x70),
    ]
}
```

- [ ] **Step 4: Run the KeyMap tests**

Run: `swift test --filter KeyMapTests`
Expected: 5 pass. If `tableHasNoDuplicateTargets` fails, the message names the colliding key codes — fix the table entry, do not weaken the test.

- [ ] **Step 5: Write the failing WheelAccumulator tests**

```swift
// Tests/SpiceKitTests/WheelAccumulatorTests.swift
import Testing
@testable import SpiceKit

@Test func wheelLinesEmitAtLeastOneClickPerEvent() {
    var w = WheelAccumulator()
    #expect(w.add(precise: false, delta: 0.1) == 1)
    #expect(w.add(precise: false, delta: -2.6) == -3)
    #expect(w.add(precise: false, delta: 0) == 0)
}

@Test func trackpadDeltasAccumulateToOneClickPerTenUnits() {
    var w = WheelAccumulator()
    #expect(w.add(precise: true, delta: 4) == 0)
    #expect(w.add(precise: true, delta: 4) == 0)
    #expect(w.add(precise: true, delta: 4) == 1)         // 12 → one click, 2 carried
    #expect(w.add(precise: true, delta: -12) == -1)      // 2 - 12 = -10 → one click down, 0 carried
    #expect(w.add(precise: true, delta: 25) == 2)
}
```

- [ ] **Step 6: Implement WheelAccumulator**

```swift
// Sources/SpiceKit/WheelAccumulator.swift
/// Mouse wheels report whole lines; trackpads report pixels. Both become SPICE wheel clicks:
/// a wheel event is at least one click, a trackpad emits one click per `unitsPerClick` points.
public struct WheelAccumulator: Sendable {
    public static let unitsPerClick = 10.0
    private var carry = 0.0
    public init() {}

    /// Positive = up (SPICE button 4), negative = down (button 5).
    public mutating func add(precise: Bool, delta: Double) -> Int {
        guard delta != 0 else { return 0 }
        if !precise {
            let clicks = Int(delta.rounded(.awayFromZero))
            return clicks == 0 ? (delta > 0 ? 1 : -1) : clicks
        }
        carry += delta
        let clicks = Int((carry / Self.unitsPerClick).rounded(.towardZero))
        carry -= Double(clicks) * Self.unitsPerClick
        return clicks
    }
}
```

- [ ] **Step 7: Write the failing ViewportTransform tests**

```swift
// Tests/SpiceKitTests/ViewportTransformTests.swift
import Testing
@testable import SpiceKit

@Test func fitLetterboxesAndMapsBothWays() {
    // 800×600 view, 1600×600 surface → scale 0.5, surface 800×300 centred vertically (origin y = 150).
    let t = ViewportTransform(viewSize: .init(width: 800, height: 600), surfaceSize: .init(width: 1600, height: 600), scaling: .fit)
    #expect(t.scale == 0.5 && t.origin == .init(x: 0, y: 150))
    #expect(t.guestPoint(fromView: .init(x: 400, y: 300)) == .init(x: 800, y: 300))
    #expect(t.guestPoint(fromView: .init(x: 0, y: 0)) == .init(x: 0, y: 0))          // clamped into the surface
    #expect(t.guestPoint(fromView: .init(x: 799.9, y: 599)) == .init(x: 1599, y: 599))
    #expect(t.viewRect(forGuest: .init(x: 100, y: 50, width: 32, height: 32)) == .init(x: 50, y: 175, width: 16, height: 16))
}

@Test func oneToOneCentresAndClips() {
    let t = ViewportTransform(viewSize: .init(width: 400, height: 400), surfaceSize: .init(width: 800, height: 200), scaling: .oneToOne)
    #expect(t.scale == 1 && t.origin == .init(x: -200, y: 100))
    #expect(t.guestPoint(fromView: .init(x: 0, y: 100)) == .init(x: 200, y: 0))
}

@Test func degenerateSizesDoNotDivideByZero() {
    let t = ViewportTransform(viewSize: .zero, surfaceSize: .init(width: 10, height: 10), scaling: .fit)
    #expect(t.scale == 1)
    #expect(t.guestPoint(fromView: .zero) == .init(x: 0, y: 0))
}
```

- [ ] **Step 8: Implement ViewportTransform**

```swift
// Sources/SpiceKit/ViewportTransform.swift
import CoreGraphics

public enum ViewportScaling: Sendable, Equatable { case fit, oneToOne }

public struct GuestPoint: Sendable, Equatable {
    public var x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// Where the guest surface sits inside a view, in view points with a top-left origin. Metal present,
/// the mouse mapping and the cursor overlay all derive from the same instance, so they cannot drift.
public struct ViewportTransform: Sendable, Equatable {
    public let scale: CGFloat
    public let origin: CGPoint
    public let surfaceSize: CGSize

    public init(viewSize: CGSize, surfaceSize: CGSize, scaling: ViewportScaling) {
        self.surfaceSize = surfaceSize
        guard viewSize.width > 0, viewSize.height > 0, surfaceSize.width > 0, surfaceSize.height > 0 else {
            scale = 1; origin = .zero; return
        }
        scale = scaling == .fit ? min(viewSize.width / surfaceSize.width, viewSize.height / surfaceSize.height) : 1
        origin = CGPoint(x: (viewSize.width - surfaceSize.width * scale) / 2,
                         y: (viewSize.height - surfaceSize.height * scale) / 2)
    }

    /// Guest pixel under a view point, clamped to the surface so dragging past the edge keeps working.
    public func guestPoint(fromView p: CGPoint) -> GuestPoint {
        let gx = ((p.x - origin.x) / scale).rounded(.down), gy = ((p.y - origin.y) / scale).rounded(.down)
        return GuestPoint(x: Int(min(max(gx, 0), surfaceSize.width - 1)), y: Int(min(max(gy, 0), surfaceSize.height - 1)))
    }

    public func viewRect(forGuest r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.origin.x * scale, y: origin.y + r.origin.y * scale, width: r.width * scale, height: r.height * scale)
    }
}
```

- [ ] **Step 9: Run all three**

Run: `swift test --filter "KeyMapTests|WheelAccumulatorTests|ViewportTransformTests"`
Expected: 10 pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/SpiceKit/KeyMap.swift Sources/SpiceKit/WheelAccumulator.swift Sources/SpiceKit/ViewportTransform.swift Tests/SpiceKitTests/KeyMapTests.swift Tests/SpiceKitTests/WheelAccumulatorTests.swift Tests/SpiceKitTests/ViewportTransformTests.swift
git commit -m "feat(kit): kVK→XT key map, wheel accumulator, viewport transform"
```

---
### Task 8: SpiceSession — inputs, cursor, ordered `send`, mouse-mode negotiation

**Files:**
- Modify: `Sources/SpiceKit/SpiceSession.swift`
- Modify: `Tests/SpiceKitTests/SpiceSessionTests.swift` (feed the new fixtures)
- Test: `Tests/SpiceKitTests/SessionInputTests.swift`

**Interfaces:**
- Consumes: `InputsChannel` (Task 4), `CursorChannel` (Task 5), `CursorTracker`/`CursorChange` (Task 6), `MainChannel.requestMouseMode(_:)`, `MainMessage.mouseMode/.agentConnected/.agentDisconnected`, `SpiceMouseMode`.
- Produces: `PointerMode` (`.server .client`), `GuestInput`, `SessionEvent.pointerMode(PointerMode)`, `.cursor(CursorChange, displayID: UInt8)`, `.agent(connected: Bool)`, `SpiceSession.send(_ input: GuestInput)` (nonisolated, ordered, never blocks), `SpiceSession.pointerMode`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SpiceKitTests/SessionInputTests.swift
import Foundation
import Testing
import SpiceWire
import SpiceCore
@testable import SpiceKit

private func fixture(_ name: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))))
}

/// A main channel whose MAIN_INIT advertises `supported` mouse modes and is `current`ly in one of them.
private func mainBytes(supported: UInt32, current: UInt32) throws -> [UInt8] {
    var mi = SpiceWriter(); [1, 1, supported, current, 0, 10, 0, 0].forEach { mi.u32($0) }
    var cl = SpiceWriter(); cl.u32(3); cl.u8(2); cl.u8(0); cl.u8(3); cl.u8(0); cl.u8(4); cl.u8(0)   // display/0 inputs/0 cursor/0
    return try fakeLink(body: frame(MainServerMsg.`init`.rawValue, mi.bytes) + frame(MainServerMsg.channelsList.rawValue, cl.bytes))
}

private func clientFrames(_ t: InMemoryTransport) async throws -> [(type: UInt16, payload: [UInt8])] {
    var r = SpiceReader(await t.written)
    try r.skip(12); let n = Int(try r.u32()); try r.skip(n); try r.skip(4 + Link.ticketBytes)
    var out: [(UInt16, [UInt8])] = []
    while r.remaining >= DataHeader.miniSize { let h = try DataHeader(mini: &r); out.append((h.type, try r.bytes(Int(h.size)))) }
    return out
}

/// Polls until the transport has `count` client frames of `type`, so tests do not race the input pump.
private func waitForFrames(_ t: InMemoryTransport, type: UInt16, count: Int) async throws -> [[UInt8]] {
    for _ in 0 ..< 100 {
        let f = try await clientFrames(t).filter { $0.type == type }.map(\.payload)
        if f.count >= count { return f }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await clientFrames(t).filter { $0.type == type }.map(\.payload)
}

@Test func requestsClientModeWhenSupported() async throws {
    let main = InMemoryTransport(input: try mainBytes(supported: 3, current: SpiceMouseMode.server))
    let inputs = InMemoryTransport(input: try fakeLink(body: frame(InputsServerMsg.`init`.rawValue, [0, 0])))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return main
        case .inputs: return inputs
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    let req = try await waitForFrames(main, type: MainClientMsg.mouseModeRequest.rawValue, count: 1)
    #expect(req == [ClientMessage.mouseModeRequest(SpiceMouseMode.client)])
    var modes: [PointerMode] = []
    for await e in session.events { if case let .pointerMode(m) = e { modes.append(m) }; if case .disconnected = e { break } }
    #expect(modes.first == .server)
}

@Test func doesNotRequestClientModeWhenUnsupported() async throws {
    let main = InMemoryTransport(input: try mainBytes(supported: 1, current: SpiceMouseMode.server))
    let session = try await SpiceSession.connect(password: nil) { desc in
        desc.type == .main ? main : InMemoryTransport(input: try fakeLink(body: []))
    }
    for await e in session.events { if case .disconnected = e { break } }
    let req = try await clientFrames(main).filter { $0.type == MainClientMsg.mouseModeRequest.rawValue }
    #expect(req.isEmpty)
}

@Test func sendPreservesOrderAndEncoding() async throws {
    let inputs = InMemoryTransport(input: try fakeLink(body: frame(InputsServerMsg.`init`.rawValue, [2, 0])))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return InMemoryTransport(input: try mainBytes(supported: 1, current: 1))
        case .inputs: return inputs
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    try await Task.sleep(for: .milliseconds(50))     // let INPUTS_INIT (num lock) land before the caps-lock sync reads it
    let a = XTScancode(0x1E)
    session.send(.keyDown(a)); session.send(.keyUp(a))
    session.send(.buttonDown(.left)); session.send(.pointerMotion(dx: 3, dy: -4)); session.send(.buttonUp(.left))
    session.send(.wheel(clicks: -1))
    session.send(.hostCapsLock(true))
    session.send(.pointerPosition(x: 10, y: 20, displayID: 0))
    let all = try await waitForFrames(inputs, type: InputsClientMsg.mousePosition.rawValue, count: 1)
    #expect(all.last == ClientMessage.mousePosition(x: 10, y: 20, buttons: [], displayID: 0))
    let frames = try await clientFrames(inputs).filter { $0.type > 100 }
    #expect(frames.map(\.payload) == [
        ClientMessage.keyDown(a), ClientMessage.keyUp(a),
        ClientMessage.mousePress(.left, buttons: [.left]),
        ClientMessage.mouseMotion(dx: 3, dy: -4, buttons: [.left]),
        ClientMessage.mouseRelease(.left, buttons: []),
        ClientMessage.mousePress(.down, buttons: []), ClientMessage.mouseRelease(.down, buttons: []),
        ClientMessage.keyModifiers([.numLock, .capsLock]),
        ClientMessage.mousePosition(x: 10, y: 20, buttons: [], displayID: 0),
    ])
    await session.disconnect()
}

@Test func cursorChangesCarryTheirDisplay() async throws {
    var set = SpiceWriter(); set.u16(4); set.u16(5); set.u8(1); set.u16(CursorFlags.none)
    let cursor = InMemoryTransport(input: try fakeLink(body: frame(CursorServerMsg.set.rawValue, set.bytes)))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return InMemoryTransport(input: try mainBytes(supported: 1, current: 1))
        case .cursor: return cursor
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    var moved: [(Int, Int, UInt8)] = []
    for await e in session.events {
        if case let .cursor(.moved(x, y), id) = e { moved.append((x, y, id)) }
        if case .disconnected = e { break }
    }
    #expect(moved.count == 1 && moved.first?.0 == 4 && moved.first?.1 == 5 && moved.first?.2 == 0)
}
```

`fakeLink`/`frame` live in `SpiceCoreTests`; `SpiceKitTests` cannot see them. Move both helpers to a new `Tests/TestSupport/` is not possible without a target, so **copy** them into `Tests/SpiceKitTests/TestSupport.swift` (same code, `import SpiceCore` non-testable — `Ticket.wrapSPKI` is internal, so mark it `public` in `Sources/SpiceCore/Ticket.swift`; one-word change).

Also update `Tests/SpiceKitTests/SpiceSessionTests.swift`'s transport factory so the recorded session brings up all four channels:

```swift
        case .main: return InMemoryTransport(input: main)
        case .display: return InMemoryTransport(input: display)
        case .inputs: return InMemoryTransport(input: try fixture("win-inputs.s2c"))
        case .cursor: return InMemoryTransport(input: try fixture("win-cursor.s2c"))
        default: throw SpiceError(.unsupported("not in M2"), channel: desc)
```

(`win-inputs.s2c.bin` was recorded from a `remote-viewer` link with common caps `0xd`; our link reads the *server's* reply from the file, which is what `fakeLink` also mimics, so the recording replays under `miniHeader: true` exactly as the display fixture does.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SessionInputTests`
Expected: compile error — `GuestInput`, `PointerMode`, `send` missing.

- [ ] **Step 3: Implement**

Replace `Sources/SpiceKit/SpiceSession.swift` with:

```swift
import os
import SpiceCanvas
import SpiceCore
import SpiceWire

public struct ConnectionConfig: Sendable {
    public var host: String, port: UInt16, password: String?
    public init(host: String, port: UInt16, password: String?) { self.host = host; self.port = port; self.password = password }
}

public enum PointerMode: Sendable, Equatable { case server, client }

/// Host input in guest terms. The app translates key codes with `KeyMap` before calling `send`.
public enum GuestInput: Sendable, Equatable {
    case keyDown(XTScancode), keyUp(XTScancode), releaseAllKeys
    case hostCapsLock(Bool)
    case pointerPosition(x: UInt32, y: UInt32, displayID: UInt8)
    case pointerMotion(dx: Int32, dy: Int32)
    case buttonDown(MouseButton), buttonUp(MouseButton)
    /// Positive = up (button 4), negative = down (button 5); one press/release pair per click.
    case wheel(clicks: Int)
}

public enum SessionEvent: Sendable {
    case connected(SessionInfo)
    case canvas(CanvasEvent)
    case pointerMode(PointerMode)
    case cursor(CursorChange, displayID: UInt8)
    case agent(connected: Bool)
    case channelFailed(ChannelDescriptor, SpiceError)
    case disconnected(SpiceError?)
}

public actor SpiceSession {
    public typealias TransportFactory = @Sendable (ChannelDescriptor) async throws -> any Transport

    public nonisolated let info: SessionInfo
    public nonisolated let events: AsyncStream<SessionEvent>
    private let cont: AsyncStream<SessionEvent>.Continuation
    private let inputStream: AsyncStream<GuestInput>
    private let inputCont: AsyncStream<GuestInput>.Continuation
    private let main: MainChannel
    private let canvas = Canvas()
    private var displays: [DisplayChannel] = []
    private var cursors: [CursorChannel] = []
    private var inputs: InputsChannel?
    private var tasks: [Task<Void, Never>] = []
    public private(set) var pointerMode: PointerMode
    private let log = Logger(subsystem: "com.spicesee", category: "session")

    public static func connect(_ config: ConnectionConfig) async throws -> SpiceSession {
        try await connect(password: config.password) { _ in try await NWTransport.connect(host: config.host, port: config.port) }
    }

    public static func connect(password: String?, transports: @escaping TransportFactory) async throws -> SpiceSession {
        let mainTransport = try await transports(MainChannel.descriptor)
        let main = try await MainChannel.open(transport: mainTransport, password: password)
        let session = SpiceSession(main: main, info: await main.info)
        await session.start(password: password, transports: transports)
        return session
    }

    private init(main: MainChannel, info: SessionInfo) {
        self.main = main
        self.info = info
        pointerMode = info.mainInit.currentMouseMode == SpiceMouseMode.client ? .client : .server
        (events, cont) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        (inputStream, inputCont) = AsyncStream.makeStream(of: GuestInput.self, bufferingPolicy: .unbounded)
    }

    /// Queues host input for the guest. Synchronous and ordered: an `AsyncStream` continuation is
    /// the FIFO, so a key-up can never overtake its key-down the way independent `Task`s could.
    /// Input sent before the inputs channel is up, or after it failed, is dropped.
    public nonisolated func send(_ input: GuestInput) { inputCont.yield(input) }

    private func start(password: String?, transports: @escaping TransportFactory) async {
        cont.yield(.connected(info))
        cont.yield(.pointerMode(pointerMode))
        let canvasPump = Task { [canvas, cont] in for await e in canvas.events { cont.yield(.canvas(e)) } }
        tasks.append(canvasPump)

        var displayPumps: [Task<Void, Never>] = []
        var cursorPumps: [Task<Void, Never>] = []
        for desc in info.channels {
            do {
                switch desc.type {
                case .display:
                    let d = try await DisplayChannel.open(transport: try await transports(desc), connectionID: info.connectionID, id: desc.id, password: password)
                    displays.append(d)
                    let pump = Task { [canvas] in for await m in d.messages { await canvas.apply(m) } }
                    displayPumps.append(pump); tasks.append(pump)
                case .cursor:
                    let c = try await CursorChannel.open(transport: try await transports(desc), connectionID: info.connectionID, id: desc.id, password: password)
                    cursors.append(c)
                    let pump = Task { [cont] in
                        var tracker = CursorTracker()
                        for await m in c.messages { for change in tracker.apply(m) { cont.yield(.cursor(change, displayID: desc.id)) } }
                    }
                    cursorPumps.append(pump); tasks.append(pump)
                case .inputs where desc.id == 0:
                    inputs = try await InputsChannel.open(transport: try await transports(desc), connectionID: info.connectionID, password: password)
                default:
                    continue
                }
            } catch let e as SpiceError {
                cont.yield(.channelFailed(desc, e))
            } catch {
                cont.yield(.channelFailed(desc, SpiceError(.connect, channel: desc, underlying: String(describing: error))))
            }
        }

        if let inputs {
            let stream = inputStream
            tasks.append(Task { [weak self] in
                for await e in stream {
                    guard let self else { return }
                    do { try await self.dispatch(e, to: inputs) }
                    catch { await self.log.error("inputs send failed: \(String(describing: error))"); return }
                }
            })
        }

        await negotiateMouseMode(supported: info.mainInit.supportedMouseModes)

        // `.disconnected` must come after every pixel and every cursor change. Main ending only means
        // the connection is gone; the other channels may still hold buffered messages. Drain, then close.
        tasks.append(Task { [weak self, main, canvas, cont] in
            for await m in main.events { await self?.handleMain(m) }
            for pump in displayPumps { _ = await pump.value }
            for pump in cursorPumps { _ = await pump.value }
            await canvas.finish()
            _ = await canvasPump.value
            cont.yield(.disconnected(nil))
        })
    }

    private func handleMain(_ m: MainMessage) async {
        switch m {
        case let .mouseMode(mode):
            let next: PointerMode = mode.current == SpiceMouseMode.client ? .client : .server
            if next != pointerMode { pointerMode = next; cont.yield(.pointerMode(next)) }
            await negotiateMouseMode(supported: mode.supported)
        case .agentConnected, .agentConnectedTokens: cont.yield(.agent(connected: true))
        case .agentDisconnected: cont.yield(.agent(connected: false))
        default: break
        }
    }

    /// Absolute positioning is what the user wants whenever the server can do it (agent or tablet);
    /// the server answers with MAIN_MOUSE_MODE, which `handleMain` turns into `.pointerMode`.
    private func negotiateMouseMode(supported: UInt32) async {
        guard supported & SpiceMouseMode.client != 0, pointerMode != .client else { return }
        do { try await main.requestMouseMode(SpiceMouseMode.client) }
        catch { log.error("mouse mode request failed: \(String(describing: error))") }
    }

    private func dispatch(_ e: GuestInput, to ch: InputsChannel) async throws {
        switch e {
        case let .keyDown(s): try await ch.keyDown(s)
        case let .keyUp(s): try await ch.keyUp(s)
        case .releaseAllKeys: try await ch.releaseAllKeys()
        case let .hostCapsLock(on): try await ch.syncCapsLock(on)
        case let .pointerPosition(x, y, id): try await ch.mousePosition(x: x, y: y, displayID: id)
        case let .pointerMotion(dx, dy): try await ch.mouseMotion(dx: dx, dy: dy)
        case let .buttonDown(b): try await ch.buttonDown(b)
        case let .buttonUp(b): try await ch.buttonUp(b)
        case let .wheel(clicks):
            let button: MouseButton = clicks > 0 ? .up : .down
            for _ in 0 ..< abs(clicks) { try await ch.buttonDown(button); try await ch.buttonUp(button) }
        }
    }

    public func snapshotPrimary() async -> DecodedImage? {
        guard let id = await canvas.primarySurfaceID else { return nil }
        return await canvas.snapshot(surfaceID: id)
    }

    public func disconnect() {
        tasks.forEach { $0.cancel() }
        inputCont.finish()
        displays.forEach { d in Task { await d.close() } }
        cursors.forEach { c in Task { await c.close() } }
        if let inputs { Task { await inputs.close() } }
        Task { [main] in await main.close() }
        cont.yield(.disconnected(nil)); cont.finish()
    }
}
```

`.agentConnectedTokens` is how a current spice-server announces the agent (it carries the token count); treating it like `.agentConnected` is deliberate.

- [ ] **Step 4: Run the kit tests**

Run: `swift test --filter SpiceKitTests`
Expected: all pass — the four new tests, `sessionBringsUpMainAndDisplayFromRecordings` with four channels, the replay golden unchanged. If `doesNotRequestClientModeWhenUnsupported` hangs, the drain task is waiting on a channel whose transport threw before `open` — confirm the `catch` runs before the pumps are appended (it does in the code above) and that `main`'s recording ends (EOF ends `ChannelReader.run`).

- [ ] **Step 5: Live check with the CLI**

`spicesee-cli dump` still works unchanged, and now brings up inputs and cursor too:

```bash
swift run spicesee-cli dump 192.168.50.6 5930 3 /tmp/m2.png
```

Expected: `connected: 10 channels`, a PNG of the installer, no `channelFailed` logged (`log stream --predicate 'subsystem == "com.spicesee"' --level info` in another terminal).

- [ ] **Step 6: Commit**

```bash
git add Sources/SpiceKit/SpiceSession.swift Sources/SpiceCore/Ticket.swift Tests/SpiceKitTests/TestSupport.swift \
        Tests/SpiceKitTests/SessionInputTests.swift Tests/SpiceKitTests/SpiceSessionTests.swift
git commit -m "feat(kit): SpiceSession drives inputs and cursor channels; ordered send; mouse-mode negotiation"
```

---
### Task 9: The seam — `sendInput`, pointer mode and cursor events through backend, model and mock

No views change in this task. It extends the protocol, teaches both backends the new events, and makes `SessionModel.pointerCaptured` honest (the engine says which mode we are in; the input view, in Task 11, says whether it captured).

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift`, `Sources/SpiceSee/SpiceKitBackend.swift`, `Sources/SpiceSee/MockSessionBackend.swift`, `Sources/SpiceSee/SessionModel.swift`, `Sources/SpiceSee/MetalSurfaceView.swift` (the `Coordinator.pump` signature only), `Sources/SpiceSee/SpiceSeeApp.swift` (lock-key setting plumbing)

**Interfaces:**
- Consumes: `SpiceSession.send`, `GuestInput`, `PointerMode`, `CursorChange`, `CursorShape`, `KeyMap`, `ModifierTarget` (Tasks 6–8); app `GuestModifier`, `AgentState`.
- Produces (app side, `SessionBackend.swift`): `PointerMode` (`.client .server`), `PointerButton` (`.left .middle .right`), `KeyboardMapping(commandMapsTo:optionMapsTo:)`, `InputEvent`, `CursorImage`, `CursorChange` (`.shape(CursorImage?)`, `.moved(x:y:)`), `ViewportEvent` (`.frame(FrameUpdate)`, `.cursor(CursorChange)`), `BackendEvent.pointerMode(PointerMode)`, `BackendEvent.cursor(viewportID: Int, CursorChange)`, `SessionBackend.sendInput(_:)` (synchronous). `SessionModel`: `pointerMode`, `keyboardMapping`, `sendLockKeys`, `sendInput(_:)`, `setPointerCaptured(_:)`, `viewportEvents(for:)`.

- [ ] **Step 1: Extend the seam**

In `Sources/SpiceSee/SessionBackend.swift`, add below `FrameUpdate`:

```swift
/// Which side owns the pointer position. Client = absolute (`MOUSE_POSITION`, host cursor shows
/// the guest's shape); server = relative (`MOUSE_MOTION`, pointer captured while working).
enum PointerMode: Equatable, Sendable { case client, server }

enum PointerButton: Sendable { case left, middle, right }

struct KeyboardMapping: Equatable, Sendable {
    var commandMapsTo: GuestModifier = .super
    var optionMapsTo: GuestModifier = .alt
}

/// Host input in the host's own terms; the adapter translates key codes and coordinates.
enum InputEvent: Sendable {
    case keyDown(keyCode: UInt16, mapping: KeyboardMapping)
    case keyUp(keyCode: UInt16, mapping: KeyboardMapping)
    /// Host caps-lock state — on change and on focus — so the guest's lock keys follow the Mac's.
    case capsLock(on: Bool)
    case releaseAllKeys
    /// Client mode: absolute guest pixels.
    case pointerPosition(x: Int, y: Int, viewportID: Int)
    /// Server mode: raw deltas while captured.
    case pointerMotion(dx: Int, dy: Int)
    case buttonDown(PointerButton), buttonUp(PointerButton)
    /// Positive = up, negative = down.
    case wheel(clicks: Int)
}

/// BGRA, straight alpha, `width * 4` bytes per row; hotspot in cursor pixels.
struct CursorImage: Sendable, Equatable {
    var width: Int, height: Int, hotX: Int, hotY: Int
    var pixels: [UInt8]
}

enum CursorChange: Sendable, Equatable {
    case shape(CursorImage?)          // nil hides the pointer
    case moved(x: Int, y: Int)        // server mode only
}

/// What one viewport window consumes: pixels and the pointer drawn over them.
enum ViewportEvent: Sendable {
    case frame(FrameUpdate)
    case cursor(CursorChange)
}
```

Extend `BackendEvent` with `case pointerMode(PointerMode)` and `case cursor(viewportID: Int, CursorChange)`, and the protocol with:

```swift
    /// Synchronous on purpose: the backend must preserve order, and a `Task` per event would not.
    func sendInput(_ event: InputEvent)
```

- [ ] **Step 2: Teach SessionModel**

In `Sources/SpiceSee/SessionModel.swift`:

```swift
    private(set) var pointerMode: PointerMode = .client
    var keyboardMapping = KeyboardMapping()
    /// Mirrors AppSettings.sendLockKeys; SpiceSeeApp keeps it current.
    var sendLockKeys = true
```

Rename the frame fan-out to viewport events (the same one-stream-per-window rule applies to cursor changes):

```swift
    private var viewportSubscribers: [UUID: (viewportID: Int, continuation: AsyncStream<ViewportEvent>.Continuation)] = [:]

    func viewportEvents(for viewportID: Int) -> AsyncStream<ViewportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ViewportEvent.self, bufferingPolicy: .unbounded)
        let key = UUID()
        viewportSubscribers[key] = (viewportID, continuation)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.viewportSubscribers[key] = nil } }
        return stream
    }

    private func publish(_ event: ViewportEvent, to viewportID: Int) {
        for (_, s) in viewportSubscribers where s.viewportID == viewportID { s.continuation.yield(event) }
    }
```

In `connect`: `keyboardMapping = KeyboardMapping(commandMapsTo: connection.advanced.commandMapsTo, optionMapsTo: connection.advanced.optionMapsTo)`.

In `apply(_:)`:

```swift
        case let .agent(state):
            agent = state          // capture is decided by pointer mode now, not by agent presence
        case let .pointerMode(mode):
            pointerMode = mode
            if mode == .client { pointerCaptured = false }   // an agent came up: absolute pointer, nothing to release
        case let .frame(update):
            publish(.frame(update), to: update.viewportID)
        case let .cursor(viewportID, change):
            publish(.cursor(change), to: viewportID)
        case .disconnected:
            phase = .idle
            viewports = []
            pointerCaptured = false
```

And the input entry points:

```swift
    func sendInput(_ event: InputEvent) {
        guard phase == .connected else { return }
        backend.sendInput(event)
    }

    /// Called by the input view when it grabs or lets go of the pointer (server mode).
    func setPointerCaptured(_ captured: Bool) { pointerCaptured = captured }

    func sendCtrlAltDel() { Task { [backend] in await backend.sendCtrlAltDel() } }
```

`releasePointer()` stays (the HUD copy references the chord; the input view does the real release in Task 11 and calls `setPointerCaptured(false)`).

Update `MetalSurfaceView.Coordinator.pump` to take `AsyncStream<ViewportEvent>` and, for now, forward only frames:

```swift
        func pump(_ events: AsyncStream<ViewportEvent>, into view: GuestSurfaceView) {
            task?.cancel()
            task = Task { [weak view] in
                for await event in events {
                    guard let view else { return }
                    switch event {
                    case let .frame(update): view.apply(update)
                    case .cursor: break            // Task 12
                    }
                }
            }
        }
```

and in `makeNSView`: `context.coordinator.pump(session.viewportEvents(for: viewport.id), into: view)`. (The old `where update.viewportID == viewportID` filter was redundant — `viewportEvents(for:)` already filters.)

In `SpiceSeeApp.swift`, inside the manager `Window` content, after `.task { … }`:

```swift
                .onChange(of: settings.sendLockKeys, initial: true) { _, on in session.sendLockKeys = on }
```

- [ ] **Step 3: The real adapter**

In `Sources/SpiceSee/SpiceKitBackend.swift`:

One FIFO for the backend's lifetime: `sendInput` yields into it synchronously, and the connect task drains it into the session, so order is the order the views produced. Sending while no session is up is dropped by the bounded buffer.

The queue carries host events from the views and, for Ctrl-Alt-Del, ready-made guest input — `InputEvent` is an app type and must not grow a SPICE payload:

```swift
    private enum Queued: Sendable { case host(InputEvent), guest(GuestInput) }
    private let inputs: AsyncStream<Queued>
    private let inputCont: AsyncStream<Queued>.Continuation

    init() { (inputs, inputCont) = AsyncStream.makeStream(of: Queued.self, bufferingPolicy: .bufferingNewest(1024)) }

    func sendInput(_ event: InputEvent) { inputCont.yield(.host(event)) }
```

In `connect`, right after `await live.store(session)`:

```swift
                let inputs = inputs
                let pump = Task {
                    for await q in inputs {
                        switch q {
                        case let .host(e): Self.translate(e).forEach(session.send)
                        case let .guest(g): session.send(g)
                        }
                    }
                }
                defer { pump.cancel() }
```

(`defer` inside the `Task` closure runs when the event loop returns, i.e. on `.disconnected` — the pump stops with the session.) Then, in the event `switch`:

```swift
                    case let .pointerMode(mode):
                        continuation.yield(.pointerMode(mode == .client ? .client : .server))
                    case let .cursor(change, displayID):
                        continuation.yield(.cursor(viewportID: Int(displayID), Self.translate(change)))
                    case let .agent(connected):
                        continuation.yield(.agent(connected ? .connected : .absent))
```

And the translations plus a real Ctrl-Alt-Del:

```swift
    /// The guest's secure attention sequence: LCtrl, LAlt, Delete down, then up in reverse.
    func sendCtrlAltDel() async {
        for s in [XTScancode.leftControl, .leftAlt, .delete] { inputCont.yield(.guest(.keyDown(s))) }
        for s in [XTScancode.delete, .leftAlt, .leftControl] { inputCont.yield(.guest(.keyUp(s))) }
    }
```

```swift
    private static func translate(_ e: InputEvent) -> [GuestInput] {
        switch e {
        case let .keyDown(code, m): return KeyMap.scancode(keyCode: code, commandMapsTo: target(m.commandMapsTo), optionMapsTo: target(m.optionMapsTo)).map { [.keyDown($0)] } ?? []
        case let .keyUp(code, m): return KeyMap.scancode(keyCode: code, commandMapsTo: target(m.commandMapsTo), optionMapsTo: target(m.optionMapsTo)).map { [.keyUp($0)] } ?? []
        case let .capsLock(on): return [.hostCapsLock(on)]
        case .releaseAllKeys: return [.releaseAllKeys]
        case let .pointerPosition(x, y, id): return [.pointerPosition(x: UInt32(max(0, x)), y: UInt32(max(0, y)), displayID: UInt8(clamping: id))]
        case let .pointerMotion(dx, dy): return [.pointerMotion(dx: Int32(clamping: dx), dy: Int32(clamping: dy))]
        case let .buttonDown(b): return [.buttonDown(button(b))]
        case let .buttonUp(b): return [.buttonUp(button(b))]
        case let .wheel(clicks): return clicks == 0 ? [] : [.wheel(clicks: clicks)]
        }
    }
    private static func target(_ m: GuestModifier) -> ModifierTarget { switch m { case .super: .super; case .ctrl: .ctrl; case .alt: .alt } }
    private static func button(_ b: PointerButton) -> MouseButton { switch b { case .left: .left; case .middle: .middle; case .right: .right } }
    private static func translate(_ c: SpiceCanvas.CursorChange) -> CursorChange {
        switch c {
        case let .shape(s): .shape(s.map { CursorImage(width: $0.width, height: $0.height, hotX: $0.hotX, hotY: $0.hotY, pixels: $0.pixels) })
        case let .moved(x, y): .moved(x: x, y: y)
        }
    }
```

The app's `CursorChange` and `SpiceCanvas.CursorChange` share a name; qualify the engine one as above and the app one as `SpiceSee.CursorChange`… the app module is `SpiceSee`, so inside the adapter the unqualified name resolves to the app's; only the parameter type needs `SpiceCanvas.` — as written.

- [ ] **Step 4: The mock**

`MockSessionBackend`: after `.agent(...)` yield `.pointerMode(scenario == .noAgent ? .server : .client)`; when the agent connects (non-`noAgent`) yield `.pointerMode(.client)` next to `.agent(.connected)`. Add `func sendInput(_ event: InputEvent) {}`. For design review of Task 12, also yield one cursor after `.connected`:

```swift
                    continuation.yield(.cursor(viewportID: 0, .shape(Self.arrowCursor)))
                    continuation.yield(.cursor(viewportID: 0, .moved(x: 300, y: 260)))
```

with

```swift
    /// A 12×20 black arrow with a white outline — enough to see the overlay in `--mock`.
    private static let arrowCursor: CursorImage = {
        let w = 12, h = 20
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            let span = min(y, w - 1)   // widening diagonal
            for x in 0 ... span {
                let i = (y * w + x) * 4
                let edge = x == 0 || x == span || y == h - 1
                px[i] = edge ? 255 : 0; px[i + 1] = edge ? 255 : 0; px[i + 2] = edge ? 255 : 0; px[i + 3] = 255
            }
        }
        return CursorImage(width: w, height: h, hotX: 0, hotY: 0, pixels: px)
    }()
```

- [ ] **Step 5: Build the app and run every scenario**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -3
swift test 2>&1 | tail -1
```

Expected: `BUILD SUCCEEDED`; the SPM suite unchanged. Then launch `--mock --scenario noAgent --autoconnect` and `--scenario desktop --autoconnect` (see CLAUDE.md for the `open -n … --args` form and the window-scoped screenshot recipe). `noAgent`: the HUD must **not** appear on connect any more (nothing has captured yet — Task 11 makes the click do it). `desktop`: agent chip green, no cue. Screenshot both with `screencapture -l<id>`, look at them.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpiceSee
git commit -m "feat(app): input, pointer-mode and cursor events cross the SessionBackend seam"
```

---
### Task 10: GuestInputView — keyboard, lock keys, focus (first live milestone: typing into the installer)

**Files:**
- Create: `Sources/SpiceSee/GuestInputView.swift`
- Modify: `Sources/SpiceSee/MetalSurfaceView.swift` (host the input view, pass state)

**Interfaces:**
- Consumes: `SessionModel.sendInput/keyboardMapping/sendLockKeys/pointerMode/releaseChord/setPointerCaptured`, `InputEvent`, `KeyMap.capsLockKeyCode` is *not* visible here (app has no SpiceKit import in views) — the caps-lock key code `0x39` is repeated as a private constant with a comment pointing at `KeyMap`.
- Produces: `final class GuestInputView: NSView` with `var onInput: (InputEvent) -> Void`, `var keyboardMapping`, `var sendLockKeys`, `var pointerMode`, `var releaseChord`, `var onCaptureChange: (Bool) -> Void`, `var transform: () -> ViewportGeometry?` (Task 11), `func releaseCapture()`.

- [ ] **Step 1: Write the view (keyboard half)**

```swift
// Sources/SpiceSee/GuestInputView.swift
import AppKit

/// Receives every host event meant for the guest. Sits over the Metal surface, fills it, and is the
/// window's first responder while a session is on screen. Keyboard here; pointer in the extension
/// below (Task 11); cursor shape in `MetalSurfaceView` (Task 12).
final class GuestInputView: NSView {
    var onInput: (InputEvent) -> Void = { _ in }
    var onCaptureChange: (Bool) -> Void = { _ in }
    var keyboardMapping = KeyboardMapping()
    var sendLockKeys = true
    var pointerMode: PointerMode = .client { didSet { if pointerMode == .client { releaseCapture() } } }
    var releaseChord: ReleaseChord = .controlOption

    /// kVK_CapsLock. Caps lock is synced as lock state (INPUTS_KEY_MODIFIERS), never as a scancode — see SpiceKit.KeyMap.
    private static let capsLockKeyCode: UInt16 = 0x39

    private var resignObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resignObserver.map(NotificationCenter.default.removeObserver)
        deactivateObserver.map(NotificationCenter.default.removeObserver)
        guard let window else { releaseCapture(); return }   // window closed while captured: give the pointer back
        window.makeFirstResponder(self)
        // The first responder does not resign when its window stops being key, so watch the window
        // and the app: a Cmd-Tab away must release every held key and let the pointer go.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFocus() }
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFocus() }
        }
    }

    override func becomeFirstResponder() -> Bool {
        if sendLockKeys { onInput(.capsLock(on: NSEvent.modifierFlags.contains(.capsLock))) }
        return true
    }

    override func resignFirstResponder() -> Bool { lostFocus(); return true }

    private func lostFocus() {
        onInput(.releaseAllKeys)
        releaseCapture()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Auto-repeat arrives as repeated keyDowns; the guest wants repeated makes with no break in between.
        onInput(.keyDown(keyCode: event.keyCode, mapping: keyboardMapping))
    }

    override func keyUp(with event: NSEvent) {
        onInput(.keyUp(keyCode: event.keyCode, mapping: keyboardMapping))
    }

    /// Menu key equivalents (⌘N, ⌘W, ⌘,…) keep their meaning; anything the menu bar declines falls
    /// through to keyDown and reaches the guest with ⌘ mapped per preference.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == Self.capsLockKeyCode {
            if sendLockKeys { onInput(.capsLock(on: event.modifierFlags.contains(.capsLock))) }
            return
        }
        if pointerCaptured, chordIsDown(event.modifierFlags) {
            releaseCapture()
            return
        }
        // Left and right variants share a device-independent flag; the device-dependent bits tell
        // them apart, so a held right ⌘ does not read as a second press of the left one.
        let pressed = event.modifierFlags.rawValue & Self.deviceMask(for: code) != 0
        onInput(pressed ? .keyDown(keyCode: code, mapping: keyboardMapping) : .keyUp(keyCode: code, mapping: keyboardMapping))
    }

    /// NX_DEVICE*KEYMASK bits from IOKit's IOLLEvent.h, keyed by kVK code.
    private static func deviceMask(for keyCode: UInt16) -> UInt {
        switch keyCode {
        case 0x3B: 0x0001   // left control
        case 0x38: 0x0002   // left shift
        case 0x3C: 0x0004   // right shift
        case 0x37: 0x0008   // left command
        case 0x36: 0x0010   // right command
        case 0x3A: 0x0020   // left option
        case 0x3D: 0x0040   // right option
        case 0x3E: 0x2000   // right control
        default: 0
        }
    }

    private func chordIsDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        var down: Set<ChordModifier> = []
        if flags.contains(.control) { down.insert(.control) }
        if flags.contains(.option) { down.insert(.option) }
        if flags.contains(.shift) { down.insert(.shift) }
        if flags.contains(.command) { down.insert(.command) }
        return down == releaseChord.modifiers
    }

    // MARK: Capture state (behaviour in Task 11)

    private(set) var pointerCaptured = false
    func releaseCapture() {}   // replaced in Task 11
}
```

`NSNotificationCenter` closures are not `@MainActor`; `MainActor.assumeIsolated` is correct because `queue: .main` delivers there. `deinit` must remove both observers.

- [ ] **Step 2: Host it from MetalSurfaceView**

In `MetalSurfaceView.makeNSView`, after creating the surface view:

```swift
        let input = GuestInputView(frame: view.bounds)
        input.autoresizingMask = [.width, .height]
        view.addSubview(input)
        view.inputView = input
        configure(input)
```

with `GuestSurfaceView` gaining `var inputView: GuestInputView?` and `MetalSurfaceView` gaining:

```swift
    private func configure(_ input: GuestInputView) {
        input.onInput = { [session] in session.sendInput($0) }
        input.onCaptureChange = { [session] in session.setPointerCaptured($0) }
        input.keyboardMapping = session.keyboardMapping
        input.sendLockKeys = session.sendLockKeys
        input.pointerMode = session.pointerMode
        input.releaseChord = session.releaseChord
    }
```

and `updateNSView` calling `nsView.inputView.map(configure)` (it runs whenever an observed property the body read changes; reading `session.pointerMode` etc. inside `configure` during `makeNSView`/`updateNSView` registers them). Because `configure` reads observable properties, wrap the reads in `updateNSView` so SwiftUI tracks them — the simplest is to read them into locals in `updateNSView` and pass them in.

- [ ] **Step 3: Build and verify live**

```bash
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -2
```

Connect to `192.168.50.6:5930` (the user's saved connection — see the memory note: the real app reads the user's own `connections.json`, so **ask the user to connect** if the entry is missing) and:

1. Press Tab / Shift-Tab: the installer's focus ring moves (visible in the window within one frame).
2. Press Alt-N (⌥N, Option→Alt): the "Next" button activates. Press Alt-B to come back.
3. Toolbar Ctrl-Alt-Del: the installer ignores it, but `log stream --predicate 'subsystem == "com.spicesee"' --level debug` shows no error, and a `spicerec` proxy in between (`swift run spicerec 5901 192.168.50.6 5930 recordings/live`, connect to `127.0.0.1:5901`) records `1d000000 38000000 e0530000 e0d30000 b8000000 9d000000` as six consecutive KEY frames.
4. Cmd-Tab away and back: the recording shows KEY_UP for anything held (hold Shift while switching).

Report exactly which of these you observed. Hover/focus-ring appearance is visible in a `screencapture -l<id>`; if the guest did not visibly react, say so.

- [ ] **Step 4: Commit**

```bash
git add Sources/SpiceSee/GuestInputView.swift Sources/SpiceSee/MetalSurfaceView.swift
git commit -m "feat(app): keyboard input to the guest; lock-key sync; release on focus loss"
```

---

### Task 11: Mouse — client mode, server-mode capture, release chord, honest HUD

**Files:**
- Modify: `Sources/SpiceSee/GuestInputView.swift` (pointer extension, capture), `Sources/SpiceSee/MetalSurfaceView.swift` (expose the transform)
- Modify: `Sources/SpiceSee/Theme.swift` (`Metric.Pointer.wheelUnitsPerClick` is *not* added — that constant lives in `SpiceKit.WheelAccumulator`; nothing to add here unless a dimension appears)

**Interfaces:**
- Consumes: `ViewportTransform` (Task 7) — **through the adapter boundary?** No: `ViewportTransform` is pure geometry in `SpiceKit`, and `MetalSurfaceView.swift` already imports Metal/QuartzCore; importing `SpiceKit` there for a geometry helper is allowed (the rule is that views do not see *SPICE* types — this is not one). `WheelAccumulator` likewise.
- Produces: `GuestSurfaceView.transform: ViewportTransform?` (nil until the first frame), used by Task 12 for the overlay.

- [ ] **Step 1: Replace `clipExtent` with the shared transform**

In `GuestSurfaceView`:

```swift
    /// Guest ↔ view geometry for the current scaling; nil until the surface size is known.
    var transform: ViewportTransform? {
        guard let texture else { return nil }
        return ViewportTransform(viewSize: bounds.size, surfaceSize: CGSize(width: texture.width, height: texture.height),
                                 scaling: scaling == .fit ? .fit : .oneToOne)
    }
```

and in `render()` derive the clip-space extent from it instead of `clipExtent`:

```swift
        guard let t = transform else { return }
        let r = t.viewRect(forGuest: CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
        var extent = Self.clipSpace(r, in: bounds.size)
```

```swift
    /// Centre and half-extent of a view rect in Metal clip space (y up).
    static func clipSpace(_ r: CGRect, in view: CGSize) -> SIMD4<Float> {
        let cx = Float((r.midX / view.width) * 2 - 1), cy = Float(1 - (r.midY / view.height) * 2)
        return SIMD4(cx, cy, Float(r.width / view.width), Float(r.height / view.height))
    }
```

Change the vertex shader to take `float4 placement` (centre.xy, extent.zw): `out.position = float4(placement.xy + corners[id] * placement.zw, 0, 1);` and `setVertexBytes(&extent, length: MemoryLayout<SIMD4<Float>>.size, index: 0)`. Delete `clipExtent`. Run the app in `--mock`: fit and 1:1 must look exactly as before (compare a `screencapture -l<id>` against one taken before the change — the pixels must match).

- [ ] **Step 2: The pointer half of GuestInputView**

Add to `GuestInputView`:

```swift
    /// Supplies the surface geometry; set by MetalSurfaceView.
    var transform: () -> ViewportTransform? = { nil }

    private var tracking: NSTrackingArea?
    private var wheel = WheelAccumulator()
    private var motionCarry = CGPoint.zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Motion

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    private func pointerMoved(_ event: NSEvent) {
        switch pointerMode {
        case .client:
            guard let t = transform() else { return }
            let p = convert(event.locationInWindow, from: nil)
            let g = t.guestPoint(fromView: p)
            onInput(.pointerPosition(x: g.x, y: g.y, viewportID: viewportID))
        case .server:
            guard pointerCaptured else { return }
            // Deltas are fractional on trackpads; carry the remainder so slow motion is not lost.
            motionCarry.x += event.deltaX; motionCarry.y += event.deltaY
            let dx = Int(motionCarry.x.rounded(.towardZero)), dy = Int(motionCarry.y.rounded(.towardZero))
            motionCarry.x -= CGFloat(dx); motionCarry.y -= CGFloat(dy)
            if dx != 0 || dy != 0 { onInput(.pointerMotion(dx: dx, dy: dy)) }
        }
    }

    // MARK: Buttons

    override func mouseDown(with event: NSEvent) { button(.left, down: true, event) }
    override func mouseUp(with event: NSEvent) { button(.left, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { button(.right, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { button(.right, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { button(.middle, down: true, event) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { button(.middle, down: false, event) } }

    private func button(_ b: PointerButton, down: Bool, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        if pointerMode == .server, !pointerCaptured {
            // The grabbing click is swallowed, like spice-gtk: the user asked for the pointer, not a click.
            if down { capture() }
            return
        }
        if pointerMode == .client { pointerMoved(event) }   // the press lands where the pointer is
        onInput(down ? .buttonDown(b) : .buttonUp(b))
    }

    override func scrollWheel(with event: NSEvent) {
        guard pointerMode == .client || pointerCaptured else { return }
        let clicks = wheel.add(precise: event.hasPreciseScrollingDeltas, delta: event.scrollingDeltaY)
        if clicks != 0 { onInput(.wheel(clicks: clicks)) }
    }

    // MARK: Capture (server mode)

    /// Hide the host pointer and stop it moving; from here on the guest owns it and we forward deltas.
    private func capture() {
        guard !pointerCaptured, let window else { return }
        pointerCaptured = true
        motionCarry = .zero
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        // Park the (invisible) pointer mid-view so it stays over us however far the user moves.
        let centre = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
        if let screen = window.screen ?? NSScreen.main {
            CGWarpMouseCursorPosition(CGPoint(x: centre.x, y: screen.frame.maxY - centre.y))
        }
        onCaptureChange(true)
    }

    func releaseCapture() {
        guard pointerCaptured else { return }
        pointerCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        onInput(.releaseAllKeys)     // the chord's own modifiers were forwarded on the way in
        onCaptureChange(false)
    }

    var viewportID = 0
```

Replace the Task 10 stub `func releaseCapture() {}` and `private(set) var pointerCaptured` with the above (keep `pointerCaptured` `private(set)`). `CGWarpMouseCursorPosition` takes a CG (top-left origin) point; the conversion above flips from AppKit's bottom-left screen space.

Wire `viewportID` and `transform` in `MetalSurfaceView.configure`: `input.viewportID = viewport.id`, `input.transform = { [weak view] in view?.transform }`.

- [ ] **Step 3: Make the HUD honest**

`SessionWindowView` already flashes the HUD on `pointerCaptured` becoming true and shows the cue while true — with `setPointerCaptured` driven by the view, nothing there changes. Confirm with `--mock --scenario noAgent --autoconnect`: the HUD appears only after the first click, the cue stays, ⌃⌥ dismisses both and the pointer reappears. Screenshot the captured state.

- [ ] **Step 4: Live verification**

Against the dev server (server mode, no agent):

1. Click into the viewport: pointer disappears, HUD flashes, cue in the top-trailing corner.
2. Move: the installer's own (guest-drawn) arrow follows; direction and roughly 1:1 speed.
3. Click "Next"/"Back" in the installer: it responds. Right-click: nothing expected in the installer — check `spicerec` shows PRESS 3.
4. Scroll over the language list: the list scrolls in the same direction as a Mac list would.
5. ⌃⌥: pointer returns, cue gone. Cmd-Tab while captured: same.
6. Press ⌃⌥ *while not captured* and type: no stray effect.

Client mode cannot be verified on this guest (no agent, no tablet). State that plainly in the report; the `--mock --scenario desktop` path shows the absolute pointer code runs (log the `pointerPosition` events at `.debug`, look for them).

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceSee/GuestInputView.swift Sources/SpiceSee/MetalSurfaceView.swift
git commit -m "feat(app): mouse in both modes; server-mode capture with release chord"
```

---

### Task 12: Cursor presentation — NSCursor in client mode, Metal overlay in server mode

**Files:**
- Modify: `Sources/SpiceSee/MetalSurfaceView.swift` (cursor state + overlay pass), `Sources/SpiceSee/GuestInputView.swift` (`cursorUpdate`)

**Interfaces:**
- Consumes: `ViewportEvent.cursor(CursorChange)`, `CursorImage`, `GuestSurfaceView.transform`.
- Produces: `GuestSurfaceView.apply(_ change: CursorChange)`, `GuestInputView.hostCursor: NSCursor?`.

- [ ] **Step 1: Turn a CursorImage into an NSCursor**

```swift
extension CursorImage {
    /// BGRA straight alpha → NSCursor. `.first` + `byteOrder32Little` is the BGRA reading (the same
    /// pairing PNG.encode needed); `.last` would silently swap channels.
    var nsCursor: NSCursor? {
        let data = Data(pixels)
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSCursor(image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)), hotSpot: NSPoint(x: hotX, y: hotY))
    }

    static let hidden: NSCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
}
```

Put this in `GuestInputView.swift`; it is presentation glue for that view.

- [ ] **Step 2: Client mode — the host pointer wears the guest's shape**

In `GuestInputView`:

```swift
    /// The guest's cursor shape (client mode). nil = the guest hid it.
    var hostCursor: NSCursor? = NSCursor.arrow {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard pointerMode == .client else { return }
        (hostCursor ?? CursorImage.hidden).set()
    }

    override func resetCursorRects() {
        if pointerMode == .client { addCursorRect(bounds, cursor: hostCursor ?? CursorImage.hidden) }
    }
```

(`.cursorUpdate` is already in the tracking-area options from Task 11.)

- [ ] **Step 3: Server mode — composite the shape at the reported position**

In `GuestSurfaceView`:

```swift
    private var cursorTexture: MTLTexture?
    private var cursorHotspot = (x: 0, y: 0)
    private var cursorPosition: (x: Int, y: Int)?
    private var cursorShape: CursorImage?
    var showsCursorOverlay = false { didSet { if showsCursorOverlay != oldValue { render() } } }

    func apply(_ change: CursorChange) {
        switch change {
        case let .shape(image):
            cursorShape = image
            cursorTexture = image.flatMap(makeCursorTexture)
            cursorHotspot = image.map { ($0.hotX, $0.hotY) } ?? (0, 0)
            inputView?.hostCursor = image?.nsCursor
        case let .moved(x, y):
            cursorPosition = (x, y)
        }
        render()
    }

    private func makeCursorTexture(_ image: CursorImage) -> MTLTexture? {
        guard let device, image.width > 0, image.height > 0, image.pixels.count >= image.width * image.height * 4 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .managed
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        image.pixels.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            t.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: base, bytesPerRow: image.width * 4)
        }
        return t
    }
```

A second pipeline for the overlay with blending (straight alpha):

```swift
    private static func makePipeline(_ device: MTLDevice, blended: Bool) -> MTLRenderPipelineState? {
        // … as before, plus:
        if blended {
            let c = descriptor.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
```

`descriptor.colorAttachments[0]` is non-optional in Swift's Metal overlay (`MTLRenderPipelineColorAttachmentDescriptor`), so drop the `!` if the compiler says so. Store `overlayPipeline = device.flatMap { Self.makePipeline($0, blended: true) }`.

In `render()`, after the surface quad and before `endEncoding`:

```swift
        if showsCursorOverlay, let cursorTexture, let overlayPipeline, let pos = cursorPosition, let t = transform {
            let rect = t.viewRect(forGuest: CGRect(x: pos.x - cursorHotspot.x, y: pos.y - cursorHotspot.y,
                                                   width: cursorTexture.width, height: cursorTexture.height))
            var placement = Self.clipSpace(rect, in: bounds.size)
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBytes(&placement, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(cursorTexture, index: 0)
            encoder.setFragmentSamplerState(sharpSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
```

`MetalSurfaceView.Coordinator.pump` forwards `.cursor(change)` to `view.apply(change)`; `configure` sets `view.showsCursorOverlay = session.pointerMode == .server`.

- [ ] **Step 4: Verify**

`--mock --scenario noAgent --autoconnect`: the mock's arrow appears at (300, 260) in guest pixels over the synthetic desktop, scaled with the viewport in Fit and unscaled in 1:1. `--scenario desktop`: no overlay; hovering the viewport shows the mock arrow as the *host* cursor — **hover cannot be verified from here** (no synthetic events); hand this one to the user. Screenshot the noAgent overlay and look at it: black arrow, white outline, top-left hotspot at (300, 260).

Dev server: a VGA guest sends no shapes; the overlay stays empty and the guest's own arrow (in the framebuffer) is what moves. Say so.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceSee/MetalSurfaceView.swift Sources/SpiceSee/GuestInputView.swift
git commit -m "feat(app): guest cursor as NSCursor in client mode, Metal overlay in server mode"
```

---

### Task 13: M2 exit — full verification, docs, memory

**Files:**
- Modify: `CLAUDE.md` (Architecture paragraph: M2 shipped, what M3 lacks), `docs/dev-server.md` (if anything changed in Tasks 10–12), this plan (tick boxes), `docs/superpowers/plans/2026-08-22-spicesee-m0-m1-pixels.md` untouched.

- [ ] **Step 1: Whole suite and the app**

```bash
swift test 2>&1 | tail -1
scripts/check-vendored-notices.sh; echo exit=$?
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -1
```

Expected: every test passes (60 before this plan + the ~30 added), notices script exit 0, `BUILD SUCCEEDED`.

- [ ] **Step 2: The M2 exit criterion, live**

Spec §9: "Keyboard, mouse both modes, native cursor." On the dev guest, in one sitting: click to capture, use the mouse to open the language dropdown, use the keyboard to pick an entry and Tab to "Next", press Enter, watch the installer advance to the next screen, press ⌃⌥ to release. Record it through `spicerec` and keep the c2s inputs capture in `recordings/` (gitignored) as evidence; quote the frame types you saw in the report.

Client mode and the cursor channel with real shapes need a guest with vdagent or a QXL driver. If the user has one (a Linux desktop guest on the same box would do: `quickemu --vm ubuntu.conf` with `spice-vdagent` in the guest), verify: pointer moves without capture, the host cursor turns into the guest's I-beam over a text field, no HUD ever shows. Otherwise list these as **not verified** in the recap — do not imply they work.

- [ ] **Step 3: Update CLAUDE.md**

Replace the "**M0–M1 are done**" paragraph's "What does not" sentence and the following paragraph with:

```
**M0–M2 are done: a real guest renders and can be driven.** … (existing list) … plus, from M2
(`docs/superpowers/plans/2026-08-24-spicesee-m2-input.md`): the inputs and cursor channels,
positional keyboard mapping (`SpiceKit.KeyMap`), both mouse modes with server-mode capture, and
the guest cursor. What does not: **TLS and `.vv` (M3)**; streams/video, tiers 2–3 (M4); agent and
clipboard (M5); audio (M6).

Input rules that are easy to break: `SpiceSession.send` and `SessionBackend.sendInput` are
synchronous and ordered on purpose — never wrap an input event in its own `Task`. Caps lock is
synced as lock *state* (`INPUTS_KEY_MODIFIERS`), never sent as a scancode. `ViewportTransform` is
the single source of fit/1:1 geometry for present, mouse mapping and the cursor overlay.
```

and delete the "Because input is M2…" paragraph (it is no longer true).

- [ ] **Step 4: Memory**

Update `~/.claude/projects/-Users-aaronpollock-code-spicesee/memory/spicesee-plan-sequence.md`: M2 shipped (date), M3 next, what could and could not be verified live, and the xdotool recording recipe as the way to get reference bytes for any client→server message.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: M2 shipped — input, capture and cursor; refresh CLAUDE.md"
```

---

## Self-review notes

- **Spec coverage (§6 + M2):** kVK table with E0 prefix (T7), modifiers via `flagsChanged` incl. left/right (T10), release-all on resign key and app deactivate (T10), lock keys both ways — host→guest via `KEY_MODIFIERS`, guest→host recorded in `InputsChannel.guestLockKeys` and preserved in every sync (T4/T8; macOS has no API to set the host's caps-lock state, so "both ways" ends at tracking), Cmd→Super / Option→Alt swappable (T7/T9 — the preference UI already exists), OS-reserved combos stay with macOS (T10 `performKeyEquivalent`), wheel as button 4/5 pairs with trackpad accumulation (T7/T8/T11), server-mode capture with hide + disassociate + chord release (T11), cursor shapes ALPHA/MONO/COLOR16/24/32 with cache (T6) — COLOR4/COLOR8 are logged and skipped, same as spice-gtk; NSCursor with hotspot in client mode and Metal composite in server mode (T12); mouse-mode request when supported (T8). Ctrl-Alt-Del toolbar button becomes real (T9).
- **Known deviations:** Pause/PrintScreen not mapped (no Mac keys). Cursor trails ignored. Motion deltas are in view points, not device pixels — on a 2× display a captured pointer moves at half the raw rate; revisit if it feels slow (multiply by `backingScaleFactor` in `pointerMoved`). HiDPI coordinate scaling waits for M5 monitors config.
- **Cross-implementation checks:** T3 pins scancode packing, motion, press/release and the KEY_SCANCODE cap against `remote-viewer`'s bytes; T5 replays the recorded cursor channel; T10–11 drive the real guest.
- **Type consistency:** `XTScancode(_:extended:)`, `wireCode(pressed:)`, `MouseButtonState` (array-literal), `LockKeys`, `InputsChannel.syncCapsLock(_:)`, `CursorChange.shape/.moved` (engine, `SpiceCanvas`) vs app `CursorChange` (same case names, `CursorImage` payload), `SessionEvent.cursor(_, displayID:)`, `GuestInput.pointerPosition(x:y:displayID:)` with `UInt32`/`UInt8` vs app `InputEvent.pointerPosition(x:y:viewportID:)` with `Int`, `ViewportTransform.guestPoint(fromView:)` / `viewRect(forGuest:)`, `SessionModel.viewportEvents(for:)` / `setPointerCaptured(_:)` / `sendInput(_:)`, `GuestSurfaceView.transform` / `apply(_ change:)` / `showsCursorOverlay` / `inputView` — spelled the same in every task that uses them.
