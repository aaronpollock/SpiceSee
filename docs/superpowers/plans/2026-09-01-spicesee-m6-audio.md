# SpiceSee M6 — Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guest audio plays through the Mac's speakers — Opus or raw PCM over the SPICE playback channel, paced to the mm clock, with the guest's volume/mute honoured and the toolbar mute made real.

**Architecture:** `SpiceWire.PlaybackMessages` parses the channel; `SpiceCore.PlaybackChannel` is a `CursorChannel`-shaped actor whose Opus capability the caller decides; `SpiceMedia.AudioPlayer` decodes (Apple's `AudioConverter` for Opus, direct conversion for S16) and gates late packets against the mm clock, emitting `AudioEvent`s; `SpiceSession` forwards them; the app's `AudioOutput` owns `AVAudioEngine → AVAudioPlayerNode` and schedules buffers behind a ~50 ms prebuffer. Frames cross the seam as `[Float]`, like video frames cross as `[UInt8]`.

**Tech Stack:** Swift 6 strict concurrency, AudioToolbox (`kAudioFormatOpus` via `AudioConverter` — no vendored codec), AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, manual rendering mode for tests), Homebrew libopus **only** as the fixture generator (`Tools/opusref.c`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-01-spicesee-m6-audio-design.md`. One addition discovered while planning: exit criterion 1 wants the probe's log to show `MODE=OPUS`, but the spec's `AudioEvent.started` carries only rate and channels — so `started` gains an `opus: Bool` field (SpiceMedia and seam alike). Spike facts the plan relies on: Apple's converter decodes libopus 1.6.1 packets at both 960- and 480-sample frame sizes with `mFramesPerPacket = 0`, returning 47 880 frames for 48 000 encoded (the 120-sample Opus pre-skip is applied by the decoder) at RMS 0.353 for a 0.5-amplitude sine.

## Global Constraints

- Swift 6 strict concurrency; **no locks, no `@unchecked Sendable`, no `nonisolated(unsafe)`**. Audio never runs on a realtime render thread — `AVAudioPlayerNode.scheduleBuffer` from the main actor only.
- `SpiceWire` is the security boundary: every reader accessor throws; no `!` unwraps or unchecked subscripts on wire data.
- The `SessionBackend` seam rule: no SPICE/SpiceMedia type in `SessionBackend.swift`, `SessionModel.swift`, `AudioOutput.swift` or any view. Views are not edited in this milestone — `session.muted` is already bound by the toolbar.
- Wire layouts are checked against spice-gtk (`channel-playback.c`) / `spice.proto`, not transcribed by eye: `PLAYBACK_DATA {u32 time; u8 data[]}`, `PLAYBACK_MODE {u32 time; u16 mode; u8 data[]}`, `PLAYBACK_START {u32 channels; u16 format; u32 frequency; u32 time}`, `PLAYBACK_STOP {}`, `PLAYBACK_VOLUME {u8 nchannels; u16 volume[nchannels]}`, `PLAYBACK_MUTE {u8 mute}`, `PLAYBACK_LATENCY {u32 latency_ms}`. Message ids 101…107 in that order. Caps: `CELT_0_5_1 = 0, VOLUME = 1, LATENCY = 2, OPUS = 3` (`spice/protocol.h`). `SPICE_AUDIO_DATA_MODE`: RAW = 1, CELT = 2, OPUS = 3; `SPICE_AUDIO_FMT_S16 = 1`.
- The Opus capability is advertised **only** when `OpusDecoder.isAvailable()` passes at connect time. CELT is never advertised. The record channel stays unopened.
- Late-packet rule is the video rule: more than 80 ms behind the mm clock → counted and dropped **before** decode. No other jitter handling in the engine; the output's ~50 ms prebuffer is the jitter target.
- Fixtures are cross-implementation: encoded by libopus (`Tools/opusref.c`), decoded by Apple. Never test the decoder against its own encoder.
- Library code logs via `os.Logger(subsystem: "com.spicesee", category:)`; no `print` outside executables. Conventional commits; Swift Testing.
- After adding files under `Sources/SpiceSee/` or `Tests/SpiceSeeTests/`: `xcodegen generate`, build the `SpiceSee` scheme once (the test bundle resolves `@testable import SpiceSee` against it), then `xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test`. Engine: `swift test`.

## File Structure

| File | Role |
|---|---|
| `Sources/SpiceWire/PlaybackMessages.swift` (new) | `PlaybackServerMsg`, `PlaybackCap`, `AudioDataMode`, `PlaybackStart`, `PlaybackMessage` |
| `Sources/SpiceCore/PlaybackChannel.swift` (new) | channel actor with caller-supplied caps |
| `Sources/SpiceMedia/OpusDecoder.swift` (new) | `AudioConverter` wrapper + `isAvailable()` probe |
| `Sources/SpiceMedia/AudioPlayer.swift` (new) | `AudioEvent`, decode + late-gate actor |
| `Tools/opusref.c` (new) | libopus fixture generator |
| `Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin` (new) | 100 × 480-frame packets, 440 Hz, amplitude 0.5 |
| `Package.swift` | `SpiceMediaTests` gains `resources: [.copy("Fixtures")]` |
| `Sources/SpiceKit/SpiceSession.swift` | opens `PlaybackChannel`, pumps `AudioPlayer`, `SessionEvent.audio` |
| `Sources/SpiceSee/SessionBackend.swift` | seam `AudioEvent`, `BackendEvent.audio` |
| `Sources/SpiceSee/AudioOutput.swift` (new) | `AVAudioEngine`/`AVAudioPlayerNode`, prebuffer, two volume controls |
| `Sources/SpiceSee/SessionModel.swift` | owns `AudioOutput`; `muted` forwards |
| `Sources/SpiceSee/SpiceKitBackend.swift`, `MockSessionBackend.swift` | translate; mock tone |
| `Sources/spicesee-cli/main.swift` | `audio` probe → WAV |
| `docs/dev-server.md`, `CLAUDE.md` | exit checks; architecture notes |

Tests: `Tests/SpiceWireTests/PlaybackMessageTests.swift`, `Tests/SpiceCoreTests/PlaybackChannelTests.swift`, `Tests/SpiceMediaTests/OpusDecoderTests.swift`, `Tests/SpiceMediaTests/AudioPlayerTests.swift`, `Tests/SpiceMediaTests/TestSupport.swift` (fixture loader), `Tests/SpiceKitTests/AudioSessionTests.swift`, `Tests/SpiceSeeTests/AudioOutputTests.swift`.

---

### Task 1: `PlaybackMessages` — the wire types

**Files:**
- Create: `Sources/SpiceWire/PlaybackMessages.swift`
- Test: `Tests/SpiceWireTests/PlaybackMessageTests.swift`

**Interfaces:**
- Produces:

```swift
public enum PlaybackServerMsg: UInt16, Sendable { case data = 101, mode, start, stop, volume, mute, latency }
public enum PlaybackCap { public static let celt051: UInt32 = 0, volume: UInt32 = 1, latency: UInt32 = 2, opus: UInt32 = 3 }
public enum AudioDataMode: UInt16, Sendable { case raw = 1, celt051 = 2, opus = 3 }
public enum AudioFormat { public static let s16: UInt16 = 1 }
public struct PlaybackStart: Sendable, Equatable { public var channels: UInt32, format: UInt16, frequency: UInt32, time: UInt32 }
public enum PlaybackMessage: Sendable, Equatable {
    case data(time: UInt32, payload: [UInt8])
    case mode(time: UInt32, mode: UInt16)          // raw value: an unknown mode is the consumer's to reject
    case start(PlaybackStart)
    case stop
    case volume([UInt16])
    case mute(Bool)
    case latency(ms: UInt32)
    case other(type: UInt16)
    public init(type: UInt16, payload: [UInt8]) throws
}
```

- [ ] **Step 1: Write the failing tests** — `Tests/SpiceWireTests/PlaybackMessageTests.swift`:

```swift
import Testing
@testable import SpiceWire

/// Layouts follow spice.proto / spice-gtk channel-playback.c; ids 101…107.
@Suite struct PlaybackMessageTests {
    @Test func startParsesChannelsFormatFrequencyTime() throws {
        var w = SpiceWriter(); w.u32(2); w.u16(AudioFormat.s16); w.u32(48000); w.u32(1234)
        let m = try PlaybackMessage(type: PlaybackServerMsg.start.rawValue, payload: w.bytes)
        #expect(m == .start(PlaybackStart(channels: 2, format: AudioFormat.s16, frequency: 48000, time: 1234)))
    }

    @Test func modeCarriesTimeAndRawMode() throws {
        var w = SpiceWriter(); w.u32(99); w.u16(AudioDataMode.opus.rawValue)
        #expect(try PlaybackMessage(type: PlaybackServerMsg.mode.rawValue, payload: w.bytes) == .mode(time: 99, mode: 3))
    }

    @Test func dataIsTimeThenTheRestOfTheMessage() throws {
        var w = SpiceWriter(); w.u32(7); w.bytes([1, 2, 3])
        #expect(try PlaybackMessage(type: PlaybackServerMsg.data.rawValue, payload: w.bytes) == .data(time: 7, payload: [1, 2, 3]))
    }

    @Test func volumeIsCountedU16s() throws {
        var w = SpiceWriter(); w.u8(2); w.u16(65535); w.u16(0)
        #expect(try PlaybackMessage(type: PlaybackServerMsg.volume.rawValue, payload: w.bytes) == .volume([65535, 0]))
    }

    @Test func muteStopLatency() throws {
        #expect(try PlaybackMessage(type: PlaybackServerMsg.mute.rawValue, payload: [1]) == .mute(true))
        #expect(try PlaybackMessage(type: PlaybackServerMsg.stop.rawValue, payload: []) == .stop)
        var w = SpiceWriter(); w.u32(40)
        #expect(try PlaybackMessage(type: PlaybackServerMsg.latency.rawValue, payload: w.bytes) == .latency(ms: 40))
    }

    @Test func truncatedPayloadsThrowRatherThanTrap() {
        #expect(throws: (any Error).self) { try PlaybackMessage(type: PlaybackServerMsg.start.rawValue, payload: [0, 0, 0]) }
        #expect(throws: (any Error).self) { try PlaybackMessage(type: PlaybackServerMsg.data.rawValue, payload: [0, 0]) }
        // VOLUME announcing more channels than bytes follow.
        #expect(throws: (any Error).self) { try PlaybackMessage(type: PlaybackServerMsg.volume.rawValue, payload: [3, 0, 0]) }
    }

    @Test func unknownTypeIsOther() throws {
        #expect(try PlaybackMessage(type: 150, payload: [9]) == .other(type: 150))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PlaybackMessageTests`
Expected: FAIL — `PlaybackMessage` undefined.

- [ ] **Step 3: Implement** `Sources/SpiceWire/PlaybackMessages.swift`:

```swift
/// The playback channel (`spice.proto` PlaybackChannel), server → client. Ids start at 101 like
/// every channel's first message; layouts follow spice-gtk's channel-playback.c.
public enum PlaybackServerMsg: UInt16, Sendable {
    case data = 101, mode, start, stop, volume, mute, latency
}

/// `SPICE_PLAYBACK_CAP_*` from spice/protocol.h.
public enum PlaybackCap {
    public static let celt051: UInt32 = 0, volume: UInt32 = 1, latency: UInt32 = 2, opus: UInt32 = 3
}

/// `SPICE_AUDIO_DATA_MODE_*`; 0 is INVALID and deliberately absent.
public enum AudioDataMode: UInt16, Sendable { case raw = 1, celt051 = 2, opus = 3 }

/// `SPICE_AUDIO_FMT_*`; S16 is the only format the protocol defines.
public enum AudioFormat { public static let s16: UInt16 = 1 }

public struct PlaybackStart: Sendable, Equatable {
    public var channels: UInt32, format: UInt16, frequency: UInt32, time: UInt32
    public init(channels: UInt32, format: UInt16, frequency: UInt32, time: UInt32) {
        self.channels = channels; self.format = format; self.frequency = frequency; self.time = time
    }
    init(reader r: inout SpiceReader) throws {
        channels = try r.u32(); format = try r.u16(); frequency = try r.u32(); time = try r.u32()
    }
}

public enum PlaybackMessage: Sendable, Equatable {
    case data(time: UInt32, payload: [UInt8])
    /// `mode` is the raw `SPICE_AUDIO_DATA_MODE` value: rejecting an unknown or unsupported codec is
    /// the consumer's decision, not a parse failure.
    case mode(time: UInt32, mode: UInt16)
    case start(PlaybackStart)
    case stop
    case volume([UInt16])
    case mute(Bool)
    case latency(ms: UInt32)
    case other(type: UInt16)

    public init(type: UInt16, payload: [UInt8]) throws {
        var r = SpiceReader(payload)
        switch PlaybackServerMsg(rawValue: type) {
        case .data:
            let time = try r.u32()
            self = .data(time: time, payload: try r.bytes(r.remaining))
        case .mode:
            let time = try r.u32()
            self = .mode(time: time, mode: try r.u16())
        case .start: self = .start(try PlaybackStart(reader: &r))
        case .stop: self = .stop
        case .volume:
            let n = Int(try r.u8())
            self = .volume(try (0 ..< n).map { _ in try r.u16() })
        case .mute: self = .mute(try r.u8() != 0)
        case .latency: self = .latency(ms: try r.u32())
        case nil: self = .other(type: type)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter PlaybackMessageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceWire/PlaybackMessages.swift Tests/SpiceWireTests/PlaybackMessageTests.swift
git commit -m "feat: parse the playback channel's messages"
```

---

### Task 2: `PlaybackChannel` actor

**Files:**
- Create: `Sources/SpiceCore/PlaybackChannel.swift`
- Test: `Tests/SpiceCoreTests/PlaybackChannelTests.swift`

**Interfaces:**
- Consumes: `PlaybackMessage`, `PlaybackServerMsg` (Task 1).
- Produces: `public actor PlaybackChannel { public nonisolated let messages: AsyncStream<PlaybackMessage>; public static func open(transport:connectionID:id:password:caps: CapabilitySet) async throws -> PlaybackChannel; public func close() async }`.

The only difference from `CursorChannel` (read `Sources/SpiceCore/CursorChannel.swift` first — this is a copy with a caps parameter): `channelCaps` comes from the caller, because whether to announce Opus depends on a device probe SpiceCore must not perform.

- [ ] **Step 1: Write the failing test** — `Tests/SpiceCoreTests/PlaybackChannelTests.swift`:

```swift
import Foundation
import Testing
import SpiceWire
@testable import SpiceCore

@Test func playbackChannelStreamsParsedMessagesAndDropsMalformedOnes() async throws {
    var mode = SpiceWriter(); mode.u32(0); mode.u16(AudioDataMode.raw.rawValue)
    var start = SpiceWriter(); start.u32(2); start.u16(AudioFormat.s16); start.u32(48000); start.u32(5)
    var data = SpiceWriter(); data.u32(5); data.bytes([0, 0, 0xFF, 0x7F])
    let body = frame(PlaybackServerMsg.mode.rawValue, mode.bytes)
             + frame(PlaybackServerMsg.start.rawValue, start.bytes)
             + frame(PlaybackServerMsg.data.rawValue, data.bytes)
             + frame(PlaybackServerMsg.start.rawValue, [1, 2])          // truncated: dropped, not fatal
             + frame(PlaybackServerMsg.stop.rawValue, [])
    let t = InMemoryTransport(input: try fakeLink(body: body))
    let ch = try await PlaybackChannel.open(transport: t, connectionID: 1, id: 0, password: nil,
                                            caps: CapabilitySet(bits: [PlaybackCap.volume]))
    var got: [PlaybackMessage] = []
    for await m in ch.messages { got.append(m) }
    #expect(got == [.mode(time: 0, mode: 1),
                    .start(PlaybackStart(channels: 2, format: 1, frequency: 48000, time: 5)),
                    .data(time: 5, payload: [0, 0, 0xFF, 0x7F]),
                    .stop])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter playbackChannelStreamsParsedMessagesAndDropsMalformedOnes`
Expected: FAIL — `PlaybackChannel` undefined.

- [ ] **Step 3: Implement** `Sources/SpiceCore/PlaybackChannel.swift`:

```swift
import os
import SpiceWire

/// The playback channel: link, then a pump that parses each frame into a `PlaybackMessage`.
/// `caps` is the caller's: the Opus bit depends on a decoder probe that belongs to SpiceMedia.
public actor PlaybackChannel {
    public nonisolated let messages: AsyncStream<PlaybackMessage>
    private let reader: ChannelReader
    private let transport: any Transport
    private let loop: Task<Void, Never>
    private let pump: Task<Void, Never>

    public static func open(transport: any Transport, connectionID: UInt32, id: UInt8, password: String?,
                            caps: CapabilitySet) async throws -> PlaybackChannel {
        let desc = ChannelDescriptor(type: .playback, id: id)
        do {
            let link = try await LinkHandshake.perform(on: transport, connectionID: connectionID, channel: desc,
                                                       channelCaps: caps, password: password)
            let reader = ChannelReader(source: transport, sink: transport, miniHeader: link.miniHeader, channel: desc)
            let loop = Task { await reader.run(); await transport.close() }
            return PlaybackChannel(reader: reader, transport: transport, loop: loop, descriptor: desc)
        } catch {
            await transport.close()
            throw error
        }
    }

    private init(reader: ChannelReader, transport: any Transport, loop: Task<Void, Never>, descriptor: ChannelDescriptor) {
        self.reader = reader; self.transport = transport; self.loop = loop
        let (stream, cont) = AsyncStream.makeStream(of: PlaybackMessage.self, bufferingPolicy: .unbounded)
        messages = stream
        let log = Logger(subsystem: "com.spicesee", category: "playback")
        let source = reader.messages
        pump = Task {
            for await raw in source {
                do { cont.yield(try PlaybackMessage(type: raw.type, payload: raw.payload)) }
                catch { log.error("playback/\(descriptor.id): drop type \(raw.type): \(String(describing: error), privacy: .public)") }
            }
            cont.finish()
        }
    }

    public func close() async { loop.cancel(); await transport.close() }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter playbackChannelStreamsParsedMessagesAndDropsMalformedOnes`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceCore/PlaybackChannel.swift Tests/SpiceCoreTests/PlaybackChannelTests.swift
git commit -m "feat: PlaybackChannel actor with caller-decided capabilities"
```

---

### Task 3: `OpusDecoder` and the libopus fixture

**Files:**
- Create: `Tools/opusref.c`
- Create: `Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin` (generated, committed)
- Modify: `Package.swift` (SpiceMediaTests resources)
- Create: `Sources/SpiceMedia/OpusDecoder.swift`
- Modify: `Tests/SpiceMediaTests/TestSupport.swift` (fixture loader)
- Test: `Tests/SpiceMediaTests/OpusDecoderTests.swift`

**Interfaces:**
- Produces:

```swift
public final class OpusDecoder {                      // actor-confined like VideoDecoder; not Sendable
    public static func isAvailable(sampleRate: Double = 48000, channels: Int = 2) -> Bool
    public init(sampleRate: Double, channels: Int) throws
    public func decode(_ packet: [UInt8]) throws -> [Float]   // interleaved Float32; may be shorter than a full frame (pre-skip)
}
public struct AudioDecodeError: Error, Sendable { public var status: Int32 }
// tests:
func opusFixturePackets() throws -> [[UInt8]]        // in SpiceMediaTests/TestSupport.swift
```

The fixture framing is `[u32 LE length][bytes]` per packet. Encoder settings: 48 kHz stereo, 480-frame (10 ms) packets — SPICE's own frame size (`SND_CODEC_OPUS_FRAME_SIZE`) — 100 packets, 440 Hz sine at amplitude 0.5 on both channels, 96 kbps, `OPUS_APPLICATION_AUDIO`.

- [ ] **Step 1: Write and run the fixture generator** — `Tools/opusref.c`:

```c
// Encodes the M6 audio fixture with libopus (a real, independent encoder) so Apple's decoder is
// tested against something it did not produce. Framing: [u32 LE length][packet bytes] × 100.
//   cc -I$(brew --prefix opus)/include -L$(brew --prefix opus)/lib -lopus -lm -o /tmp/opusref Tools/opusref.c
//   /tmp/opusref Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin
#include <opus/opus.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define FRAMES 480          /* SPICE's SND_CODEC_OPUS_FRAME_SIZE: 10 ms at 48 kHz */
#define PACKETS 100

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: opusref <out.bin>\n"); return 2; }
    int err = 0;
    OpusEncoder *enc = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err);
    if (err != OPUS_OK) { fprintf(stderr, "encoder: %s\n", opus_strerror(err)); return 1; }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(96000));
    FILE *out = fopen(argv[1], "wb");
    if (!out) { perror(argv[1]); return 1; }
    int16_t pcm[FRAMES * 2];
    unsigned char buf[4000];
    double phase = 0;
    for (int p = 0; p < PACKETS; p++) {
        for (int i = 0; i < FRAMES; i++) {
            int16_t s = (int16_t)(0.5 * 32767 * sin(phase));
            pcm[i * 2] = s; pcm[i * 2 + 1] = s;
            phase += 2 * M_PI * 440.0 / 48000.0;
        }
        int n = opus_encode(enc, pcm, FRAMES, buf, sizeof buf);
        if (n < 0) { fprintf(stderr, "encode: %s\n", opus_strerror(n)); return 1; }
        uint32_t len = (uint32_t)n;
        fwrite(&len, 4, 1, out); fwrite(buf, 1, n, out);
    }
    fclose(out);
    printf("wrote %d packets of %d frames with %s\n", PACKETS, FRAMES, opus_get_version_string());
    return 0;
}
```

Run:
```bash
mkdir -p Tests/SpiceMediaTests/Fixtures
cc -I$(brew --prefix opus)/include -L$(brew --prefix opus)/lib -lopus -lm -o /tmp/opusref Tools/opusref.c && /tmp/opusref Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin
```
Expected: `wrote 100 packets of 480 frames with libopus 1.6.1` (version may differ; record it in the commit message). Then in `Package.swift` change the SpiceMediaTests line to `.testTarget(name: "SpiceMediaTests", dependencies: ["SpiceMedia", "SpiceWire"], resources: [.copy("Fixtures")]),`.

- [ ] **Step 2: Fixture loader** — append to `Tests/SpiceMediaTests/TestSupport.swift`:

```swift
/// The libopus-encoded tone from `Tools/opusref.c`: `[u32 LE length][bytes]` × 100.
func opusFixturePackets() throws -> [[UInt8]] {
    let url = try #require(Bundle.module.url(forResource: "tone-48k-stereo.opus", withExtension: "bin", subdirectory: "Fixtures"))
    let data = [UInt8](try Data(contentsOf: url))
    var packets: [[UInt8]] = []
    var i = 0
    while i + 4 <= data.count {
        let len = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
        i += 4
        guard i + len <= data.count else { break }
        packets.append(Array(data[i ..< i + len])); i += len
    }
    return packets
}
```
(Add `import Foundation` and `import Testing` at the top of the file if missing — `#require` needs Testing.)

