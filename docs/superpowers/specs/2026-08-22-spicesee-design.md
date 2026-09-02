# SpiceSee — Design

Date: 2026-08-22
Status: approved for planning

A native macOS SPICE client. Swift core, Apple frameworks for TLS, crypto, video, audio, and
rendering; the SPICE-proprietary image codecs are the only vendored C. Shipped as a signed,
notarized download for anyone to use.

## 1. Goals and scope

**Targets:** Proxmox VE (`.vv` files, TLS with pinned `host-subject`, ticket auth) and plain
QEMU/libvirt (direct host:port, optional ticket, optional TLS).

**v1 features:** display, keyboard, mouse (client + server mode), native cursor, bidirectional
clipboard, dynamic resolution, multi-monitor, audio playback, `.vv` handling, migration
reconnect prompt.

**Out of scope:** USB redirection, smartcard, SASL, proxies, audio recording (seam only), full
semi-seamless migration, VP8/VP9, forwarding OS-reserved shortcuts (Cmd-Tab; v2 via CGEventTap),
Mac App Store.

**Deployment:** arm64, macOS 14+, Developer ID + notarized DMG at https://somecoolthings.com/spicesee,
Sparkle 2 updates. No Homebrew cask (decided 2026-08-28: it asks nothing of the build and would only
be a second front door to the same file). Closed-source-capable.

## 2. Architecture

Single SPM package plus a thin Xcode project for the app bundle.

```
Sources/
  CSpiceCodec/   vendored C, decode-only: quic.c, lz.c, glz decoder   (LGPL-2.1+, dynamic fw)
  COpus/         libopus static lib                                   (BSD-3)
  SpiceWire/     wire types, enums, capability bits, bounds-checked reader/writer
  SpiceCore/     NWConnection transport, TLS, link handshake, ticket, session + channel actors
  SpiceCanvas/   surfaces, draw commands, image cache, GLZ window, codec routing
  SpiceMedia/    video streams -> VideoToolbox; playback -> CoreAudio
  SpiceAgent/    vdagent: clipboard, monitors config, mouse mode
  SpiceKit/      facade: `SpiceSession`, the only type the app sees
  SpiceSee/      SwiftUI + AppKit app, .vv handling, connection manager
Tools/spicerec   TCP proxy that records every channel's raw bytes for replay tests
Tests/
```

**Dependency rule:** strictly downward. `SpiceCanvas` knows nothing about sockets; `SpiceCore`
knows nothing about pixels. The whole stack below `SpiceKit` runs headless from recorded bytes.

**Concurrency:** Swift 6 strict. One `actor` per SPICE channel (each is its own TCP connection)
with a read loop publishing decoded messages. Display work runs on a dedicated serial executor,
never the main actor, and hands finished surfaces to `@MainActor` views. No locks, no
`@unchecked Sendable`.

### Licensing

`spice-protocol` headers (`messages.h`, `draw.h`) are BSD-3 — the wire format is unencumbered.
`quic.c`, `lz.c`, and the GLZ decoder are LGPL-2.1+ and unavoidable: `image-compression` is a
server-side option defaulting to `auto_glz` with no client opt-out, and Proxmox exposes no
per-VM override. A Swift port would be a derivative work and stay LGPL.

Compliance via LGPL-2.1 §6(b):

- `CSpiceCodec` builds as a **dynamic framework** embedded in the bundle; its source (codecs
  only) is published.
- LGPL text and written offer in an acknowledgements panel.
- Entitlement `com.apple.security.cs.disable-library-validation = true` so a user may substitute
  a modified framework under the hardened runtime. Notarization accepts this.

This rules out the Mac App Store. Distribution is a direct download (notarized DMG); no Homebrew cask (§8).

## 3. SpiceWire and SpiceCore

**`SpiceWire` is the security boundary.** `SpiceReader` is a bounds-checked little-endian reader
whose every accessor throws. A hostile or buggy server produces a caught error, never a trap.
Messages are Swift enums with associated values built via `init(reader:)`. Hand-written (~60
message types) from `messages.h`/`draw.h`; no IDL codegen — the protocol is frozen and the
generator would be its own project. Correctness is pinned by replay tests.

**Link handshake**, per channel:

```
->  SpiceLinkHeader   magic "REDQ", version 2.2
->  SpiceLinkMess     connection_id, channel type/id, common + channel caps
<-  SpiceLinkReply    error, 162-byte RSA SubjectPublicKeyInfo, server caps
->  128 bytes         ticket, RSA-OAEP-SHA1 via SecKeyCreateEncryptedData
<-  SpiceLinkResult   error
    message loop
```

Capabilities advertised: `AUTH_SPICE`, `MINI_HEADER`. No SASL. `disable-ticketing` servers skip
the ticket step.

**TLS:** Network.framework. `sec_protocol_options_set_verify_block` validates against the `.vv`
file's embedded CA and matches `host-subject` directly. No OpenSSL anywhere.

