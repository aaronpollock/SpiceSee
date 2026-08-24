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