- [ ] **Step 3: Write the failing tests** — `Tests/SpiceMediaTests/OpusDecoderTests.swift`:

```swift
import Testing
@testable import SpiceMedia

/// Apple's Opus decoder checked against libopus's encoder — never against itself.
@Suite struct OpusDecoderTests {
    @Test func opusIsAvailableOnThisMac() {
        #expect(OpusDecoder.isAvailable())
    }

    @Test func decodesTheLibopusToneFrameAccurate() throws {
        let decoder = try OpusDecoder(sampleRate: 48000, channels: 2)
        var frames = 0
        var sumSq = 0.0
        for packet in try opusFixturePackets() {
            let pcm = try decoder.decode(packet)
            frames += pcm.count / 2
            for s in pcm { sumSq += Double(s * s) }
        }
        // 100 × 480 encoded; the decoder applies Opus's 120-sample pre-skip itself.
        #expect(frames == 48000 - 120)
        let rms = (sumSq / Double(frames * 2)).squareRoot()
        #expect(abs(rms - 0.354) < 0.004)      // 0.5-amplitude sine → 0.5/√2, within 1 %
    }

    @Test func garbageIsAnErrorNotATrap() throws {
        let decoder = try OpusDecoder(sampleRate: 48000, channels: 2)
        // Either an error or an empty result is acceptable; a crash is not.
        _ = try? decoder.decode([0xFF, 0x00, 0x13, 0x37])
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `swift test --filter OpusDecoderTests`
Expected: FAIL — `OpusDecoder` undefined.

- [ ] **Step 5: Implement** `Sources/SpiceMedia/OpusDecoder.swift`:

```swift
import AudioToolbox
import os