**Session bring-up:** `SpiceSession` connects main, reads `MAIN_INIT` (connection id, mouse
mode, agent tokens, mm clock), then `MAIN_CHANNELS_LIST`, then spawns one channel actor per
entry. `PING`/`PONG` supplies RTT.

**Errors:** one `SpiceError` carrying channel identity; a failed secondary channel degrades the
session (e.g. "audio disconnected") rather than tearing it down.

**Migration:** parse `MAIN_MIGRATE_BEGIN`/`MIGRATE_SWITCH_HOST`; show a "VM migrated —
reconnect?" dialog with the new host prefilled. Full channel switchover is deferred.

**`.vv` files:** INI. Read `host`, `port`, `tls-port`, `password`, `host-subject`, `ca` (PEM with
escaped newlines), `delete-this-file`. Registered as a document type so Proxmox's web UI hands
off by double-click.

## 4. SpiceCanvas

**Raster core in Swift over Accelerate.** SPICE ROP descriptors (`PUT`/`OR`/`AND`/`XOR` with
source/brush/dest inversion flags) plus optional 1-bit masks do not map onto `CGBlendMode`, so
drawing is our own scanline code. CoreGraphics is used only to rasterize `STROKE` paths into a
1-bit mask. `TEXT` carries glyph bitmaps, not fonts — it is a mask blit.

Surfaces are aligned BGRA allocations owned by us, wrapped in `CGContext` only when needed, and
shared to Metal without a copy.

Three draw tiers:

```
tier 1  ROPD_OP_PUT, no mask, rect clip   -> vImage / memcpy scanlines   (~95% of traffic)
tier 2  general ROP + brush + qmask       -> Swift scanline kernels
tier 3  STROKE                            -> CGPath -> 1-bit mask -> tier 2
```

All draw commands are implemented: COPY, FILL, OPAQUE, BLEND, ALPHA_BLEND, COPY_BITS,
BLACKNESS, WHITENESS, INVERS, ROP3, TRANSPARENT, STROKE, TEXT, COMPOSITE, plus SURFACE_CREATE/
DESTROY and off-screen surface references. There is no full-redraw request in the protocol; an
unimplemented command is permanent corruption.

**Mandatory state** from `DISPLAY_INIT`:

- **Image cache** keyed by 64-bit id: `CACHE_ME` stores, `FROM_CACHE` references with no
  pixel data. Also `INVAL_LIST`/`INVAL_ALL_PIXMAPS`.
- **GLZ dictionary window**: GLZ back-references pixels from previously decoded images, so the
  decoder is stateful for the session. Lives in `CSpiceCodec`.

**Video streams** (`STREAM_CREATE`/`DATA`/`DATA_SIZED`/`CLIP`/`DESTROY`) are not drawn into
the surface. Decoded frames stay as `IOSurface`-backed textures and are composited in Metal at
present time. `STREAM_REPORT` is implemented so the server adapts bitrate.

**Presentation:** one `CAMetalLayer` pass per viewport — primary surface texture updated on dirty
rects only, stream textures composited over it.

**Codec routing:**

| Source | Decoder |
|---|---|
| QUIC, GLZ, LZ, ZLIB-GLZ | `CSpiceCodec` |
| LZ4 | `Compression.framework` (`COMPRESSION_LZ4_RAW`) |
| JPEG, JPEG-alpha | ImageIO / vImage |
| MJPEG streams | VideoToolbox (`kCMVideoCodecType_JPEG`, hardware) |
| H.264 streams | VideoToolbox |
| VP8, VP9 | not supported; not advertised |

Display caps advertised: `MJPEG`, `H264`. MJPEG is the universal server fallback, so there is
always a video path; its cost is bandwidth (~20–40 Mbps at 1080p), not decode. libvpx can be
added later if VP9 is wanted.

## 5. SpiceMedia and SpiceAgent

**Audio.** Playback cap: `OPUS` only (CELT is dead; raw PCM is the server fallback). Opus decode
via static libopus. Output: `AVAudioSourceNode` render callback over a ring buffer; ~50 ms jitter
target keyed to the mm clock. `PLAYBACK_VOLUME`/`MUTE` map to the mixer. Record channel: seam
only.

**Agent.** vdagent rides `MAIN_AGENT_DATA` and is **token flow-controlled** — we send only as
many agent messages as `AGENT_TOKEN` has granted; the session actor owns the queue. Without
`spice-vdagent` in the guest, the UI shows "agent not connected"; clipboard and resolution
features are simply absent.

**Clipboard** (both sides lazy, grab-based):

- Host -> guest: poll `NSPasteboard.changeCount` (~0.5 s); send `CLIPBOARD_GRAB` with held
  types (`UTF8_TEXT`, `IMAGE_PNG`); send data only on `CLIPBOARD_REQUEST`.
