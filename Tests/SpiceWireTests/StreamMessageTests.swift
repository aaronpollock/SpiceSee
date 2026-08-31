import Testing
@testable import SpiceWire

@Test func streamCreateParses() throws {
    var w = SpiceWriter()
    w.u32(0); w.u32(3); w.u8(StreamFlags.topDown); w.u8(VideoCodecType.mjpeg.rawValue); w.u64(0)
    w.u32(640); w.u32(480); w.u32(640); w.u32(480)
    w.i32(10); w.i32(20); w.i32(490); w.i32(660)     // dest
    w.u8(0)                                           // clip none
    let m = try DisplayMessage(type: DisplayServerMsg.streamCreate.rawValue, payload: w.bytes)
    guard case let .streamCreate(s) = m else { Issue.record("case"); return }
    #expect(s.id == 3 && s.codec == .mjpeg && s.dest.width == 640)
    #expect(s.surfaceID == 0 && s.flags == StreamFlags.topDown)
    #expect(s.streamWidth == 640 && s.streamHeight == 480 && s.srcWidth == 640 && s.srcHeight == 480)
    #expect(s.dest == SpiceRect(top: 10, left: 20, bottom: 490, right: 660))
    #expect(s.clip == .none)
}

@Test func streamDataParses() throws {
    var w = SpiceWriter(); w.u32(3); w.u32(1000); w.u32(4); w.bytes([1, 2, 3, 4])
    let m = try DisplayMessage(type: DisplayServerMsg.streamData.rawValue, payload: w.bytes)
    guard case let .streamData(d) = m else { Issue.record("case"); return }
    #expect(d.id == 3 && d.mmTime == 1000 && d.data == [1, 2, 3, 4] && d.sized == nil)
}

@Test func streamDataSizedParses() throws {
    var w = SpiceWriter(); w.u32(3); w.u32(1000); w.u32(320); w.u32(200)
    w.i32(0); w.i32(0); w.i32(200); w.i32(320)
    w.u32(2); w.bytes([9, 9])
    let m = try DisplayMessage(type: DisplayServerMsg.streamDataSized.rawValue, payload: w.bytes)
    guard case let .streamData(d) = m else { Issue.record("case"); return }
    #expect(d.id == 3 && d.mmTime == 1000)
    #expect(d.sized?.width == 320 && d.sized?.height == 200 && d.data == [9, 9])
    #expect(d.sized?.dest == SpiceRect(top: 0, left: 0, bottom: 200, right: 320))
}

@Test func hostileStreamDataSizeRejected() throws {
    var w = SpiceWriter(); w.u32(3); w.u32(0); w.u32(0xFFFF_FFFF)
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.streamData.rawValue, payload: w.bytes)
    }
}

@Test func streamDataSizeExceedingPayloadRejected() throws {
    // Declared size (100) is small enough to pass the 1<<26 cap but larger than what's actually sent.
    var w = SpiceWriter(); w.u32(3); w.u32(0); w.u32(100); w.bytes([1, 2, 3])
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.streamData.rawValue, payload: w.bytes)
    }
}

@Test func unknownCodecRejected() throws {
    var w = SpiceWriter()
    w.u32(0); w.u32(1); w.u8(0); w.u8(99); w.u64(0)
    w.u32(1); w.u32(1); w.u32(1); w.u32(1)
    w.i32(0); w.i32(0); w.i32(1); w.i32(1); w.u8(0)
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.streamCreate.rawValue, payload: w.bytes)
    }
}

@Test func streamClipParses() throws {
    var w = SpiceWriter(); w.u32(5); w.u8(0)
    let m = try DisplayMessage(type: DisplayServerMsg.streamClip.rawValue, payload: w.bytes)
    guard case let .streamClip(id, clip) = m else { Issue.record("case"); return }
    #expect(id == 5 && clip == .none)
}

@Test func streamDestroyParses() throws {
    var w = SpiceWriter(); w.u32(7)
    let m = try DisplayMessage(type: DisplayServerMsg.streamDestroy.rawValue, payload: w.bytes)
    guard case let .streamDestroy(id) = m else { Issue.record("case"); return }
    #expect(id == 7)
}

@Test func streamDestroyAllParses() throws {
    let m = try DisplayMessage(type: DisplayServerMsg.streamDestroyAll.rawValue, payload: [])
    guard case .streamDestroyAll = m else { Issue.record("case"); return }
}

@Test func streamActivateReportParses() throws {
    var w = SpiceWriter(); w.u32(1); w.u32(2); w.u32(3); w.u32(4)
    let m = try DisplayMessage(type: DisplayServerMsg.streamActivateReport.rawValue, payload: w.bytes)
    guard case let .streamActivateReport(a) = m else { Issue.record("case"); return }
    #expect(a.streamID == 1 && a.uniqueID == 2 && a.maxWindowSize == 3 && a.timeoutMs == 4)
}

@Test func streamReportEncodes32Bytes() {
    let b = ClientMessage.streamReport(StreamReport(streamID: 3, uniqueID: 7, startFrameMMTime: 100,
                                                    endFrameMMTime: 200, numFrames: 30, numDrops: 1,
                                                    lastFrameDelay: -5, audioDelay: .max))
    #expect(b.count == 32)
    #expect(b[0] == 3 && b[4] == 7)
    #expect(b[8] == 100 && b[12] == 200 && b[16] == 30 && b[20] == 1)
    #expect(b[24] == 0xFB && b[25] == 0xFF)           // -5 little-endian
    #expect(b[28] == 0xFF && b[29] == 0xFF && b[30] == 0xFF && b[31] == 0xFF)  // audioDelay .max
}