public struct AudioDecodeError: Error, Sendable { public var status: Int32 }

/// Opus → Float32 PCM through AudioToolbox — Apple ships the decoder, so nothing is vendored.
/// One converter per stream (recreated on every PLAYBACK_START), fed one packet per `decode`.
/// Actor-confined by its owner; not Sendable, like `VideoDecoder`.
public final class OpusDecoder {
    /// Returned by the input callback once its single packet is consumed. Fill then returns it too,
    /// with whatever frames were decoded; that is success here, not failure.
    private static let noMoreData: OSStatus = 0x6E6F6D6F   // 'nomo'

    private let converter: AudioConverterRef
    private let channels: Int
    private let maxFrames = 5760                          // Opus's largest frame: 120 ms at 48 kHz

    /// Whether this macOS decodes Opus. False → the caller must not advertise the capability.
    public static func isAvailable(sampleRate: Double = 48000, channels: Int = 2) -> Bool {
        var input = Self.opusFormat(sampleRate: sampleRate, channels: channels)
        var output = Self.pcmFormat(sampleRate: sampleRate, channels: channels)
        var ref: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &ref) == noErr, let ref else { return false }
        AudioConverterDispose(ref)
        return true
    }

    public init(sampleRate: Double, channels: Int) throws {
        var input = Self.opusFormat(sampleRate: sampleRate, channels: channels)
        var output = Self.pcmFormat(sampleRate: sampleRate, channels: channels)
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &ref)
        guard status == noErr, let ref else { throw AudioDecodeError(status: status) }
        converter = ref
        self.channels = channels
    }

    deinit { AudioConverterDispose(converter) }

    private static func opusFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        // mFramesPerPacket 0 = variable: SPICE sends 480-frame packets, libopus fixtures may differ,
        // and the spike showed the decoder needs no hint either way.
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                    mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
    }

    private static func pcmFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytes = UInt32(channels * 4)
        return AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                           mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    /// One packet in, its interleaved Float32 frames out. The first packet of a stream comes back
    /// short by the pre-skip; garbage comes back as an error or as nothing.
    public func decode(_ packet: [UInt8]) throws -> [Float] {
        final class Feed { var packet: [UInt8]; var consumed = false; var desc = AudioStreamPacketDescription()
            init(_ p: [UInt8]) { packet = p } }
        let feed = Feed(packet)
        let input: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, userData in
            let feed = Unmanaged<Feed>.fromOpaque(userData!).takeUnretainedValue()
            guard !feed.consumed else { ioPackets.pointee = 0; return OpusDecoder.noMoreData }
            feed.consumed = true
            feed.packet.withUnsafeMutableBufferPointer { p in
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(p.baseAddress)
                ioData.pointee.mBuffers.mDataByteSize = UInt32(p.count)
                ioData.pointee.mBuffers.mNumberChannels = 0
            }
            feed.desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(feed.packet.count))
            outDesc?.pointee = withUnsafeMutablePointer(to: &feed.desc) { $0 }
            ioPackets.pointee = 1
            return noErr
        }
        var out = [Float](repeating: 0, count: maxFrames * channels)
        var frames = UInt32(maxFrames)
        let status: OSStatus = out.withUnsafeMutableBufferPointer { p in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(p.count * 4), mData: UnsafeMutableRawPointer(p.baseAddress)))
            return AudioConverterFillComplexBuffer(converter, input, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == Self.noMoreData else { throw AudioDecodeError(status: status) }
        return Array(out.prefix(Int(frames) * channels))
    }
}
```

`packet.withUnsafeMutableBufferPointer` inside the callback: the `Feed` object keeps the array alive for the duration of the Fill call, which is the only time the converter reads it. If Swift 6 rejects the closure capturing `feed` through `userData` for concurrency reasons, the C-convention closure has no captures — all state travels through `userData` — which is the accepted shape.

- [ ] **Step 6: Run to verify it passes**

Run: `swift test --filter OpusDecoderTests`
Expected: PASS — including the exact `48000 - 120` frame count and RMS within 1 %.

- [ ] **Step 7: Commit**

```bash
git add Tools/opusref.c Tests/SpiceMediaTests/Fixtures Package.swift Sources/SpiceMedia/OpusDecoder.swift Tests/SpiceMediaTests
git commit -m "feat: OpusDecoder over AudioToolbox, tested against a libopus-encoded fixture"
```

---

### Task 4: `AudioPlayer` — decode, late-gate, events

**Files:**
- Create: `Sources/SpiceMedia/AudioPlayer.swift`
- Test: `Tests/SpiceMediaTests/AudioPlayerTests.swift`

**Interfaces:**
- Consumes: `PlaybackMessage`, `AudioDataMode`, `AudioFormat` (Task 1); `OpusDecoder` (Task 3).
- Produces:

```swift
public enum AudioEvent: Sendable, Equatable {
    case started(sampleRate: Int, channels: Int, opus: Bool)
    case pcm(frames: [Float], mmTime: UInt32)     // interleaved
    case volume([Float])                          // 0…1 per channel
    case mute(Bool)
    case stopped
}
public actor AudioPlayer {
    public nonisolated let events: AsyncStream<AudioEvent>
    public init(opusAvailable: Bool)
    public func setMMTime(_ serverTime: UInt32)
    public func handle(_ message: PlaybackMessage)
    public func finish()
    private(set) var decodeAttempts: UInt32     // internal, test-only (as in StreamPlayer)
    private(set) var droppedLate: UInt32
}
```

Semantics: `MODE` records the codec (raw/opus; CELT or unknown → logged once, all data dropped). `START` records rate/channels, (re)creates the decoder when the mode is Opus and Opus is available, emits `.started`. `DATA` before `START` is dropped. A packet more than 80 ms behind `serverNow()` is counted in `droppedLate` and never decoded. Raw S16 LE → `Float(sample) / 32768`. Opus → `decoder.decode`; a throw skips the packet. `VOLUME` → `Float(v) / 65535`. `STOP` → `.stopped`, decoder released.

- [ ] **Step 1: Write the failing tests** — `Tests/SpiceMediaTests/AudioPlayerTests.swift`:

```swift
import Testing
import SpiceWire
@testable import SpiceMedia

