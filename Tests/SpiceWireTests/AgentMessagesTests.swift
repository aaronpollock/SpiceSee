import Foundation
import Testing
@testable import SpiceWire

/// The expected bytes here were not written by hand: they come from a C program that includes the
/// real `spice/vd_agent.h` and lays each message out with the actual structs and `VD_AGENT_SET_*`
/// macros (`Tools/agentref.c` in spirit — the generator is recorded in `docs/dev-server.md`). That
/// is what caught `sizeof(VDAgentMessage)` being 20 rather than the 24 natural alignment implies:
/// the struct is packed, so `opaque` gets no padding in front of it.
@Suite struct AgentMessagesTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    private func stream(_ m: AgentMessage, hasSelection: Bool = true) -> [UInt8] {
        AgentMessage.chunks(m.frame(hasSelection: hasSelection)).flatMap { $0 }
    }

    @Test func headerMatchesThePackedCStruct() {
        #expect(VDAgent.headerSize == 20)
        #expect(VDAgent.maxChunk == 2048)
        #expect(VDAgent.capsWords == 1)
    }

    @Test func announceCapabilitiesMatchesSpiceGTK() {
        let caps = CapabilitySet(bits: [AgentCap.clipboardByDemand, AgentCap.clipboardSelection])
        #expect(hex(stream(.announceCapabilities(request: true, caps: caps)))
                == "010000000600000000000000000000000800000001000000" + "60000000")
    }

    @Test func clipboardGrabMatchesSpiceGTK() {
        #expect(hex(stream(.clipboardGrab(.clipboard, [.utf8Text])))
                == "010000000700000000000000000000000800000000000000" + "01000000")
    }

    @Test func clipboardRequestMatchesSpiceGTK() {
        #expect(hex(stream(.clipboardRequest(.clipboard, .utf8Text)))
                == "010000000800000000000000000000000800000000000000" + "01000000")
    }

    @Test func clipboardDataMatchesSpiceGTK() {
        #expect(hex(stream(.clipboard(.clipboard, .utf8Text, Array("hi\n".utf8))))
                == "010000000400000000000000000000000b00000000000000" + "01000000" + "68690a")
    }

    @Test func clipboardReleaseMatchesSpiceGTK() {
        #expect(hex(stream(.clipboardRelease(.clipboard)))
                == "010000000900000000000000000000000400000000000000")
    }

    @Test func withoutTheSelectionCapThePrefixIsAbsent() {
        #expect(hex(stream(.clipboardRequest(.clipboard, .utf8Text), hasSelection: false))
                == "010000000800000000000000000000000400000001000000")
    }

    // MARK: Reassembly

    @Test func roundTripsThroughTheReassembler() throws {
        let sent = AgentMessage.clipboard(.clipboard, .utf8Text, Array("hello".utf8))
        var r = AgentReassembler()
        let frames = try r.push(stream(sent))
        #expect(frames.count == 1)
        #expect(try AgentMessage(frame: frames[0], hasSelection: true) == sent)
    }

    /// A payload past `VD_AGENT_MAX_DATA_SIZE` is split, and the pieces must rebuild into one
    /// message — the case the header size bug would have corrupted silently.
    @Test func reassemblesAMessageSplitAcrossChunks() throws {
        let big = [UInt8](repeating: 0x41, count: 5000)
        let chunks = AgentMessage.chunks(AgentMessage.clipboard(.clipboard, .utf8Text, big).frame(hasSelection: true))
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= VDAgent.maxChunk })

        var r = AgentReassembler()
        var got: [AgentFrame] = []
        for c in chunks { got += try r.push(c) }
        #expect(got.count == 1)
        guard case let .clipboard(_, type, data) = try AgentMessage(frame: got[0], hasSelection: true) else {
            Issue.record("not a clipboard message"); return
        }
        #expect(type == .utf8Text)
        #expect(data == big)
    }

    /// One MAIN_AGENT_DATA can carry the tail of one message and the head of the next, and a single
    /// byte at a time is the worst case of the same thing.
    @Test func reassemblesRegardlessOfWhereTheStreamIsCut() throws {
        let a = AgentMessage.clipboardRequest(.clipboard, .utf8Text)
        let b = AgentMessage.clipboard(.clipboard, .utf8Text, Array("xy".utf8))
        let bytes = stream(a) + stream(b)

        var whole = AgentReassembler()
        #expect(try whole.push(bytes).count == 2)

        var byByte = AgentReassembler()
        var got: [AgentFrame] = []
        for byte in bytes { got += try byByte.push([byte]) }
        #expect(got.count == 2)
        #expect(try AgentMessage(frame: got[0], hasSelection: true) == a)
        #expect(try AgentMessage(frame: got[1], hasSelection: true) == b)
    }

    @Test func emptyMessagesReassemble() throws {
        var r = AgentReassembler()
        let frames = try r.push(stream(.clipboardRelease(.clipboard), hasSelection: false))
        #expect(frames.count == 1)
        #expect(frames[0].payload.isEmpty)
    }

    // MARK: Hostile input

    @Test func rejectsAForeignProtocolVersion() {
        var w = SpiceWriter()
        w.u32(99); w.u32(4); w.u64(0); w.u32(0)
        var r = AgentReassembler()
        #expect(throws: WireError.self) { _ = try r.push(w.bytes) }
    }

    @Test func rejectsALengthItWouldHaveToAllocate() {
        var w = SpiceWriter()
        w.u32(VDAgent.version); w.u32(4); w.u64(0); w.u32(.max)
        var r = AgentReassembler()
        #expect(throws: WireError.self) { _ = try r.push(w.bytes) }
    }

    @Test func truncatedBodiesNeverYieldAFrame() throws {
        var r = AgentReassembler()
        let bytes = stream(.clipboard(.clipboard, .utf8Text, Array("hello".utf8)))
        #expect(try r.push(Array(bytes.dropLast())).isEmpty)
    }

    @Test func toleratesAGrabCarryingTypesItDoesNotKnow() throws {
        var w = SpiceWriter()
        w.u8(0); w.u8(0); w.u8(0); w.u8(0)
        w.u32(1)      // utf8
        w.u32(9999)   // not a type we model
        let m = try AgentMessage(frame: AgentFrame(type: AgentMsgType.clipboardGrab.rawValue, payload: w.bytes),
                                 hasSelection: true)
        #expect(m == .clipboardGrab(.clipboard, [.utf8Text]))
    }

    @Test func aReleaseWithNoSelectionPrefixStillDecodes() throws {
        let m = try AgentMessage(frame: AgentFrame(type: AgentMsgType.clipboardRelease.rawValue, payload: []),
                                 hasSelection: true)
        #expect(m == .clipboardRelease(.clipboard))
    }

    @Test func monitorsConfigMatchesTheCStructs() {
        // From Tools/agentref.c `monitors_config_1`: header(20) + num,flags + height,width,depth,x,y.
        let one = AgentMessage.monitorsConfig(
            flags: AgentMonitorsFlags.usePosition,
            monitors: [AgentMonitorConfig(width: 1920, height: 1080, depth: 32, x: 0, y: 0)])
        #expect(hex(stream(one)) ==
            "01000000" + "02000000" + "0000000000000000" + "1c000000"   // header: proto, type, opaque, size 28
            + "01000000" + "01000000"                                   // num_of_monitors, flags
            + "38040000" + "80070000" + "20000000" + "00000000" + "00000000")  // height, width, depth, x, y
    }

    @Test func sparseMonitorsConfigSendsDisabledHeadsAsZeros() {
        // From `monitors_config_sparse`: an all-zero VDAgentMonConfig is a disabled head.
        let sparse = AgentMessage.monitorsConfig(
            flags: AgentMonitorsFlags.usePosition,
            monitors: [AgentMonitorConfig(width: 2560, height: 1440, depth: 32, x: 0, y: 0),
                       AgentMonitorConfig(width: 0, height: 0, depth: 0, x: 0, y: 0)])
        #expect(hex(stream(sparse)) ==
            "01000000" + "02000000" + "0000000000000000" + "30000000"   // header: size 48
            + "02000000" + "01000000"                                   // num_of_monitors, flags
            + "a0050000" + "000a0000" + "20000000" + "00000000" + "00000000"  // 2560x1440 (height first)
            + "0000000000000000000000000000000000000000")               // disabled head: all zeros
    }
}
