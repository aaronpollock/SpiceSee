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

@Test func hiddenShapeIsStillCached() {
    var t = CursorTracker()
    let hiddenSet = CursorMessage.set(position: SpicePoint16(x: 3, y: 4), visible: false,
                                      cursor: SpiceCursor(flags: CursorFlags.cacheMe, header: shapeHeader, data: shapePixels))
    #expect(t.apply(hiddenSet) == [.shape(nil), .moved(x: 3, y: 4)])
    let fromCache = CursorMessage.set(position: SpicePoint16(x: 0, y: 0), visible: true,
                                      cursor: SpiceCursor(flags: CursorFlags.fromCache, header: shapeHeader, data: []))
    #expect(t.apply(fromCache) == [.shape(shape), .moved(x: 0, y: 0)])
}