private func start(_ rate: UInt32 = 48000, channels: UInt32 = 2) -> PlaybackMessage {
    .start(PlaybackStart(channels: channels, format: AudioFormat.s16, frequency: rate, time: 0))
}

private func s16(_ samples: [Int16]) -> [UInt8] {
    samples.flatMap { let u = UInt16(bitPattern: $0); return [UInt8(u & 0xFF), UInt8(u >> 8)] }
}

private func drain(_ p: AudioPlayer) async -> [AudioEvent] {
    await p.finish()
    var out: [AudioEvent] = []
    for await e in p.events { out.append(e) }
    return out
}

@Test func startAnnouncesFormatAndCodec() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    #expect(await drain(p) == [.started(sampleRate: 48000, channels: 2, opus: true)])
}

@Test func rawS16ConvertsExactly() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 0, payload: s16([0, 32767, -32768, 16384])))
    let events = await drain(p)
    guard case let .pcm(frames, mmTime)? = events.last else { Issue.record("no pcm: \(events)"); return }
    #expect(mmTime == 0)
    #expect(frames == [0, 32767 / 32768, -1, 0.5])
}

@Test func latePacketsDropBeforeDecode() async throws {
    let p = AudioPlayer(opusAvailable: true)
    await p.setMMTime(10_000)
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 5_000, payload: [0xFF, 0xFF, 0xFF]))       // 5 s late and garbage: never decoded
    #expect(await p.decodeAttempts == 0)
    #expect(await p.droppedLate == 1)
    await p.handle(.data(time: 10_000, payload: try opusFixturePackets()[0]))
    #expect(await p.decodeAttempts == 1)
}

@Test func theLibopusToneDecodesThroughThePlayer() async throws {
    let p = AudioPlayer(opusAvailable: true)          // no setMMTime: nothing can be late
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    for (i, packet) in try opusFixturePackets().enumerated() { await p.handle(.data(time: UInt32(i * 10), payload: packet)) }
    let frames = await drain(p).reduce(0) { n, e in if case let .pcm(f, _) = e { return n + f.count / 2 }; return n }
    #expect(frames == 48000 - 120)
}

@Test func volumeAndMuteMapToTheSeam() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.volume([65535, 0]))
    await p.handle(.mute(true))
    #expect(await drain(p) == [.volume([1, 0]), .mute(true)])
}

