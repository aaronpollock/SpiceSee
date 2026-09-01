# SpiceSee M6 — Audio: playback channel, Opus decode, speaker output

Design for milestone M6 of `2026-08-22-spicesee-design.md` ("Audio"). Scope is spec-faithful to §5
of that document with one substitution decided by a spike on 2026-09-01: **the Opus decoder is
Apple's** (`AudioToolbox` `AudioConverter`, `kAudioFormatOpus`), not a vendored libopus. The spike
encoded one second of a 440 Hz tone with Homebrew's libopus 1.6.1 and Apple's converter decoded it to
47 880 frames (48 000 minus Opus's 120-sample pre-skip) at RMS 0.353 against an expected 0.354. No new
dependency, no new licence entry. The deployment floor is macOS 14 and the spike ran on a newer OS, so
Opus support is **probed at runtime** and the capability is advertised only when the probe passes;
raw PCM is the server's fallback either way.

**Shape (approach 1 of three considered):** decode and pacing in the engine (`SpiceMedia`), speaker
output in the app via `AVAudioPlayerNode.scheduleBuffer`. Frames cross the seam as `[Float]`, exactly
as video frames cross as `[UInt8]`. The main spec's `AVAudioSourceNode` + ring buffer was declined: a
realtime render thread reading a ring needs atomics, the `Synchronization` module is macOS 15+, and
`os_unfair_lock` is banned — that path costs a swift-atomics dependency for no audible gain at a 50 ms
target.

**Out of scope:** microphone/record capture (the record channel stays unopened — opening it without
answering `RECORD_START` would only tell the server a mic exists), `PLAYBACK_LATENCY` adaptation
(parsed and logged; one fixed target), audio/video lip-sync (each is paced to the mm clock
independently), CELT, output-device selection, and the agent's `AUDIO_VOLUME_SYNC` (still
unannounced).

## 1. Wire and channel

**`SpiceWire.PlaybackMessages`** parses the server→client set (constants already in the vendored
`enums.h`): `PLAYBACK_DATA` (`time: u32`, then the codec payload), `PLAYBACK_MODE` (`time: u32`,
`mode: u16` RAW/OPUS), `PLAYBACK_START` (`channels: u32`, `format: u16` = S16, `frequency: u32`,
`time: u32`), `PLAYBACK_STOP`, `PLAYBACK_VOLUME` (`nchannels: u8`, `u16` × n), `PLAYBACK_MUTE`
(`u8`), `PLAYBACK_LATENCY` (`u32` ms). Every accessor throws; a hostile length is a caught error,
never a trap. Layouts are checked against `spice.proto`/`spice-gtk` during implementation, not
transcribed by eye (`SpiceString.flags` and `VDAgentMessage` are the precedents).

Client caps: `PLAYBACK_CAP_VOLUME`, `PLAYBACK_CAP_LATENCY`, and `PLAYBACK_CAP_OPUS` **only when the
runtime probe passed** (§2). CELT is never advertised; a server sending `MODE=CELT` anyway has its data
dropped with one logged notice.

**`SpiceCore.PlaybackChannel`** is a small actor in the `CursorChannel` mould:
`open(transport:connectionID:id:password:caps:)`, `messages: AsyncStream<PlaybackMessage>`,
`close()`. The `caps` argument is the one difference from its siblings — the Opus bit depends on a
device probe SpiceCore must not perform, so the caller decides.

## 2. `SpiceMedia.AudioPlayer` — decode, pacing, events

An actor beside `StreamPlayer`, fed by `SpiceSession`'s playback pump, emitting
`AsyncStream<AudioEvent>`:

```
enum AudioEvent: Sendable {
  case started(sampleRate: Int, channels: Int)   // PLAYBACK_START (after MODE); output (re)configures
  case pcm(frames: [Float], mmTime: UInt32)      // interleaved Float32, one PLAYBACK_DATA packet
  case volume([Float])                           // per channel, 0…1 from PLAYBACK_VOLUME's u16 / 65535
  case mute(Bool)
  case stopped                                   // PLAYBACK_STOP: output drains and idles
}
```

- **`OpusDecoder`** wraps `AudioConverter(kAudioFormatOpus → Float32 LPCM)`. `static func
  isAvailable() -> Bool` (does `AudioConverterNew` succeed?) is the startup probe behind the channel
  cap. RAW mode converts S16 → Float32 directly. The converter is recreated on every
  `PLAYBACK_START` — a new stream is fresh decoder state, as in spice-gtk.
