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
