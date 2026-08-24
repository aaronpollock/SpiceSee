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
