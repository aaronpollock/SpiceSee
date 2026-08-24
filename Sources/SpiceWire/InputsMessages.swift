public enum InputsServerMsg: UInt16, Sendable { case `init` = 101, keyModifiers = 102, mouseMotionAck = 111 }
public enum InputsClientMsg: UInt16, Sendable {
    case keyDown = 101, keyUp = 102, keyModifiers = 103, keyScancode = 104
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

extension MouseButtonState: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MouseButton...) { self.init(); elements.forEach { insert($0) } }
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

    /// The raw scancode byte(s) `SPICE_MSGC_INPUTS_KEY_SCANCODE` carries — the same E0-then-code
    /// order `wireCode` packs into a u32, but as the literal bytes `kbd_push_scan` consumes.
    public func rawBytes(pressed: Bool) -> [UInt8] {
        let byte = UInt8(code) | (pressed ? 0 : 0x80)
        return extended ? [0xE0, byte] : [byte]
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
    public static func keyScancode(_ s: XTScancode, pressed: Bool) -> [UInt8] { s.rawBytes(pressed: pressed) }
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