@Test func stopEmitsStopped() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(start())
    await p.handle(.stop)
    #expect(await drain(p) == [.started(sampleRate: 48000, channels: 2, opus: false), .stopped])
}

@Test func opusUnavailableDropsOpusButRawStillPlays() async throws {
    let p = AudioPlayer(opusAvailable: false)
    await p.handle(.mode(time: 0, mode: AudioDataMode.opus.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 0, payload: try opusFixturePackets()[0]))
    await p.handle(.stop)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(start())
    await p.handle(.data(time: 0, payload: s16([100, -100])))
    let pcm = await drain(p).filter { if case .pcm = $0 { return true }; return false }
    #expect(pcm.count == 1)                            // only the raw packet made it
}

@Test func dataBeforeStartIsDropped() async {
    let p = AudioPlayer(opusAvailable: true)
    await p.handle(.mode(time: 0, mode: AudioDataMode.raw.rawValue))
    await p.handle(.data(time: 0, payload: s16([1, 2])))
    #expect(await drain(p).isEmpty)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter AudioPlayerTests`
Expected: FAIL — `AudioPlayer` / `AudioEvent` undefined.

- [ ] **Step 3: Implement** `Sources/SpiceMedia/AudioPlayer.swift`:

```swift
import os
import SpiceWire

/// The video rule, reused: a packet this far behind the mm clock is dropped before decode.
private let maxLatenessMs: Int64 = 80

public enum AudioEvent: Sendable, Equatable {
    case started(sampleRate: Int, channels: Int, opus: Bool)
    case pcm(frames: [Float], mmTime: UInt32)
    case volume([Float])
    case mute(Bool)
    case stopped
}

/// Decodes the playback channel into Float32 frames and gates late packets against the mm clock.
/// A pure decode-and-gate stage: it holds no jitter buffer, so the output owns the ~50 ms
/// prebuffer, and a test can drive this actor with a synthetic clock.
public actor AudioPlayer {
    public nonisolated let events: AsyncStream<AudioEvent>
    private let cont: AsyncStream<AudioEvent>.Continuation
    private let opusAvailable: Bool
    private var mode: AudioDataMode?
    private var unsupportedModeLogged = false
    private var format: (sampleRate: Int, channels: Int)?
    private var decoder: OpusDecoder?
    private var mmBase: (serverTime: UInt32, at: ContinuousClock.Instant)?
    private let log = Logger(subsystem: "com.spicesee", category: "audio")

    /// Test-only counters — `internal`, reachable through `@testable import` only. Frame counts
    /// alone cannot separate "dropped before decode" from "decoded and threw".
    private(set) var decodeAttempts: UInt32 = 0
    private(set) var droppedLate: UInt32 = 0

    public init(opusAvailable: Bool) {
        self.opusAvailable = opusAvailable
        (events, cont) = AsyncStream.makeStream(of: AudioEvent.self, bufferingPolicy: .unbounded)
    }

    public func finish() { cont.finish() }

    public func setMMTime(_ serverTime: UInt32) { mmBase = (serverTime, .now) }

    private func serverNow() -> UInt32? {
        guard let mmBase else { return nil }
        let elapsedMs = mmBase.at.duration(to: .now).milliseconds
        return mmBase.serverTime &+ UInt32(clamping: elapsedMs)
    }

    public func handle(_ message: PlaybackMessage) {
        switch message {
        case let .mode(_, raw):
            mode = AudioDataMode(rawValue: raw)
            if mode == nil || mode == .celt051, !unsupportedModeLogged {
                log.notice("playback: unsupported audio mode \(raw); dropping data")
                unsupportedModeLogged = true
            }
        case let .start(s):
            format = (Int(s.frequency), Int(s.channels))
            decoder = nil
            let usesOpus = mode == .opus
            if usesOpus, opusAvailable {
                do { decoder = try OpusDecoder(sampleRate: Double(s.frequency), channels: Int(s.channels)) }
                catch { log.error("playback: Opus decoder unavailable: \(String(describing: error), privacy: .public); dropping Opus data") }
            }
            cont.yield(.started(sampleRate: Int(s.frequency), channels: Int(s.channels), opus: usesOpus))
        case let .data(time, payload):
            guard format != nil, let mode else { return }
            if let now = serverNow(), Int64(now) - Int64(time) > maxLatenessMs { droppedLate += 1; return }
            switch mode {
            case .raw:
                cont.yield(.pcm(frames: Self.floats(fromS16: payload), mmTime: time))
            case .opus:
                guard let decoder else { return }
                decodeAttempts += 1
                do {
                    let frames = try decoder.decode(payload)
                    if !frames.isEmpty { cont.yield(.pcm(frames: frames, mmTime: time)) }
                } catch { log.error("playback: Opus decode failed: \(String(describing: error), privacy: .public); packet skipped") }
            case .celt051:
                break
            }
        case let .volume(levels):
            cont.yield(.volume(levels.map { Float($0) / 65535 }))
        case let .mute(on):
            cont.yield(.mute(on))
        case .stop:
            decoder = nil
            cont.yield(.stopped)
        case let .latency(ms):
            log.debug("playback: server latency hint \(ms) ms")
        case .other:
            break
        }
    }

    private static func floats(fromS16 bytes: [UInt8]) -> [Float] {
        var out = [Float](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let s = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            out.append(Float(s) / 32768)
            i += 2
        }
        return out
    }
}
```

`OpusDecoder` throws `AudioDecodeError`; `String(describing:)` on it prints the OSStatus, which is what the log needs.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter AudioPlayerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceMedia/AudioPlayer.swift Tests/SpiceMediaTests/AudioPlayerTests.swift
git commit -m "feat: AudioPlayer decodes the playback channel and drops late packets before decode"
```

---

### Task 5: `SpiceSession` opens the playback channel

**Files:**
- Modify: `Sources/SpiceKit/SpiceSession.swift`
- Modify: `Sources/SpiceSee/SpiceKitBackend.swift` (compile-only: `case .audio: break` until Task 7)
- Test: `Tests/SpiceKitTests/AudioSessionTests.swift`

**Interfaces:**
- Consumes: `PlaybackChannel.open(…caps:)` (Task 2), `AudioPlayer`, `AudioEvent`, `OpusDecoder.isAvailable()` (Tasks 3–4), `PlaybackCap`.
- Produces: `SessionEvent.audio(AudioEvent)`; `SpiceSession` opens `playback` id 0 with caps `[volume, latency] (+ opus when available)`, pumps it into an `AudioPlayer` seeded with the mm clock, forwards `.audio`, keeps the drain order (`audio.finish()` + await its pump before `channelEnded`), and re-seeds the clock on `MULTI_MEDIA_TIME`.

- [ ] **Step 1: Write the failing test** — `Tests/SpiceKitTests/AudioSessionTests.swift`:

```swift
import Foundation
import Testing
import SpiceWire
import SpiceMedia
@testable import SpiceCore
@testable import SpiceKit

/// MAIN_INIT + CHANNELS_LIST advertising exactly one playback channel, id 0.
private func mainBytesWithPlayback() throws -> [UInt8] {
    var mi = SpiceWriter(); [1, 1, SpiceMouseMode.server, SpiceMouseMode.server, 0, 10, 0, 0].forEach { mi.u32($0) }
    var cl = SpiceWriter(); cl.u32(1); cl.u8(ChannelType.playback.rawValue); cl.u8(0)
    return try fakeLink(body: frame(MainServerMsg.`init`.rawValue, mi.bytes) + frame(MainServerMsg.channelsList.rawValue, cl.bytes))
}

@Test func playbackMessagesSurfaceAsAudioEventsAndDisconnectedComesLast() async throws {
    var mode = SpiceWriter(); mode.u32(0); mode.u16(AudioDataMode.raw.rawValue)
    var start = SpiceWriter(); start.u32(2); start.u16(AudioFormat.s16); start.u32(48000); start.u32(0)
    var data = SpiceWriter(); data.u32(0); data.bytes([0, 0, 0, 0x40])        // L=0, R=0.5
    let body = frame(PlaybackServerMsg.mode.rawValue, mode.bytes)
             + frame(PlaybackServerMsg.start.rawValue, start.bytes)
             + frame(PlaybackServerMsg.data.rawValue, data.bytes)
             + frame(PlaybackServerMsg.stop.rawValue, [])
    let main = InMemoryTransport(input: try mainBytesWithPlayback())
    let playback = InMemoryTransport(input: try fakeLink(body: body))
    let session = try await SpiceSession.connect(password: nil) { desc in
        switch desc.type {
        case .main: return main
        case .playback: return playback
        default: return InMemoryTransport(input: try fakeLink(body: []))
        }
    }
    var audio: [AudioEvent] = []
    var disconnectedLast = false
    for await e in session.events {
        switch e {
        case let .audio(a): audio.append(a); disconnectedLast = false
        case .disconnected: disconnectedLast = true
        default: continue
        }
        if case .disconnected = e { break }
    }
    #expect(audio == [.started(sampleRate: 48000, channels: 2, opus: false),
                      .pcm(frames: [0, 0.5], mmTime: 0),
                      .stopped])
    #expect(disconnectedLast)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter playbackMessagesSurfaceAsAudioEventsAndDisconnectedComesLast`