- Guest -> host: on guest `GRAB`, register an `NSPasteboardItem` with a data provider; fetch on
  paste.
- Loop guard: remember our own `changeCount`.

**Monitors.** Two server shapes, both supported from the start:

```
(a) N qxl devices   -> N display channels (id 0..N-1), one surface each
(b) 1 qxl, N heads  -> 1 display channel; DISPLAY_MONITORS_CONFIG carves N head rects
                       out of one primary surface
```

Core abstraction: `Viewport = (channelID, headIndex, rect-into-surface)`. **One window per
viewport.** Window resize -> debounced (~250 ms) `VD_AGENT_MONITORS_CONFIG` covering all heads;
closing a window disables that head. Per-connection **HiDPI** setting, off by default (send
points, guest at 1x); on sends backing pixels.

**Mouse mode.** Request client mode (absolute `MOUSE_POSITION`) when the agent is up; server mode
(relative `MOUSE_MOTION`, pointer captured) for agent-less states (BIOS, installers, login).

## 6. Input, cursor, app

**Keyboard.** Static table: macOS `kVK_*` (physical, layout-independent) -> XT set-1 scancodes
with `0xE0` extended prefix (~110 entries). Modifiers via `flagsChanged`. On window-resign-key,
release every held key. Lock keys synced both ways with `INPUTS_KEY_MODIFIERS`. Default
positional mapping Cmd->Super, Option->Alt, swappable in preferences. OS-reserved combos stay
with macOS in v1.

**Mouse.** Wheel = button 4/5 press/release pairs; trackpad deltas accumulate and emit one click
per N units. Server mode hides the cursor, pins it with
`CGAssociateMouseAndMouseCursorPosition(false)`, releases on a configurable chord (default
Ctrl+Option).

**Cursor.** Cursor channel shapes (`ALPHA`, `MONO`, `COLOR4/8/16/24/32`) decode to BGRA with a
cursor cache. Client mode: real `NSCursor` with hotspot. Server mode: composited in the Metal
layer at the reported position.

**App.** SwiftUI chrome; one `NSView` subclass hosting the `CAMetalLayer` per viewport. A
`Session` owns its viewport windows; closing the last one disconnects. Connection manager
persists saved hosts, passwords in Keychain. Per-window toolbar: Ctrl-Alt-Del, fullscreen,
fit/1:1 scaling, HiDPI, clipboard on/off, mute, agent indicator. Native fullscreen per window so a
multi-head session spans multiple Mac displays. Visual design is a separate phase.

## 7. Testing

- **Replay golden tests** (primary): `spicerec` records raw channel bytes from any
  client/server pair; replay through `SpiceCore`+`SpiceCanvas` headless; final framebuffer
  pinned as PNG after one manual review.
- **Per-op golden tests** for each draw command and ROP variant.
- **libFuzzer** on `SpiceWire`, seeded from recordings.
- **Live** against a local QEMU in the dev loop; not in CI.

## 8. Build and release

SPM for libraries; Xcode project (generated from `project.yml` by xcodegen) for the bundle,
entitlements, and embedding `CSpiceCodec.framework`. Swift 6 strict concurrency. arm64, macOS 14+.
Developer ID, hardened runtime, library-validation entitlement, `notarytool`, stapled DMG,
Sparkle 2 (MIT). Release builds come from `scripts/release.sh` on the developer's Mac and are
uploaded by hand; no CI, no cask. Details and the decisions behind them:
`2026-09-02-spicesee-m7-ship-design.md`.

## 9. Milestones

| | Milestone | Exit criterion |
|---|---|---|
| M0 | Spike | Local SPICE server on this Mac; link handshake prints `MAIN_INIT`. Answers whether Homebrew QEMU has SPICE server support or the dev server lives in a Linux VM. |
| M1 | Pixels | Plain QEMU desktop renders correctly: tier-1 draws, QUIC/GLZ framework, Metal present |
| M2 | Input | Keyboard, mouse both modes, native cursor |
| M3 | Proxmox | Double-click a `.vv` from the web UI and get a console |
| M4 | Canvas complete | Windows/QXL guest with no corruption; MJPEG + H.264 streams |
| M5 | Agent | Clipboard both ways, resize-follows-window, multi-monitor windows |
| M6 | Audio | Opus playback |
| M7 | Ship | Connection manager, prefs, signed/notarized DMG, Sparkle — `scripts/release.sh` stages both |

## References

- spice-mac (recent CocoaSpice-based client): https://github.com/Ching367436/spice-mac
- UTM CocoaSpice: https://github.com/utmapp/CocoaSpice
- Pure-Go SPICE client (existence proof): https://github.com/Shells-com/spice
- Protocol: https://www.spice-space.org/spice-protocol.html
- Debian per-file licence audit for spice-gtk / spice-common:
  https://metadata.ftp-master.debian.org/changelogs/main/s/spice-gtk/unstable_copyright