- **Pacing — the mm clock, the video rules.** `setMMTime` from `MAIN_INIT`/`MULTI_MEDIA_TIME`,
  `serverNow()` as `StreamPlayer` does. A packet more than **80 ms** behind the clock is counted and
  dropped *before* decode, for the same reason video drops before decode. Otherwise packets are
  emitted immediately: the ~50 ms jitter target lives in the output's prebuffer (§3), so this actor
  stays a pure decode-and-gate stage a test can drive with a synthetic clock.
- **Volume/mute** are forwarded as they arrive, stamped on the event, never queried back.
- **Failure never ends the session:** decoder creation fails → log, drop Opus packets with one notice
  (raw still plays); a malformed packet → skip it, keep the stream.

## 3. Seam, app output, controls

**Seam.** `BackendEvent.audio(AudioEvent)` — the seam's own enum mirroring §2's cases, `[Float]` and
`Float` only. The seam gains **only the event**: the protocol has no client→server playback mute, so
muting is local and never crosses. `MockSessionBackend` yields `.started` and a soft 440 Hz `.pcm`
tick each second in the desktop scenario, so the mute toggle is reviewable by ear without a guest.

**`Sources/SpiceSee/AudioOutput.swift`** (`@MainActor final class`, AVFoundation only) owns
`AVAudioEngine → AVAudioPlayerNode → mainMixerNode`. On `.started` it (re)connects the player at the
announced rate/channels and enters **prebuffer**: chunks are scheduled but `play()` waits until ~50 ms
are queued — the jitter target, honoured in the one place that can. Each `.pcm` becomes an
`AVAudioPCMBuffer` passed to `scheduleBuffer`, created and consumed on the main actor. `.stopped` →
`stop()` and back to prebuffer. Engine start failure (no output device) is logged once; the session
is unaffected.

**Two independent controls that multiply:** guest `.volume`/`.mute` set the **player node's**
`volume` (what the guest's slider does); the toolbar's `session.muted` sets the **mixer's**
`outputVolume` to 0/1 (the user's local switch, already in the UI and currently inert). Neither
overwrites the other.

**`SessionModel`** owns `AudioOutput` the way it owns `ClipboardBridge`: created in `init`, fed from
`apply(.audio(_))`, stopped on disconnect/failed/cancel; `muted`'s `didSet` forwards. **No view
edits** — `SessionWindowView`'s mute button and overflow toggle already bind `session.muted`.

**`SpiceSession`** opens `PlaybackChannel` with the probed caps, pumps its messages into
`AudioPlayer`, forwards `AudioEvent`s as `SessionEvent.audio(_)`, and keeps the drain order: the
audio pump finishes before `.disconnected`, like the canvas and stream pumps.

## 4. Testing and exit criteria

**Fixtures are cross-implementation.** `Tools/opusref.c` (the spike's encoder, kept like
`agentref.c`) encodes a known tone with Homebrew's libopus into
`Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin`; the fixture is committed, the tool is how
it was made. `OpusDecoderTests` asserts frame count (48 000 − 120) and RMS within 1 % of 0.354 —
Apple's decoder checked against libopus, never against itself.

| Layer | Covers |
|---|---|
| `SpiceWireTests/PlaybackMessageTests` | each message from hand-built bytes; truncated payloads throw |
| `SpiceMediaTests/AudioPlayerTests` | scripted messages + synthetic mm clock: `.started`; a 100 ms-late packet dropped and counted; S16→Float32 exact; u16→Float volume; `.stopped`; decoder-unavailable degrades without ending the stream |
| `SpiceSeeTests/AudioOutputTests` | `AVAudioEngine` in manual rendering mode (no device): 50 ms of `.pcm` starts playback, a lone 20 ms chunk stays in prebuffer, guest mute zeroes the player while toolbar mute zeroes the mixer |
| `SpiceKitTests` | scripted session with a playback channel: `.audio` events arrive; `.disconnected` still last |
| Mock | the desktop tone makes the toolbar mute reviewable by ear |

**Probe.** `spicesee-cli audio <host> <port> <seconds> <out.wav>` records the decoded stream to a WAV
and prints START/MODE/VOLUME/MUTE as they arrive — wire-verifiable from this machine while someone
plays a sound in the guest.

**Exit criteria:**

1. `spicesee-cli audio` against the Windows dev guest writes a WAV in which the guest's sound is
   audible; the log shows `MODE=OPUS`.
2. In the app: guest sound plays without audible stutter over ~1 minute; the guest's volume slider
   changes the level; the toolbar mute silences and un-mute restores.
3. The Opus probe passes on this Mac; a macOS 14 machine is a listed manual check (raw PCM is the
   safety net if it fails there).