Expected: FAIL — `SessionEvent` has no `.audio`.

- [ ] **Step 3: Implement in `SpiceSession.swift`.**
  - `SessionEvent`: add `case audio(AudioEvent)`.
  - State: `private var playback: PlaybackChannel?`, `private var audio: AudioPlayer?`.
  - In `start(...)`'s channel loop, add before `default: continue`:

```swift
                case .playback where desc.id == 0:
                    let opus = OpusDecoder.isAvailable()
                    var bits = [PlaybackCap.volume, PlaybackCap.latency]
                    if opus { bits.append(PlaybackCap.opus) }
                    let ch = try await PlaybackChannel.open(transport: try await transports(desc), connectionID: info.connectionID,
                                                            id: desc.id, password: password, caps: CapabilitySet(bits: bits))
                    playback = ch
                    let player = AudioPlayer(opusAvailable: opus)
                    audio = player
                    await player.setMMTime(info.mainInit.multiMediaTime)
                    let audioPump = Task { [cont] in for await e in player.events { cont.yield(.audio(e)) } }
                    tasks.append(audioPump)
                    let pump = Task { [weak self] in
                        for await m in ch.messages { await player.handle(m) }
                        // Same drain shape as the canvas and stream pumps: every decoded chunk is on
                        // `cont` before the channel is declared over, so .disconnected stays last.
                        await player.finish()
                        _ = await audioPump.value
                        await self?.channelEnded(desc)
                    }
                    audioPumps.append(pump); tasks.append(pump)
```

  with `var audioPumps: [Task<Void, Never>] = []` declared beside `displayPumps`/`cursorPumps`, awaited in the main-ended drain task after `cursorPumps`; `closeChannels()` gains `await playback?.close()`; `handleMain`'s `.multiMediaTime(t)` case also does `await audio?.setMMTime(t.time)`.
  - `Sources/SpiceSee/SpiceKitBackend.swift`: add `case .audio: break   // wired in Task 7` to the `session.events` switch so the app target compiles. `spicesee-cli`'s probes have `default:` arms and need nothing.

- [ ] **Step 4: Run everything**

Run: `swift test && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"`
Expected: engine PASS — `ReplayTests`, `ZlibGlzReplayTests`, `StreamSessionTests`, `SessionLossTests` included (their transport factories already hand empty channels to unknown types, and a playback channel that ends at EOF behaves exactly like the cursor channel they already tolerate); app BUILD SUCCEEDED. If a replay/session test regresses because its recorded main advertises `playback/0`, fix the **test's** transport factory to return `InMemoryTransport(input: try fakeLink(body: []))` for `.playback` explicitly and note it in the report — never weaken the session.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceKit/SpiceSession.swift Sources/SpiceSee/SpiceKitBackend.swift Tests/SpiceKitTests/AudioSessionTests.swift
git commit -m "feat: SpiceSession opens the playback channel and surfaces audio events"
```

---

### Task 6: `AudioOutput` and the seam event

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift` (seam `AudioEvent`, `BackendEvent.audio`)
- Create: `Sources/SpiceSee/AudioOutput.swift`
- Modify: `Sources/SpiceSee/SessionModel.swift` (owns `AudioOutput`; `muted` forwards; `apply(.audio)`)
- Modify: `Sources/SpiceSee/MockSessionBackend.swift` (compiles; the tone lands in Task 7)
- Test: `Tests/SpiceSeeTests/AudioOutputTests.swift`; run `xcodegen generate`

**Interfaces:**
- Produces (seam, in `SessionBackend.swift`):

```swift
/// Guest audio, decoded. `frames` are interleaved Float32 at the announced rate/channels.
enum AudioEvent: Sendable, Equatable {
    case started(sampleRate: Int, channels: Int, opus: Bool)
    case pcm(frames: [Float], mmTime: UInt32)
    case volume([Float])
    case mute(Bool)
    case stopped
}
// BackendEvent gains: case audio(AudioEvent)
```

and the output:

```swift
@MainActor final class AudioOutput {
    static let prebufferSeconds = 0.05
    init(engine: AVAudioEngine = AVAudioEngine())
    var muted: Bool                      // the toolbar's local switch → mainMixerNode.outputVolume 0/1
    func handle(_ event: AudioEvent)
    func stop()                          // session teardown: stop the player and the engine
    var isPlaying: Bool                  // test hook: player.isPlaying
    var playerVolume: Float              // test hook: player.volume (guest volume × !guestMute)
}
```

Behaviour: `.started` → stop the player, build a **deinterleaved** standard Float32 format at the announced rate/channels, `connect(player → mainMixerNode)`, start the engine if needed (log once on failure), reset prebuffer. `.pcm` → deinterleave into an `AVAudioPCMBuffer`, `scheduleBuffer`; while not yet playing, accumulate frames and call `play()` once ≥ `prebufferSeconds × sampleRate` are queued. `.volume(levels)` → guest volume = mean of `levels`; `.mute` → guest mute; `player.volume = guestMuted ? 0 : guestVolume`. `.stopped` → `player.stop()`, prebuffer reset. `muted` (toolbar) touches only the mixer.

- [ ] **Step 1: Write the failing tests** — `Tests/SpiceSeeTests/AudioOutputTests.swift`. `AVAudioEngine` in **manual rendering mode** needs no output device, so these run headless:

```swift
import AVFoundation
import Testing
@testable import SpiceSee

@MainActor
@Suite struct AudioOutputTests {
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    private func offlineEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        return engine
    }

    /// `ms` of full-scale stereo silence-or-tone as the seam delivers it: interleaved Float32.
    private func chunk(ms: Int, amplitude: Float = 0.5) -> AudioEvent {
        let n = 48 * ms
        var frames = [Float](repeating: 0, count: n * 2)
        for i in 0 ..< n { let v = amplitude * sinf(Float(i) * 2 * .pi * 440 / 48000); frames[i * 2] = v; frames[i * 2 + 1] = v }
        return .pcm(frames: frames, mmTime: 0)
    }

    private func rms(_ engine: AVAudioEngine, frames: AVAudioFrameCount = 2048) throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        let status = try engine.renderOffline(frames, to: buffer)
        #expect(status == .success)
        var sum: Float = 0
        for c in 0 ..< Int(buffer.format.channelCount) {
            let p = buffer.floatChannelData![c]
            for i in 0 ..< Int(buffer.frameLength) { sum += p[i] * p[i] }
        }
        return (sum / Float(Int(buffer.frameLength) * Int(buffer.format.channelCount))).squareRoot()
    }

    @Test func prebufferHoldsPlaybackUntilFiftyMilliseconds() throws {
        let output = AudioOutput(engine: try offlineEngine())
        output.handle(.started(sampleRate: 48000, channels: 2, opus: true))
        output.handle(chunk(ms: 20))
        #expect(!output.isPlaying)
        output.handle(chunk(ms: 20))
        #expect(!output.isPlaying)
        output.handle(chunk(ms: 20))         // 60 ms queued ≥ 50 ms target
        #expect(output.isPlaying)
    }

    @Test func toolbarMuteSilencesTheMixerButNotThePlayer() throws {
        let engine = try offlineEngine()
        let output = AudioOutput(engine: engine)
        output.handle(.started(sampleRate: 48000, channels: 2, opus: false))
        for _ in 0 ..< 5 { output.handle(chunk(ms: 20)) }
        #expect(try rms(engine) > 0.1)
        output.muted = true
        #expect(try rms(engine) == 0)
        #expect(output.playerVolume == 1)     // the guest's own level is untouched
    }

    @Test func guestMuteAndVolumeDriveThePlayerNotTheMixer() throws {
        let engine = try offlineEngine()
        let output = AudioOutput(engine: engine)
        output.handle(.started(sampleRate: 48000, channels: 2, opus: false))
        output.handle(.volume([0.5, 0.5]))
        #expect(output.playerVolume == 0.5)
        output.handle(.mute(true))
        #expect(output.playerVolume == 0)
        #expect(engine.mainMixerNode.outputVolume == 1)
        output.handle(.mute(false))
        #expect(output.playerVolume == 0.5)
    }

    @Test func stoppedResetsThePrebuffer() throws {
        let output = AudioOutput(engine: try offlineEngine())
        output.handle(.started(sampleRate: 48000, channels: 2, opus: false))
        for _ in 0 ..< 3 { output.handle(chunk(ms: 20)) }
        #expect(output.isPlaying)
        output.handle(.stopped)
        #expect(!output.isPlaying)
        output.handle(chunk(ms: 20))
        #expect(!output.isPlaying)            // a fresh prebuffer, not a resumed one
    }
}
```

