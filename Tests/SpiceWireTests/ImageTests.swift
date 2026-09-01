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

@Test func rectRejectsOverflowingWidth() throws {
    var w = SpiceWriter()
    w.i32(0); w.i32(Int32.min); w.i32(0); w.i32(Int32.max)   // top, left, bottom, right — right - left overflows
    var r = SpiceReader(w.bytes)
    #expect(throws: WireError.self) { _ = try SpiceRect(reader: &r) }
}

@Test func rectRejectsOverflowingHeight() throws {
    var w = SpiceWriter()
    w.i32(Int32.min); w.i32(0); w.i32(Int32.max); w.i32(0)   // top, left, bottom, right — bottom - top overflows
    var r = SpiceReader(w.bytes)
    #expect(throws: WireError.self) { _ = try SpiceRect(reader: &r) }
}

// MARK: - ZLIB_GLZ_RGB

/// The layout every draw from a low-bandwidth-classified server uses: the descriptor is followed
/// by TWO lengths — `glz_data_size` (the uncompressed GLZ blob) and then the zlib data's own
/// size. Reading it like the single-length codecs slices `glz_data_size` bytes out of a message
/// that only holds the zlib bytes — which is how every draw from a real Proxmox VM over a VPN
/// was dropped as truncated. Shape and sizes here are from that capture (17:18:46, size 316).
@Test func zlibGlzImageCarriesBothLengths() throws {
    var w = SpiceWriter()
    w.u64(0)                    // image id
    w.u8(107); w.u8(0)          // ZLIB_GLZ_RGB, no flags
    w.u32(1280); w.u32(768)
    w.u32(4069)                 // glz_data_size: the *uncompressed* GLZ size
    w.u32(213)                  // data_size: what is actually in the message
    w.bytes([UInt8](repeating: 0xAB, count: 213))
    let image = try SpiceImage(reader: SpiceReader(w.bytes), base: SpiceReader(w.bytes))
    guard case let .zlibGlzRGB(glzSize, data) = image.payload else {
        Issue.record("parsed as \(image.payload)"); return
    }
    #expect(glzSize == 4069)
    #expect(data.count == 213)
}

@Test func zlibGlzRefusesAnAbsurdUncompressedSize() {
    var w = SpiceWriter()
    w.u64(0); w.u8(107); w.u8(0); w.u32(1280); w.u32(768)
    w.u32(UInt32.max)           // a hostile glz_data_size must fail before anything is allocated
    w.u32(4)
    w.bytes([1, 2, 3, 4])
    #expect(throws: WireError.self) { _ = try SpiceImage(reader: SpiceReader(w.bytes), base: SpiceReader(w.bytes)) }
}
