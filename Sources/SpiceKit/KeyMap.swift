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