- [ ] **Step 2: `xcodegen generate`; run to verify they fail**

Run: `xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:" | head -3; xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)" | grep -v "module dependency" | head -5`
Expected: FAIL — `AudioOutput`/`AudioEvent` undefined.

- [ ] **Step 3: Implement.**
  - `SessionBackend.swift`: the seam `AudioEvent` above (place after `ClipboardEvent`) and `case audio(AudioEvent)` in `BackendEvent` (after `.clipboard`).
  - `Sources/SpiceSee/AudioOutput.swift`:

```swift
import AVFoundation
import os

/// The speaker end of the playback channel. Decoded frames arrive over the seam; this schedules
/// them on an `AVAudioPlayerNode` — never a realtime render callback, so there is no ring buffer
/// and no lock — and holds `play()` until ~50 ms are queued, which is the whole jitter buffer.
///
/// Two volume controls multiply: the guest's (`PLAYBACK_VOLUME`/`MUTE`, what its slider does)
/// lives on the player node; the toolbar's `muted` lives on the mixer. Neither overwrites the other.
@MainActor
final class AudioOutput {
    static let prebufferSeconds = 0.05

    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queuedBeforePlay: AVAudioFrameCount = 0
    private var playing = false
    private var guestVolume: Float = 1
    private var guestMuted = false
    private var loggedStartFailure = false
    private let log = Logger(subsystem: "com.spicesee", category: "audio-output")

    var muted = false {
        didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
    }

    var isPlaying: Bool { player.isPlaying }
    var playerVolume: Float { player.volume }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
    }

    func handle(_ event: AudioEvent) {
        switch event {
        case let .started(sampleRate, channels, _):
            player.stop()
            playing = false
            queuedBeforePlay = 0
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else {
                log.error("audio: unsupported format \(sampleRate) Hz × \(channels)")
                format = nil
                return
            }
            format = fmt
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            if !engine.isRunning {
                do { try engine.start() }
                catch {
                    if !loggedStartFailure { log.error("audio: engine start failed: \(String(describing: error))"); loggedStartFailure = true }
                }
            }
        case let .pcm(frames, _):
            guard let format, engine.isRunning else { return }
            let channels = Int(format.channelCount)
            let count = AVAudioFrameCount(frames.count / channels)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let data = buffer.floatChannelData else { return }
            for c in 0 ..< channels {
                for i in 0 ..< Int(count) { data[c][i] = frames[i * channels + c] }
            }
            buffer.frameLength = count
            player.scheduleBuffer(buffer)
            if !playing {
                queuedBeforePlay += count
                if Double(queuedBeforePlay) >= Self.prebufferSeconds * format.sampleRate {
                    player.play()
                    playing = true
                }
            }
        case let .volume(levels):
            guestVolume = levels.isEmpty ? 1 : levels.reduce(0, +) / Float(levels.count)
            applyGuestLevel()
        case let .mute(on):
            guestMuted = on
            applyGuestLevel()
        case .stopped:
            player.stop()
            playing = false
            queuedBeforePlay = 0
        }
    }

    /// Session teardown. The engine is stopped too, so the device is released between sessions.
    func stop() {
        player.stop()
        playing = false
        queuedBeforePlay = 0
        format = nil
        if engine.isRunning { engine.stop() }
    }

    private func applyGuestLevel() { player.volume = guestMuted ? 0 : guestVolume }
}
```

  - `SessionModel.swift`: `private let audio: AudioOutput` created in `init` (`audio = AudioOutput()`); `var muted = false { didSet { audio.muted = muted } }`; in `apply`: `case let .audio(event): audio.handle(event)`; call `audio.stop()` in the `.failed` and `.disconnected` cases and in `cancel()` and `disconnect()`, next to `clipboard.stop()`. `connect()` should also `audio.stop()` before starting (a reconnect over a live session).
  - `MockSessionBackend.swift` compiles unchanged (no new protocol members).

- [ ] **Step 4: Run the app-target suite**

Run: `xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"; xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)" | head -2`
Expected: BUILD SUCCEEDED; all tests pass (four new). If `renderOffline` in `toolbarMuteSilencesTheMixerButNotThePlayer` yields RMS 0 even unmuted, the player has not been started (prebuffer) — five 20 ms chunks are 100 ms, so check the connect/`play()` path before touching the assertion.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceSee/SessionBackend.swift Sources/SpiceSee/AudioOutput.swift Sources/SpiceSee/SessionModel.swift Tests/SpiceSeeTests/AudioOutputTests.swift project.yml SpiceSee.xcodeproj 2>/dev/null
git commit -m "feat: AudioOutput plays seam audio behind a 50 ms prebuffer; toolbar mute is real"
```

(`SpiceSee.xcodeproj` is gitignored — the `git add` of it is a harmless no-op; `project.yml` only changes if you edited it, which you should not need to.)

---

### Task 7: Adapter translation and the mock tone

**Files:**
- Modify: `Sources/SpiceSee/SpiceKitBackend.swift`
- Modify: `Sources/SpiceSee/MockSessionBackend.swift`

**Interfaces:**
- Consumes: `SpiceMedia.AudioEvent` (Task 4), seam `AudioEvent`/`BackendEvent.audio` (Task 6).
- Produces: `.audio` flowing to `SessionModel`; the mock's desktop scenario emits `.started` then a soft 100 ms 440 Hz tick every second, so the toolbar mute is reviewable by ear.

- [ ] **Step 1: Replace Task 5's placeholder in `SpiceKitBackend.connect`:**

```swift
                    case let .audio(e):
                        continuation.yield(.audio(Self.translate(e)))
```

and add the mapping (the two enums are the same shape on purpose — the seam one simply does not import SpiceMedia):

```swift
    private static func translate(_ e: SpiceMedia.AudioEvent) -> AudioEvent {
        switch e {
        case let .started(rate, channels, opus): .started(sampleRate: rate, channels: channels, opus: opus)
        case let .pcm(frames, mmTime): .pcm(frames: frames, mmTime: mmTime)
        case let .volume(levels): .volume(levels)
        case let .mute(on): .mute(on)
        case .stopped: .stopped
        }
    }
```

- [ ] **Step 2: Mock tone.** In `MockSessionBackend.connect`, right after the initial `.frame`/`.cursor` yields: `continuation.yield(.audio(.started(sampleRate: 48000, channels: 2, opus: true)))`. In the caret loop body (it already ticks every 500 ms), every other tick also yields `.audio(Self.tick())`:

```swift
    /// 100 ms of a quiet 440 Hz tone, stereo interleaved — enough to hear the mute toggle work.
    private static func tick() -> AudioEvent {
        let n = 4800
        var frames = [Float](repeating: 0, count: n * 2)
        for i in 0 ..< n {
            let env = Float(min(i, n - 1 - i)) / 480              // 10 ms fade in/out: no clicks
            let v = 0.1 * min(env, 1) * sinf(Float(i) * 2 * .pi * 440 / 48000)
            frames[i * 2] = v; frames[i * 2 + 1] = v
        }
        return .pcm(frames: frames, mmTime: 0)
    }
