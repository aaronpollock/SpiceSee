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

@Test func scancodeRawBytesMatchWireCodeOrdering() {
    #expect(XTScancode(0x53, extended: true).rawBytes(pressed: true) == [0xE0, 0x53])
    #expect(XTScancode(0x53, extended: true).rawBytes(pressed: false) == [0xE0, 0xD3])
    #expect(XTScancode(0x1E).rawBytes(pressed: false) == [0x9E])
    #expect(ClientMessage.keyScancode(XTScancode(0x1E), pressed: true) == [0x1E])
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
