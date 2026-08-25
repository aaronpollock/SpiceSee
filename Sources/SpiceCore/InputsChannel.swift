import os
import SpiceWire

/// The inputs channel: every key and pointer message the guest receives goes through here, in the
/// order it was called. The caller (SpiceSession's single input pump) serialises calls; this actor
/// owns the state the wire needs — held keys, buttons_state, motion flow control, guest lock keys.
public actor InputsChannel {
    public static let descriptor = ChannelDescriptor(type: .inputs, id: 0)
    private let reader: ChannelReader
    private let transport: any Transport
    private let loop: Task<Void, Never>
    private var pump: Task<Void, Never>?
    private let log = Logger(subsystem: "com.spicesee", category: "inputs")

    public private(set) var heldKeys: Set<XTScancode> = []
    /// nil until the guest reports its lock state in INPUTS_INIT or KEY_MODIFIERS.
    public private(set) var guestLockKeys: LockKeys?
    private var pendingCapsLock: Bool?
    private var buttons = MouseButtonState()
    private var throttle = MotionThrottle()
    /// Set once, from the server's link-reply caps: whether keys go out as the combined
    /// KEY_SCANCODE byte stream (what a real client sends when this is negotiated) or as the
    /// legacy KEY_DOWN/KEY_UP pair.
    private let serverSendsScancodes: Bool

    public static func clientCaps() -> CapabilitySet { CapabilitySet(bits: [InputsCap.keyScancode]) }

    public static func open(transport: any Transport, connectionID: UInt32, password: String?) async throws -> InputsChannel {
        let link: LinkResult
        do {
            link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: descriptor,
                                                   channelCaps: clientCaps(), password: password)
        } catch {
            await transport.close()
            throw error
        }
        let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: descriptor)
        let loop = Task { await reader.run(); await transport.close() }
        let channel = InputsChannel(reader: reader, transport: transport, loop: loop,
                                     serverSendsScancodes: link.serverChannelCaps.contains(InputsCap.keyScancode))
        await channel.startPump()
        return channel
    }

    private init(reader: ChannelReader, transport: any Transport, loop: Task<Void, Never>, serverSendsScancodes: Bool) {
        self.reader = reader; self.transport = transport; self.loop = loop; self.serverSendsScancodes = serverSendsScancodes
    }

    private func startPump() {
        let messages = reader.messages
        pump = Task { [weak self] in
            for await raw in messages {
                guard let self else { return }
                do { await self.handle(try InputsMessage(type: raw.type, payload: raw.payload)) }
                catch { self.log.error("inputs: drop type \(raw.type): \(String(describing: error))") }
            }
        }
    }

    private func handle(_ m: InputsMessage) async {
        switch m {
        case let .`init`(k), let .keyModifiers(k):
            guestLockKeys = k
            if let on = pendingCapsLock {
                pendingCapsLock = nil
                try? await setLockKeys(merging(on, into: k))
            }
        case .mouseMotionAck:
            if let p = throttle.acked() { try? await send(p) }
        case .other: break
        }
    }

    /// Feeds a server message as if it had arrived on the wire (tests only).
    func handleForTesting(_ m: InputsMessage) async { await handle(m) }

    // MARK: Keyboard

    public func keyDown(_ s: XTScancode) async throws {
        heldKeys.insert(s)
        try await sendKey(s, pressed: true)
    }
    public func keyUp(_ s: XTScancode) async throws {
        heldKeys.remove(s)
        try await sendKey(s, pressed: false)
    }
    /// On focus loss: the guest must not be left with a stuck modifier.
    public func releaseAllKeys() async throws {
        for s in heldKeys.sorted(by: { ($0.extended ? 256 : 0) + Int($0.code) < ($1.extended ? 256 : 0) + Int($1.code) }) {
            try await sendKey(s, pressed: false)
        }
        heldKeys = []
    }
    private func sendKey(_ s: XTScancode, pressed: Bool) async throws {
        if serverSendsScancodes {
            try await reader.send(type: InputsClientMsg.keyScancode.rawValue, payload: ClientMessage.keyScancode(s, pressed: pressed))
        } else {
            let type = pressed ? InputsClientMsg.keyDown : InputsClientMsg.keyUp
            let payload = pressed ? ClientMessage.keyDown(s) : ClientMessage.keyUp(s)
            try await reader.send(type: type.rawValue, payload: payload)
        }
    }
    public func setLockKeys(_ k: LockKeys) async throws {
        try await reader.send(type: InputsClientMsg.keyModifiers.rawValue, payload: ClientMessage.keyModifiers(k))
    }
    /// Caps lock is the only lock state macOS exposes; num and scroll keep what the guest reported.
    /// Before the guest has reported, sending would clear its num and scroll lock — spice-server takes
    /// KEY_MODIFIERS as the whole state — so the request is held and applied when INIT arrives.
    public func syncCapsLock(_ on: Bool) async throws {
        guard let k = guestLockKeys else { pendingCapsLock = on; return }
        try await setLockKeys(merging(on, into: k))
    }

    private func merging(_ capsLock: Bool, into keys: LockKeys) -> LockKeys {
        var k = keys
        if capsLock { k.insert(.capsLock) } else { k.remove(.capsLock) }
        return k
    }

    // MARK: Pointer

    public func mouseMotion(dx: Int32, dy: Int32) async throws {
        if let p = throttle.offer(.motion(dx: dx, dy: dy)) { try await send(p) }
    }
    public func mousePosition(x: UInt32, y: UInt32, displayID: UInt8) async throws {
        if let p = throttle.offer(.position(x: x, y: y, displayID: displayID)) { try await send(p) }
    }
    public func buttonDown(_ b: MouseButton) async throws {
        buttons.insert(b)
        try await reader.send(type: InputsClientMsg.mousePress.rawValue, payload: ClientMessage.mousePress(b, buttons: buttons))
    }
    public func buttonUp(_ b: MouseButton) async throws {
        buttons.remove(b)
        try await reader.send(type: InputsClientMsg.mouseRelease.rawValue, payload: ClientMessage.mouseRelease(b, buttons: buttons))
    }

    private func send(_ p: MotionThrottle.Pending) async throws {
        switch p {
        case let .motion(dx, dy):
            try await reader.send(type: InputsClientMsg.mouseMotion.rawValue, payload: ClientMessage.mouseMotion(dx: dx, dy: dy, buttons: buttons))
        case let .position(x, y, id):
            try await reader.send(type: InputsClientMsg.mousePosition.rawValue, payload: ClientMessage.mousePosition(x: x, y: y, buttons: buttons, displayID: id))
        }
    }

    public func close() async { loop.cancel(); await transport.close() }
}