```

- [ ] **Step 3: Build, test, listen**

Run: `swift build && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)" && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)" | head -2`
Then launch the mock (`BUILT_PRODUCTS_DIR=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings | grep BUILT_PRODUCTS_DIR | awk '{print $3}'); SPICESEE_MOCK=1 "$BUILT_PRODUCTS_DIR/SpiceSee.app/Contents/MacOS/SpiceSee" --scenario desktop --autoconnect`). Expected: a quiet tick once a second from the Mac's speakers; the toolbar mute button cannot be clicked on this machine, so state that the listen-and-mute check is the user's, and quit with `osascript -e 'tell application "SpiceSee" to quit'`.

- [ ] **Step 4: Commit**

```bash
git add Sources/SpiceSee/SpiceKitBackend.swift Sources/SpiceSee/MockSessionBackend.swift
git commit -m "feat: audio events cross the seam; the mock ticks a tone for the mute toggle"
```

---

### Task 8: `spicesee-cli audio` — record the guest to a WAV

**Files:**
- Modify: `Sources/spicesee-cli/main.swift`

**Interfaces:**
- Consumes: `SessionEvent.audio(AudioEvent)` (Task 5).
- Produces: `spicesee-cli audio <host> <port> <seconds> <out.wav> [password]` — writes a 16-bit WAV of the decoded stream; prints `START rate=… channels=… mode=OPUS|RAW`, `VOLUME …`, `MUTE …`, `STOP`, and a final `wrote N frames (S s) to path`.

- [ ] **Step 1: Add the probe** (after `resizeProbe`; `import AVFoundation` at the top of the file):

```swift
/// Records the playback channel to a WAV so M6 can be checked by ear from this machine: someone
/// plays a sound in the guest, this file should contain it. Prints the negotiation as it happens.
func audioProbe(_ config: ConnectionConfig, seconds: Double, out: URL) async throws {
    let session = try await SpiceSession.connect(config)
    print("connected; recording audio for \(seconds)s")
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await session.disconnect()
    }
    defer { deadline.cancel() }

    var file: AVAudioFile?
    var format: AVAudioFormat?
    var frames = 0
    for await event in session.events {
        switch event {
        case let .audio(.started(rate, channels, opus)):
            print("START rate=\(rate) channels=\(channels) mode=\(opus ? "OPUS" : "RAW")")
            let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels))!
            format = fmt
            if file == nil {
                file = try AVAudioFile(forWriting: out, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
        case let .audio(.pcm(pcm, _)):
            guard let file, let format else { continue }
            let channels = Int(format.channelCount)
            let count = AVAudioFrameCount(pcm.count / channels)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let data = buffer.floatChannelData else { continue }
            for c in 0 ..< channels { for i in 0 ..< Int(count) { data[c][i] = pcm[i * channels + c] } }
            buffer.frameLength = count
            try file.write(from: buffer)
            frames += Int(count)
        case let .audio(.volume(levels)):
            print("VOLUME \(levels.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        case let .audio(.mute(on)):
            print("MUTE \(on)")
        case .audio(.stopped):
            print("STOP")
        case .disconnected:
            if let format { print("wrote \(frames) frames (\(String(format: "%.1f", Double(frames) / format.sampleRate)) s) to \(out.path)") }
            else { print("no PLAYBACK_START arrived — is anything playing in the guest?") }
            return
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Argument parsing.** `usage()` gains `spicesee-cli audio <host> <port> <seconds> <out.wav> [password]`; add a `case "audio":` mirroring `case "dump":` (positional host, port, seconds, out path, optional password) calling `audioProbe`.

- [ ] **Step 3: Build and smoke**

Run: `swift build && swift run spicesee-cli audio 2>&1 | head -2`
Expected: builds; bare invocation prints usage (exit 2). The live run is the exit check (Task 9).

- [ ] **Step 4: Commit**

```bash
git add Sources/spicesee-cli/main.swift
git commit -m "feat: cli audio probe records the playback channel to a WAV"
```

---

### Task 9: Exit checks and docs

**Files:**
- Modify: `docs/dev-server.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Live probe.** `scripts/dev-server.sh` first. Then, with the user (or a scheduled sound) producing audio in the Windows guest — if nobody is at the guest, run anyway for 15 s and record whatever arrived:

```bash
swift run spicesee-cli audio 192.168.50.6 5930 15 /tmp/guest-audio.wav
```

Expected when sound is playing: `START rate=48000 channels=2 mode=OPUS`, then `wrote … frames`. Record the verbatim output (or the "no PLAYBACK_START" line) in the doc.

- [ ] **Step 2: `docs/dev-server.md`** — append after the M5 exit check:

```markdown
## M6 exit check (manual)

Machine-driveable half (needs a sound playing in the guest — a YouTube tab, a Windows system sound):

- [ ] `swift run spicesee-cli audio 192.168.50.6 5930 15 /tmp/guest-audio.wav` prints
      `START rate=48000 channels=2 mode=OPUS` and writes a WAV you can hear the guest in. `mode=RAW`
      means the Opus capability was not announced (the AudioToolbox probe failed on this Mac) or the
      server ignored it; either way sound still plays, but say which.

<verbatim probe output from the run goes here>

In the app:

- [ ] Guest sound plays from the Mac's speakers with no audible stutter over about a minute.
- [ ] Moving the guest's volume slider changes the level (PLAYBACK_VOLUME → the player node).
- [ ] The toolbar mute silences it and un-mute restores it (the mixer; the guest's level is kept).
- [ ] Pausing the guest's player sends PLAYBACK_STOP and the app goes silent without clicks; resuming
      starts cleanly after the ~50 ms prebuffer.
- [ ] `--mock --scenario desktop --autoconnect` ticks a quiet 440 Hz tone once a second; the mute
      button stops it.

**Opus decode is Apple's, not libopus.** `OpusDecoder.isAvailable()` probes `AudioConverterNew`
with `kAudioFormatOpus` at connect time and the capability is announced only when that passes.
Verified on this Mac (macOS 26.x); **a macOS 14 machine has not been checked** — the deployment
floor is 14 and Opus landed in AudioToolbox in that release, but if it fails there the fallback
is raw PCM at ~1.5 Mbps, not silence. The fixture `Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin`
was encoded by libopus 1.6.1 via `Tools/opusref.c` so the decoder is never tested against itself.

**No lip-sync.** Audio and video streams are each paced to the mm clock independently; nothing
ties a frame to a sample. The record (microphone) channel is not opened.
```

- [ ] **Step 3: `CLAUDE.md`** — surgical edits: the layer table's `SpiceMedia` line adds "audio: AudioToolbox Opus decode, mm-clock gate"; the architecture paragraph gains an **M6 added** sentence (playback channel, `OpusDecoder` probe-gated over AudioToolbox, `AudioPlayer` with the 80 ms drop-before-decode rule, `AudioOutput` behind a 50 ms prebuffer on `AVAudioPlayerNode`, toolbar mute now real, `spicesee-cli audio`); "audio is M6" leaves the does-not-exist list; the record channel and mic stay listed as absent, M7 (ship) next. Add three gotcha lines beside the M4 rules: *audio never touches a realtime render thread — `scheduleBuffer` from the main actor is the whole output path, and the ~50 ms prebuffer in `AudioOutput` is the only jitter buffer*; *two volume controls multiply: guest volume/mute on the player node, toolbar mute on the mixer — never fold one into the other*; *the Opus capability is announced only when `OpusDecoder.isAvailable()` passes at connect — do not hard-code it, and never test the decoder against an Apple-encoded fixture*.

- [ ] **Step 4: Full suites**

Run: `swift test && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)" | head -2 && scripts/check-vendored-notices.sh`
Expected: all PASS; notices exit 0 (nothing under `vendor/` changed and no new licence — Apple's decoder is the OS's).

- [ ] **Step 5: Commit**

```bash
git add docs/dev-server.md CLAUDE.md
git commit -m "docs: M6 exit checks; audio architecture notes"
```

---

## Self-Review Notes (already applied)

- Spec §1 → Tasks 1–2; §2 → Tasks 3–4; §3 → Tasks 5–7; §4 → Tasks 3 (fixture), 4–6 (tests), 8 (probe), 9 (exit checks). The `opus: Bool` on `started` is the plan's one addition to the spec's event, needed by exit criterion 1's `MODE=OPUS` log line.
- Type consistency: `AudioEvent.started(sampleRate:channels:opus:)` is spelled identically in SpiceMedia (Task 4), the seam (Task 6), the adapter (Task 7), the cli (Task 8) and the tests. `PlaybackCap.opus`, `AudioDataMode.opus`, `AudioFormat.s16` are used with those exact names throughout.
- The `.playback where desc.id == 0` arm in Task 5 comes before `default: continue`, so a second playback channel (never seen) is still skipped rather than opened.
