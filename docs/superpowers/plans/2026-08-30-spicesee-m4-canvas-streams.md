# SpiceSee M4 (Canvas Complete + Video Streams) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows/QXL guest renders with no corruption — tiers 2 and 3 (general ROPs, brushes, masks, scaled copies, ROP3, TRANSPARENT, STROKE, TEXT) plus the palette cache and JPEG-alpha — and MJPEG/H.264 video streams decode through VideoToolbox and composite over the surface in the Metal pass, with `STREAM_REPORT` feedback so the server adapts bitrate.

**Architecture:** Draw tiers 2–3 are new scanline kernels in `SpiceCanvas` (`Tier2.swift`, `Tier3.swift`) routed from the existing `Canvas` actor — nothing above the canvas changes for them. Streams are *not* drawn into the surface (design spec §4): a new `SpiceMedia` target owns a `VideoDecoder` (one `VTDecompressionSession` path for both MJPEG and H.264) and a `StreamPlayer` actor (stream state, mm-time lateness, report bookkeeping); `SpiceSession` routes stream messages there instead of to the canvas and forwards decoded frames as a new `SessionEvent`. The app composites stream textures over the primary quad in `GuestSurfaceView`'s existing render pass, scissored to the stream clip.

Two deliberate deviations from the spec's ideal, both argued from constraints that bind harder:

1. **Frames cross actor boundaries as `[UInt8]` BGRA, not IOSurface.** Strict concurrency with no `@unchecked Sendable` rules out handing `CVPixelBuffer`/`IOSurface` between actors. The copy cost (1080p30 ≈ 250 MB/s) is well inside what the current draw path already sustains — full-screen HD YouTube plays through today's `[UInt8]`-per-rect pipeline with zero choppiness, and that path does far more CPU work per frame (QUIC decode) than a memcpy. Do not "optimize" this with unsafe Sendable wrappers.
2. **No jitter buffer.** Frames present on decode; a frame late against the mm-clock by more than the drop threshold is counted and discarded. This is the lowest-latency choice and matches the current quality bar; buffering for lip-sync is M6's problem (audio), not M4's. `CADisplayLink` in `GuestSurfaceView` already coalesces to vsync.

**Performance bar (regression gate):** the user can currently play a full-screen YouTube HD video in the guest with zero lag or choppiness through the *draw* path. Nothing in M4 may regress that: no added buffering, no per-frame allocations beyond the one pixel buffer, no main-thread decode. The final task re-verifies this by eye against the real server, both with streaming off (the old path) and on (the new path).

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, vendored SPICE codecs via `CSpiceCodec`, Accelerate/vImage (scaled blits), CoreGraphics (STROKE path rasterization only), VideoToolbox + CoreMedia + CoreVideo (MJPEG/H.264), `spicerec` + `remote-viewer` under `xvfb-run` on the dev box for fixtures.

**Spec:** `docs/superpowers/specs/2026-08-22-spicesee-design.md` — this plan implements §4 (SpiceCanvas: tiers 2–3, mandatory state, video streams, codec routing) and the video half of §5's SpiceMedia, milestone M4. Previous plans: `2026-08-22-spicesee-m0-m1-pixels.md`, `2026-08-24-spicesee-m2-input.md`, `2026-08-24-spicesee-m3-proxmox.md` (all shipped; their Global Constraints still bind).

## Global Constraints

- Swift 6 language mode, strict concurrency. **No locks, no `@unchecked Sendable`, no `nonisolated(unsafe)`** outside the one pre-existing use in `NWTransport.connect`. This is why frames are `[UInt8]`.
- `platforms: [.macOS(.v14)]`, arm64. Dependency rule strictly downward: `SpiceWire` ← `SpiceCore`/`SpiceCanvas`/`SpiceMedia` ← `SpiceKit` ← app. `SpiceMedia` imports `SpiceWire` only (plus system frameworks) — it must never import `SpiceCanvas` or `SpiceCore`, and everything in it runs headless under `swift test`.
- `SpiceWire` is the security boundary: every reader accessor throws, no `!`, no unchecked subscripts, every server-controlled length validated before allocation. A malformed message is a caught error, never a trap. Stream payloads are server-controlled: cap them (`data_size ≤ 1 << 26`, same as images).
- **There is no full-redraw request in the protocol; an unimplemented draw command is permanent corruption.** The `CanvasEvent.unsupported` event is the corruption alarm — never remove it. **Amended 2026-08-30:** the intended M4 exit gate — a real Windows/QXL desktop recording replaying with zero unsupported events — turned out to be unachievable on this hardware and vacuous as a gate. Neither guest on the dev box emits a single tier-2/3 draw command (Windows 11's QXL driver is WDDM; the Linux guest's X server runs `modesetting`, and `xf86-video-qxl` cannot bind — see `docs/dev-server.md`, "Where tier-2/3 draw commands actually come from"). The recording replays with zero unsupported events *before any M4 work*. Tiers 2-3 are therefore gated by unit tests; the real-traffic fixture is a tier-1 regression canary.
- Capability gating is load-bearing scope control: `DisplayChannel.clientCaps()` already advertises `sizedStream`, `streamReport`, `multiCodec`, `codecMjpeg`, `codecH264` — which means **today's client invites stream messages it drops on the floor**; M4 makes the advertisement true. Conversely `composite`, `a8Surface`, `lz4`, `codecVp8/9`, `codecH265` are **not** advertised, the server therefore never sends them, and they are out of M4 scope. Do not add capability bits this plan doesn't name.
- Stream message layouts are transcribed from `spice.proto`; the vendored `enums.h` confirms every constant used here but **no local header confirms the message layouts** (same situation as M3's migration messages). Parse defensively — validate every length against the payload — and treat Task 13's real-server recording as the layout's confirmation. If the recording contradicts a layout, the recording wins.
- Tests use Swift Testing. Fixtures under `Tests/<Target>Tests/Fixtures/`. Commit after every task, conventional-commit prefixes. **Only commit a golden you have actually looked at** (open the PNG and check it is a plausible Windows desktop / video frame, not garbage).
- JPEG and H.264 decodes are not bit-exact across OS releases. Goldens produced through ImageIO/VideoToolbox compare with tolerance (Task 8's `expectClose`), never pixel-exact; QUIC/LZ/GLZ goldens stay exact.
- Library code logs via `os.Logger(subsystem: "com.spicesee", category:)`; no `print` outside executables and tests.
- Input rules from M2 are untouched by this milestone and stay in force.
- Verification habit (memory `spicesee-verification-habits`): self-consistent tests hid two bugs before. The VideoToolbox H.264 round-trip test encodes with VT and decodes with VT — that is self-consistent and this plan says so where it happens; the MJPEG path is verified against a **real spice-server recording** (Task 13), which also confirms the stream wire layouts against the only authority available.
- App seam discipline: views never see SPICE types. M4's sanctioned view-layer changes are exactly two — `GuestSurfaceView` (Metal compositing of stream layers, plus its `MetalSurfaceView` pump) and `SessionModel`'s event routing. If any other view needs editing, the seam is wrong; fix the adapter.

## What cannot be verified in this milestone

Listed here so nobody mistakes green tests for proof:

1. **H.264 from a real server.** The dev box's spice-server streams MJPEG only (H.264 needs a gstreamer-enabled server configuration we cannot switch on remotely with confidence). The H.264 path ships verified against VideoToolbox's own encoder — self-consistent. When a Proxmox or gstreamer server is available, record a session and promote it to a fixture, exactly as Task 13 does for MJPEG.
2. **Hover/full-screen smoothness** can only be judged by eye. Task 14's live check is the user's, like M2's exit check — synthetic input is impossible on this machine.
3. **STREAM_DESTROY_ALL and STREAM_ACTIVATE_REPORT** may not appear in the recorded session (spice-server sends ACTIVATE_REPORT only when built with report support and destroys streams individually on scene change). Their handling is unit-tested from transcribed layouts; flag them in the final report if the recording never exercised them.

## Protocol reference (transcribed; constants confirmed by vendored `enums.h`)

Wire integers are little-endian. "ptr" is a `UInt32` offset into the message body, resolved with the existing `SpiceReader.reader(at:)` / `SpiceImage.at(pointer:base:)` pattern; 0 means absent.

### Draw commands (tiers 2–3)

All start with the existing `DrawBase` (surface_id u32, box Rect, clip Clip).

```
ROP3        (309): src ptr → SpiceImage, src_area Rect, brush Brush, rop3 u8, scale_mode u8, mask QMask
TRANSPARENT (312): src ptr → SpiceImage, src_area Rect, src_color u32, true_color u32
STROKE      (310): path ptr → Path (nonnull), attr LineAttr, brush Brush, fore_mode u16, back_mode u16
TEXT        (311): str ptr → String (nonnull), back_area Rect, fore_brush Brush, back_brush Brush,
                   fore_mode u16, back_mode u16

Path:       num_segments u32, then segments inline sequentially:
PathSeg:    flags u8, count u32, then count × PointFix (x FIXED28_4 i32, y FIXED28_4 i32)
            flags: PATH_BEGIN 1<<0, PATH_END 1<<1, PATH_CLOSE 1<<3, PATH_BEZIER 1<<4
            A FIXED28_4 is the value × 16; divide by 16.0. BEZIER points come in triples
            (control1, control2, end); non-bezier points are line-to.
LineAttr:   flags u8; if flags & LINE_FLAGS_STYLED (1<<3): style_nseg u8, style ptr u32
            (style = style_nseg × FIXED28_4 dash lengths — parse, then ignore: QXL sends solid)
String:     length u16, flags u8, then length × RasterGlyph inline:
RasterGlyph: render_pos Point(2×i32), glyph_origin Point(2×i32), width u16, height u16,
             data[height × bytesPerRow] where bytesPerRow = (width×bpp + 7)/8
            String flags: RASTER_A1 1<<0, RASTER_A4 1<<1, RASTER_A8 1<<2, RASTER_TOP_DOWN 1<<3
            (bpp 1/4/8 accordingly; exactly one of A1/A4/A8 is set). A1 is MSB-first;
            A4 high nibble first. Rows without TOP_DOWN are bottom-up: flip.
QMask:      flags u8 (MASK_FLAGS_INVERS = 1<<0), pos Point, bitmap ptr → SpiceImage (already parsed today)
```

### Stream messages (server → client, display channel)

```
STREAM_CREATE     (122): surface_id u32, id u32, flags u8, codec_type u8, stamp u64,
                         stream_width u32, stream_height u32, src_width u32, src_height u32,
                         dest Rect, clip Clip
                         flags: STREAM_FLAGS_TOP_DOWN = 1<<0 (enums.h:158)
                         codec_type: MJPEG=1, VP8=2, H264=3, VP9=4, H265=5 (enums.h:148)
STREAM_DATA       (123): id u32, multi_media_time u32, data_size u32, data[data_size]
STREAM_CLIP       (124): id u32, clip Clip
STREAM_DESTROY    (125): id u32
STREAM_DESTROY_ALL(126): (empty)
STREAM_DATA_SIZED (316): id u32, multi_media_time u32, width u32, height u32, dest Rect,
                         data_size u32, data[data_size]
STREAM_ACTIVATE_REPORT (319): stream_id u32, unique_id u32, max_window_size u32, timeout_ms u32
```

### Client → server

```
STREAM_REPORT (102 on display channel = DisplayClientMsg.streamReport):
    stream_id u32, unique_id u32, start_frame_mm_time u32, end_frame_mm_time u32,
    num_frames u32, num_drops u32, last_frame_delay i32, audio_delay u32
    (audio_delay = UInt32.max when no audio is playing — M6 will wire the real value)
```

### ROP descriptor semantics (per spice-common `canvas_base.c`)

`rop` is the u16 ROPD bitfield already in `Geometry.swift`. Effective per-byte combine of source value `s` (image pixel or brush pixel) with dest `d`:

1. If `INVERS_SRC` (image ops) or `INVERS_BRUSH` (brush ops): `s = ~s`.
2. If `INVERS_DEST`: `d = ~d`.
3. Exactly one op bit: `PUT → s`, `OR → d|s`, `AND → d&s`, `XOR → d^s`, `BLACKNESS → 0`, `WHITENESS → 0xFF`, `INVERS → ~d`.
4. If `INVERS_RES`: invert the result.

Alpha byte is forced to 0xFF after every tier-2 write. `OPAQUE` = scale/copy src into a temp, rop-combine the *brush* into the temp, blit the temp through the mask. `BLEND` = `COPY` that honours `rop` against dest. ROP3 codes are Windows ternary ops: result bit = `(code >> ((p<<2)|(s<<1)|d)) & 1` (SRCCOPY 0xCC, PATCOPY 0xF0 confirm the bit order).

## File Structure

```
Sources/SpiceWire/Geometry.swift            MODIFY  + SpicePath, SpiceLineAttr, SpiceString, glyph + flag enums, MaskFlags
Sources/SpiceWire/DisplayMessages.swift     MODIFY  + DrawRop3, DrawTransparent, DrawStroke, DrawText cases & parsing
Sources/SpiceWire/StreamMessages.swift      CREATE  stream message structs; DisplayMessage stream cases parse here
Sources/SpiceWire/ClientMessages.swift      MODIFY  + streamReport encoder
Sources/SpiceCanvas/PaletteCache.swift      CREATE  palette id → SpicePalette, wired to INVAL_PALETTE(S)
Sources/SpiceCanvas/ImageDecoder.swift      MODIFY  palette-cache plumbing, JPEG-alpha decode
Sources/SpiceCanvas/Tier2.swift             CREATE  rop combine, PixelSource (image/solid/pattern), mask, scaled blit
Sources/SpiceCanvas/Tier3.swift             CREATE  STROKE path rasterization, TEXT glyph blits (both feed Tier2)
Sources/SpiceCanvas/Canvas.swift            MODIFY  route fill/copy/blend/opaque through Tier2; new command cases
Sources/SpiceMedia/VideoDecoder.swift       CREATE  one VTDecompressionSession wrapper: MJPEG + H.264 Annex-B
Sources/SpiceMedia/StreamPlayer.swift       CREATE  actor: stream state, mm clock, drops, STREAM_REPORT bookkeeping
Sources/SpiceCore/DisplayChannel.swift      MODIFY  + send(streamReport:)
Sources/SpiceKit/SpiceSession.swift         MODIFY  route stream msgs to StreamPlayer, mm-time, new SessionEvents
Sources/SpiceSee/SessionBackend.swift       MODIFY  + StreamFrameUpdate, GuestRect, stream Backend/Viewport events
Sources/SpiceSee/SpiceKitBackend.swift      MODIFY  map stream SessionEvents to seam events
Sources/SpiceSee/SessionModel.swift         MODIFY  route stream events to viewport subscribers
Sources/SpiceSee/MetalSurfaceView.swift     MODIFY  stream layers composited over primary quad (sanctioned)
Package.swift                               MODIFY  + SpiceMedia target, SpiceMediaTests, SpiceKit dep
Tests/SpiceWireTests/DisplayMessageTests.swift   MODIFY  tier-2/3 parse tests
Tests/SpiceWireTests/StreamMessageTests.swift    CREATE  stream parse + report encode tests
Tests/SpiceCanvasTests/Tier2Tests.swift          CREATE
Tests/SpiceCanvasTests/Tier3Tests.swift          CREATE  stroke + text
Tests/SpiceCanvasTests/ImageDecoderTests.swift   MODIFY  palette cache + jpeg-alpha
Tests/SpiceMediaTests/VideoDecoderTests.swift    CREATE
Tests/SpiceMediaTests/StreamPlayerTests.swift    CREATE
Tests/SpiceKitTests/ReplayTests.swift            MODIFY  win-desktop replay (inventory → golden), win-video replay
Tests/SpiceKitTests/StreamSessionTests.swift     CREATE  session-level stream routing + report send
Tests/SpiceSeeTests/StreamSeamTests.swift        CREATE  SessionEvent → BackendEvent mapping
docs/dev-server.md                          MODIFY  M4 recording notes + exit check
CLAUDE.md                                   MODIFY  architecture paragraph: M4 shipped, M5 next
```

---

### Task 1: Record the installed Windows/QXL desktop and inventory what it draws

The whole milestone is aimed at "Windows/QXL guest with no corruption", so the first artifact is a recording of the *installed* guest (QXL driver, real desktop) that exercises tier-2/3 commands. This fixture is the ground truth every later task renders against; its golden is written in Task 8, once rendering is complete. Streaming stays **off** for this recording — check for `STREAM_CREATE` before promoting, per `docs/dev-server.md`.

**Files:**
- Create: `Tests/SpiceKitTests/Fixtures/win-desktop.s2c.bin` (recorded)
- Modify: `Tests/SpiceKitTests/ReplayTests.swift`
- Modify: `docs/dev-server.md` (record what was captured, like the existing fixture table)

**Interfaces:**
- Produces: the `win-desktop.s2c.bin` fixture and `winDesktopReplayCompletes` test that Tasks 4–8 run against. Task 8 replaces the lenient assertion with the strict golden gate.

- [x] **Step 1: Confirm the dev server is up and the guest is at a desktop**

```bash
scripts/dev-server.sh
swift run spicesee-cli dump 192.168.50.6 5930 5 /private/tmp/claude-501/-Users-aaronpollock-code-spicesee/*/scratchpad/desktop-check.png
```

Look at the PNG. It must show a Windows desktop (not the installer, not a lock screen). If it shows a lock screen, ask the user to unlock the guest — do not guess at credentials.

- [x] **Step 2: Record a desktop session with driven activity**

The xdotool recipe from `docs/dev-server.md` (`### Recording input`), adapted to generate tier-2/3 traffic: right-click menus (TRANSPARENT/alpha), window drags (COPY_BITS, ROPs), text selection (INVERS/XOR). Guest is in client mouse mode, so absolute positioning works unfocused.

```bash
# here (MACIP as seen from the box is 192.168.4.3 — VPN address, see docs/dev-server.md)
swift run spicerec 5901 192.168.50.6 5930 recordings/win-desktop &
ssh aaron@192.168.50.6 'cat > /tmp/drive-desktop.sh' <<'EOF'
#!/bin/sh
remote-viewer spice://192.168.4.3:5901 &
sleep 8
W=$(xdotool search --sync --classname remote-viewer | tail -1)
xdotool mousemove --window $W 640 400; sleep 0.5
xdotool click 3;  sleep 1.5                       # desktop context menu: alpha/transparent draws
xdotool key Escape; sleep 0.5
xdotool click 1;  sleep 0.5
xdotool key super; sleep 2                        # start menu: rich mixed drawing
xdotool key Escape; sleep 0.5
xdotool mousemove --window $W 200 200
xdotool mousedown 1
for X in 220 260 300 340 380 420 460 500; do xdotool mousemove --window $W $X 250; sleep 0.15; done
xdotool mouseup 1; sleep 1                        # drag selection rectangle: XOR/INVERS
sleep 2
kill %1
EOF
ssh aaron@192.168.50.6 "timeout 45 xvfb-run -a -s '-screen 0 1280x1024x24' sh /tmp/drive-desktop.sh"
wait
```

- [x] **Step 3: Verify the recording has draws and no streams, promote it**

```bash
ls -la recordings/win-desktop/
# Identify the display channel capture (largest s2c after main; the spicerec output names channels).
# Check for STREAM_CREATE (type 122) — with streaming off there must be none; a crude scan is fine:
# replay it through the inventory test below and confirm no unsupported type 122.
cp recordings/win-desktop/<display-conn>.s2c.bin Tests/SpiceKitTests/Fixtures/win-desktop.s2c.bin
```

The raw recording directory stays gitignored, as with the existing fixtures.

- [x] **Step 4: Write the inventory replay test**

Append to `Tests/SpiceKitTests/ReplayTests.swift`:

```swift
/// Replays the installed Windows/QXL desktop recording. Until M4's tiers land this only proves
/// the stack survives the traffic and reports what it cannot draw; Task 8 tightens it to a
/// zero-unsupported golden compare. The printed tally is the milestone's work list.
@Test func winDesktopReplayCompletes() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-desktop.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let t = InMemoryTransport(input: [UInt8](try Data(contentsOf: url)))
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    let collector = Task {
        var tally: [String: Int] = [:]
        for await e in canvas.events { if case let .unsupported(what) = e { tally[what, default: 0] += 1 } }
        return tally
    }
    for await m in channel.messages { await canvas.apply(m) }
    await canvas.finish()
    let tally = await collector.value
    for (what, n) in tally.sorted(by: { $0.value > $1.value }) { print("unsupported ×\(n): \(what)") }
    let id = try #require(await canvas.primarySurfaceID)
    #expect(await canvas.snapshot(surfaceID: id) != nil)
}
```

- [x] **Step 5: Run it and record the inventory**

```bash
swift test --filter winDesktopReplayCompletes 2>&1 | grep -E "unsupported|passed|failed"
```

Expected: PASS, with a printed tally (e.g. `display message 317`, `copy rop/mask/scale → drawn as PUT`, …). Paste the tally into the commit message and into `docs/dev-server.md` next to the fixture description — it is the evidence for what Tasks 2–7 must cover. If the tally is empty, the recording didn't exercise QXL drawing; redo Step 2 with more activity before proceeding.

- [x] **Step 6: Commit**

```bash
git add Tests/SpiceKitTests/Fixtures/win-desktop.s2c.bin Tests/SpiceKitTests/ReplayTests.swift docs/dev-server.md
git commit -m "test(kit): record installed Windows/QXL desktop fixture with draw inventory"
```

---

### Task 2: Wire parsing for ROP3, TRANSPARENT, STROKE, TEXT

**Files:**
- Modify: `Sources/SpiceWire/Geometry.swift`
- Modify: `Sources/SpiceWire/DisplayMessages.swift`
- Test: `Tests/SpiceWireTests/DisplayMessageTests.swift`

**Interfaces:**
- Consumes: existing `SpiceReader`, `SpiceWriter`, `DrawBase`, `SpiceBrush`, `SpiceQMask`, `SpiceImage.at(pointer:base:)`.
- Produces (for Tasks 4–7):
  - `public enum MaskFlags { static let invers: UInt8 = 1 }` in Geometry.swift
  - `public struct SpicePathSegment: Sendable, Equatable { var flags: UInt8; var points: [SpicePoint] }` where points are already divided by 16 into… **no** — keep FIXED28_4 raw: `public struct FixedPoint: Sendable, Equatable { public var x, y: Int32 }` (value × 16), with `public var cgX: Double { Double(x) / 16 }`, `cgY` likewise
  - `public struct SpicePath: Sendable, Equatable { public var segments: [SpicePathSegment] }`
  - `public enum PathFlags { public static let begin: UInt8 = 1, end: UInt8 = 2, close: UInt8 = 8, bezier: UInt8 = 16 }`
  - `public struct SpiceLineAttr: Sendable, Equatable { public var flags: UInt8 }` (styled dash array parsed and discarded)
  - `public enum StringFlags { public static let rasterA1: UInt16 = 1, rasterA4: UInt16 = 2, rasterA8: UInt16 = 4, topDown: UInt16 = 8 }`
  - `public struct RasterGlyph: Sendable, Equatable { public var renderPos: SpicePoint; public var origin: SpicePoint; public var width, height: UInt16; public var data: [UInt8] }`
  - `public struct SpiceString: Sendable, Equatable { public var flags: UInt16; public var glyphs: [RasterGlyph] }  // `flags` is read as u8 from the wire and widened; see the corrected table above`
  - `public struct DrawRop3: Sendable, Equatable { public var base: DrawBase; public var source: SpiceImage?; public var sourceArea: SpiceRect; public var brush: SpiceBrush; public var rop3: UInt8; public var scaleMode: UInt8; public var mask: SpiceQMask }`
  - `public struct DrawTransparent: Sendable, Equatable { public var base: DrawBase; public var source: SpiceImage?; public var sourceArea: SpiceRect; public var srcColor: UInt32; public var trueColor: UInt32 }`
  - `public struct DrawStroke: Sendable, Equatable { public var base: DrawBase; public var path: SpicePath; public var attr: SpiceLineAttr; public var brush: SpiceBrush; public var foreMode: UInt16; public var backMode: UInt16 }`
  - `public struct DrawText: Sendable, Equatable { public var base: DrawBase; public var str: SpiceString; public var backArea: SpiceRect; public var foreBrush: SpiceBrush; public var backBrush: SpiceBrush; public var foreMode: UInt16; public var backMode: UInt16 }`
  - `DisplayMessage` cases `.rop3(DrawRop3)`, `.transparent(DrawTransparent)`, `.stroke(DrawStroke)`, `.text(DrawText)`

- [x] **Step 1: Write failing parse tests**

Append to `Tests/SpiceWireTests/DisplayMessageTests.swift` (the `base()` helper exists at the top of the file):

```swift
@Test func drawTransparentParses() throws {
    var w = base()
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(8); w.i32(8)     // src_area
    w.u32(0x00FF00); w.u32(0x00FF00)            // src_color, true_color
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(1); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(8); w.u32(8)
    let m = try DisplayMessage(type: DisplayServerMsg.drawTransparent.rawValue, payload: w.bytes)
    guard case let .transparent(t) = m else { Issue.record("case"); return }
    #expect(t.trueColor == 0x00FF00 && t.sourceArea.width == 8)
}

@Test func drawRop3Parses() throws {
    var w = base()
    let ptr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(4); w.i32(4)
    w.u8(1); w.u32(0x0000FF)                    // brush solid blue
    w.u8(0xCC); w.u8(0)                          // rop3 SRCCOPY, scale interpolate
    w.u8(0); w.i32(0); w.i32(0); w.u32(0)        // no mask
    w.patchU32(at: ptr, UInt32(w.bytes.count))
    w.u64(2); w.u8(ImageType.fromCache.rawValue); w.u8(0); w.u32(4); w.u32(4)
    let m = try DisplayMessage(type: DisplayServerMsg.drawRop3.rawValue, payload: w.bytes)
    guard case let .rop3(r) = m else { Issue.record("case"); return }
    #expect(r.rop3 == 0xCC && r.brush == .solid(0x0000FF))
}

@Test func drawStrokeParsesPath() throws {
    var w = base()
    let pathPtr = w.bytes.count; w.u32(0)
    w.u8(0)                                      // line attr: plain
    w.u8(1); w.u32(0xFF0000)                     // brush solid red
    w.u16(ROPD.opPut); w.u16(ROPD.opPut)         // fore_mode, back_mode
    w.patchU32(at: pathPtr, UInt32(w.bytes.count))
    w.u32(1)                                     // one segment
    w.u8(PathFlags.begin | PathFlags.end); w.u32(2)
    w.i32(10 * 16); w.i32(10 * 16)               // FIXED28_4: (10,10)
    w.i32(50 * 16); w.i32(10 * 16)               // (50,10)
    let m = try DisplayMessage(type: DisplayServerMsg.drawStroke.rawValue, payload: w.bytes)
    guard case let .stroke(s) = m else { Issue.record("case"); return }
    #expect(s.path.segments.count == 1)
    #expect(s.path.segments[0].points == [FixedPoint(x: 160, y: 160), FixedPoint(x: 800, y: 160)])
    #expect(s.brush == .solid(0xFF0000))
}

@Test func drawTextParsesGlyphs() throws {
    var w = base()
    let strPtr = w.bytes.count; w.u32(0)
    w.i32(0); w.i32(0); w.i32(0); w.i32(0)       // back_area empty
    w.u8(1); w.u32(0xFFFFFF)                     // fore solid white
    w.u8(0)                                      // back brush none
    w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: strPtr, UInt32(w.bytes.count))
    w.u16(1); w.u16(StringFlags.rasterA1 | StringFlags.topDown)
    w.i32(5); w.i32(7); w.i32(0); w.i32(0)       // render_pos (5,7), origin (0,0)
    w.u16(8); w.u16(2)                            // 8×2 → 1 byte/row A1
    w.bytes([0b1010_1010, 0b0101_0101])
    let m = try DisplayMessage(type: DisplayServerMsg.drawText.rawValue, payload: w.bytes)
    guard case let .text(t) = m else { Issue.record("case"); return }
    #expect(t.str.glyphs.count == 1 && t.str.glyphs[0].data.count == 2)
    #expect(t.str.glyphs[0].renderPos == SpicePoint(x: 5, y: 7))
}

@Test func strokeRejectsOversizedPath() throws {
    var w = base()
    let pathPtr = w.bytes.count; w.u32(0)
    w.u8(0); w.u8(1); w.u32(0xFF0000); w.u16(ROPD.opPut); w.u16(ROPD.opPut)
    w.patchU32(at: pathPtr, UInt32(w.bytes.count))
    w.u32(1)
    w.u8(PathFlags.begin); w.u32(0xFFFF_FFFF)    // hostile point count
    #expect(throws: WireError.self) {
        _ = try DisplayMessage(type: DisplayServerMsg.drawStroke.rawValue, payload: w.bytes)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter DisplayMessageTests` — expected: compile errors (`PathFlags`, `.transparent` etc. undefined).

- [x] **Step 3: Implement the types and parsing**

In `Geometry.swift`, after `SpiceBrush`:

```swift
public enum MaskFlags { public static let invers: UInt8 = 1 }
public enum PathFlags { public static let begin: UInt8 = 1, end: UInt8 = 2, close: UInt8 = 8, bezier: UInt8 = 16 }
public enum StringFlags { public static let rasterA1: UInt16 = 1, rasterA4: UInt16 = 2, rasterA8: UInt16 = 4, topDown: UInt16 = 8 }

/// FIXED28_4: the wire value is the coordinate × 16.
public struct FixedPoint: Sendable, Equatable {
    public var x, y: Int32
    public var cgX: Double { Double(x) / 16 }
    public var cgY: Double { Double(y) / 16 }
    public init(x: Int32, y: Int32) { self.x = x; self.y = y }
    public init(reader r: inout SpiceReader) throws { x = try r.i32(); y = try r.i32() }
}

public struct SpicePathSegment: Sendable, Equatable {
    public var flags: UInt8
    public var points: [FixedPoint]
}

public struct SpicePath: Sendable, Equatable {
    public var segments: [SpicePathSegment]
    public init(reader r: inout SpiceReader) throws {
        let n = try r.u32()
        guard n <= 1 << 16 else { throw WireError.badValue(field: "num_segments", value: UInt64(n)) }
        segments = try (0 ..< n).map { _ in
            let flags = try r.u8()
            let count = try r.u32()
            guard count <= 1 << 16 else { throw WireError.badValue(field: "seg_count", value: UInt64(count)) }
            return SpicePathSegment(flags: flags, points: try (0 ..< count).map { _ in try FixedPoint(reader: &r) })
        }
    }
}

public struct SpiceLineAttr: Sendable, Equatable {
    public var flags: UInt8
    /// The styled dash array is parsed for reader position but discarded: QXL strokes solid lines.
    public init(reader r: inout SpiceReader) throws {
        flags = try r.u8()
        if flags & 8 != 0 { _ = try r.u8(); _ = try r.u32() }   // style_nseg, style ptr
    }
}

public struct RasterGlyph: Sendable, Equatable {
    public var renderPos: SpicePoint, origin: SpicePoint
    public var width, height: UInt16
    public var data: [UInt8]
}

public struct SpiceString: Sendable, Equatable {
    public var flags: UInt16
    public var glyphs: [RasterGlyph]
    public var bitsPerPixel: Int { flags & StringFlags.rasterA8 != 0 ? 8 : flags & StringFlags.rasterA4 != 0 ? 4 : 1 }
    public init(reader r: inout SpiceReader) throws {
        let length = try r.u16()
        flags = try r.u16()
        let bpp = flags & StringFlags.rasterA8 != 0 ? 8 : flags & StringFlags.rasterA4 != 0 ? 4 : 1
        glyphs = try (0 ..< length).map { _ in
            let renderPos = try SpicePoint(reader: &r), origin = try SpicePoint(reader: &r)
            let w = try r.u16(), h = try r.u16()
            let rowBytes = (Int(w) * bpp + 7) / 8
            let size = rowBytes * Int(h)
            guard size <= 1 << 20 else { throw WireError.badValue(field: "glyph_size", value: UInt64(size)) }
            return RasterGlyph(renderPos: renderPos, origin: origin, width: w, height: h, data: try r.bytes(size))
        }
    }
}
```

In `DisplayMessages.swift`, the four structs (shapes given under Interfaces; each `init(reader:body:)` follows the exact field order in the protocol reference, resolving `path`/`str` pointers with `body.reader(at:)` and throwing `WireError.badValue(field: "path", value: 0)` when the nonnull pointer is 0), the four enum cases, and the four `switch` arms replacing `default` fall-through for types 310/311/312/317.

- [x] **Step 4: Run to verify pass**

Run: `swift test --filter DisplayMessageTests` — expected: all PASS, including the pre-existing tests.

- [x] **Step 5: Handle the new cases in Canvas (compile fix only)**

`Canvas.applyThrowing` must stay exhaustive. Add a temporary arm so the package builds; Tasks 5–7 replace it:

```swift
case let .rop3(r): throw CanvasError.unsupported("rop3 \(r.rop3) (task 5)")
case let .transparent(t): _ = t; throw CanvasError.unsupported("transparent (task 5)")
case .stroke: throw CanvasError.unsupported("stroke (task 6)")
case .text: throw CanvasError.unsupported("text (task 7)")
```

Run: `swift build && swift test` — expected: everything passes (the desktop replay still prints its tally; the tally strings change from `display message 317` to `rop3 …`).

- [x] **Step 6: Commit**

```bash
git add Sources/SpiceWire/Geometry.swift Sources/SpiceWire/DisplayMessages.swift Sources/SpiceCanvas/Canvas.swift Tests/SpiceWireTests/DisplayMessageTests.swift
git commit -m "feat(wire): parse ROP3, TRANSPARENT, STROKE and TEXT draw commands"
```

---

### Task 3: Palette cache and JPEG-alpha

Two decoder gaps that are silent corruption on palettized/translucent images: `palFromCache` bitmaps decode against a nil palette today, and `jpegAlpha` throws unsupported.

**Files:**
- Create: `Sources/SpiceCanvas/PaletteCache.swift`
- Modify: `Sources/SpiceCanvas/ImageDecoder.swift`, `Sources/SpiceCanvas/Canvas.swift`
- Modify: `Packages/CSpiceCodec/Sources/CSpiceCodec/codec_bridge.c` + `include/spice_codec.h` (one test-only encoder)
- Test: `Tests/SpiceCanvasTests/ImageDecoderTests.swift`

**Interfaces:**
- Produces: `public struct PaletteCache: Sendable { subscript(id: UInt64) -> SpicePalette?; mutating func store(_:); mutating func remove(_ id: UInt64); mutating func removeAll() }`; `ImageDecoder.decode(_:cache:palettes:)` gains the palette parameter (`inout PaletteCache`); `sc_lz_encode_xxxa` in the bridge (test helper).

- [x] **Step 1: Write failing tests**

In `Tests/SpiceCanvasTests/ImageDecoderTests.swift` (follow the file's existing builder style):

```swift
@Test func bitmapPaletteRoundTripsThroughCache() throws {
    // An 8-bit bitmap with an inline palette flagged PAL_CACHE_ME, then the same image
    // with PAL_FROM_CACHE referencing the id: both must decode to the same pixels.
    var palettes = PaletteCache()
    let pal = SpicePalette(id: 9, entries: [0x0000FF, 0x00FF00] + Array(repeating: 0, count: 254))
    let withPal = SpiceBitmap(format: .bit8, flags: BitmapFlags.palCacheMe | BitmapFlags.topDown,
                              width: 2, height: 1, stride: 2, palette: pal, paletteID: nil, data: [0, 1])
    var d = ImageDecoder()
    let first = try d.decodeBitmap(withPal, palettes: &palettes)
    #expect(first.pixel(x: 0, y: 0) & 0xFFFFFF == 0x0000FF)
    let fromCache = SpiceBitmap(format: .bit8, flags: BitmapFlags.palFromCache | BitmapFlags.topDown,
                                width: 2, height: 1, stride: 2, palette: nil, paletteID: 9, data: [0, 1])
    let second = try d.decodeBitmap(fromCache, palettes: &palettes)
    #expect(second.pixels == first.pixels)
}

@Test func missingCachedPaletteThrows() throws {
    var palettes = PaletteCache()
    let b = SpiceBitmap(format: .bit8, flags: BitmapFlags.palFromCache, width: 1, height: 1,
                        stride: 1, palette: nil, paletteID: 42, data: [0])
    var d = ImageDecoder()
    #expect(throws: CanvasError.self) { _ = try d.decodeBitmap(b, palettes: &palettes) }
}

@Test func jpegAlphaCarriesTheAlphaPlane() throws {
    // RGB from a solid red JPEG, alpha from an LZ XXXA plane encoded by the bridge test helper.
    let w = 8, h = 8
    let red = try PNGFixtures.solidJPEG(width: w, height: h, r: 255, g: 0, b: 0)   // helper below
    var alphaPixels = [UInt8](repeating: 0, count: w * h * 4)
    for i in stride(from: 3, to: alphaPixels.count, by: 4) { alphaPixels[i] = 0x80 }
    var lz = [UInt8](repeating: 0, count: 1 << 16)
    let n = alphaPixels.withUnsafeBufferPointer { src in lz.withUnsafeMutableBufferPointer { dst in
        sc_lz_encode_xxxa(src.baseAddress, Int32(w), Int32(h), Int32(w * 4), dst.baseAddress, dst.count) } }
    #expect(n > 0)
    let payload = ImagePayload.jpegAlpha(flags: 1, jpegSize: UInt32(red.count), data: red + lz[0 ..< Int(n)])
    let desc = SpiceImageDescriptor(id: 0, type: .jpegAlpha, flags: 0, width: UInt32(w), height: UInt32(h))
    var d = ImageDecoder(); var palettes = PaletteCache()
    let img = try d.decode(SpiceImage(descriptor: desc, payload: payload), cache: nil, palettes: &palettes)
    #expect(img.hasAlpha)
    #expect(img.pixels[3] == 0x80)                       // alpha from the LZ plane
    #expect(img.pixels[2] > 200 && img.pixels[0] < 50)   // red from the JPEG (tolerance: lossy)
}
```

`PNGFixtures.solidJPEG` is a ~10-line test helper using `CGContext` + `CGImageDestination` with type `public.jpeg`; put it in the test file. Note `SpiceImageDescriptor`/`SpiceBitmap`/`SpiceImage` need memberwise inits usable from tests — they are `public struct`s whose fields are public; add `public init(...)` memberwise initializers where missing (wire structs currently only have `init(reader:)`).

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter ImageDecoderTests` — expected: compile errors (no `PaletteCache`, no `decodeBitmap(_:palettes:)`, no `sc_lz_encode_xxxa`).

- [x] **Step 3: Implement**

`PaletteCache.swift` mirrors `ImageCache` (a `[UInt64: SpicePalette]` dictionary, same four members). In `ImageDecoder`:

- `decode` gains `palettes: inout PaletteCache`; `decodeBitmap` becomes an instance method taking `palettes`, resolving `paletteID` via the cache (throw `CanvasError.cacheMiss(id)` on miss) and storing when `flags & BitmapFlags.palCacheMe != 0`; same resolution for `lzPlt`'s `paletteID`.
- `jpegAlpha`: `data` is `jpegSize` bytes of JPEG followed by an LZ XXXA image. Decode the JPEG with the existing `Self.decodeJPEG`, then run `sc_lz_begin`/`sc_lz_decode` over the remainder into the *same* buffer — the vendored XXXA template writes only byte 3 of each 4-byte pixel. Verify the LZ header type is XXXA (`SC_IMAGE_XXXA`) and dimensions match, flip rows when `top_down == 0` (flip *before* the alpha merge is wrong — the LZ decode writes into the final buffer, so decode into a scratch BGRA buffer, flip that if needed, then copy its alpha bytes across). `flags & 1` is the jpeg-alpha top-down flag for the alpha plane. Return `hasAlpha: true`.
- Bridge: `sc_lz_encode_xxxa(const uint8_t *pixels, int width, int height, int stride, uint8_t *out, size_t cap)` — same shape as the existing `sc_lz_encode_rgb32` but with `LZ_IMAGE_TYPE_XXXA`. Test-only, mirrors the existing encoder precedent.
- `Canvas`: hold `private var palettes = PaletteCache()`, pass it to `decoder.decode`, and wire `case let .invalPalette(id): palettes.remove(id)` and `case .invalAllPalettes: palettes.removeAll()` (both currently `break`).

- [x] **Step 4: Run to verify pass**

Run: `swift test --filter ImageDecoderTests && swift test` — expected: PASS, no regressions.

- [x] **Step 5: Commit**

```bash
git add Sources/SpiceCanvas Packages/CSpiceCodec Tests/SpiceCanvasTests/ImageDecoderTests.swift
git commit -m "feat(canvas): palette cache and JPEG-alpha decode"
```

---

### Task 4: Tier 2 — ROP combine, brushes, masks, scaled blits

The core of "no corruption": every `fill`/`copy`/`blend`/`opaque` that today silently draws as PUT (the `.unsupported("… → drawn as PUT")` shims in `Canvas.applyThrowing`) renders correctly instead.

**Files:**
- Create: `Sources/SpiceCanvas/Tier2.swift`
- Modify: `Sources/SpiceCanvas/Canvas.swift`
- Test: `Tests/SpiceCanvasTests/Tier2Tests.swift`

**Interfaces:**
- Consumes: `Surface` (internal to SpiceCanvas), `DecodedImage`, `ROPD`, `MaskFlags`, `SpiceQMask`.
- Produces (used by Tasks 5–7):

```swift
enum PixelSource {
    case image(DecodedImage, origin: SpicePoint)      // src pixel for (x,y) in rect: origin + offset
    case solid(UInt32)                                 // 0x00RRGGBB, SPICE brush color order
    case pattern(DecodedImage, seed: SpicePoint)       // tiled; seed is the pattern origin in surface coords
}
struct ResolvedMask {                                  // 8-bit coverage, 0 = skip, else apply
    var width: Int, height: Int, origin: SpicePoint    // origin = mask.pos for the draw rect
    var coverage: [UInt8]
}
enum Tier2 {
    static func draw(_ dst: Surface, rect: SpiceRect, source: PixelSource, rop: UInt16, mask: ResolvedMask?)
    static func ropCombine(dst: UInt8, src: UInt8, rop: UInt16) -> UInt8
    static func scaled(_ src: DecodedImage, from: SpiceRect, toWidth: Int, toHeight: Int, nearest: Bool) -> DecodedImage
}
```

`Canvas` gains `resolveMask(_ mask: SpiceQMask, for rect: SpiceRect) throws -> ResolvedMask?` (nil when `mask.bitmap == nil`) — decode the mask image through the normal `resolve` path, threshold any non-black pixel to coverage 255, invert when `mask.flags & MaskFlags.invers != 0`.

- [x] **Step 1: Write failing kernel tests**

`Tests/SpiceCanvasTests/Tier2Tests.swift` (Surface is internal: `@testable import SpiceCanvas`):

```swift
import Testing
import SpiceWire
@testable import SpiceCanvas

private func surface(_ w: Int, _ h: Int, fill: UInt8) -> Surface {
    let s = Surface(id: 0, width: w, height: h, isPrimary: true)
    for i in 0 ..< s.pixels.count where i % 4 != 3 { s.pixels[i] = fill }
    return s
}

@Test func ropCombineTruthTable() {
    // dst 0b1100, src 0b1010 — every op, from the semantics in canvas_base.c.
    let d: UInt8 = 0b1100, s: UInt8 = 0b1010
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opPut) == s)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opOr) == 0b1110)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opAnd) == 0b1000)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opXor) == 0b0110)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opBlackness) == 0)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opWhiteness) == 0xFF)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opInvers) == ~d)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opPut | ROPD.inversSrc) == ~s)
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opAnd | ROPD.inversDest) == (~d & s))
    #expect(Tier2.ropCombine(dst: d, src: s, rop: ROPD.opOr | ROPD.inversRes) == ~(d | s))
}

@Test func solidFillWithXor() {
    let s = surface(2, 1, fill: 0b1100)
    Tier2.draw(s, rect: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
               source: .solid(0x0A0A0A), rop: ROPD.opXor, mask: nil)
    #expect(s.pixels[0] == 0b1100 ^ 0x0A)
    #expect(s.pixels[3] == 0xFF)                       // alpha forced opaque
}

@Test func patternTilesFromSeed() {
    // 2×1 pattern [red, blue] seeded at x=1: surface x=0 samples pattern x=(0-1) mod 2 = 1 → blue.
    let pat = DecodedImage(width: 2, height: 1,
                           pixels: [0,0,255,255, 255,0,0,255], hasAlpha: false)   // BGRA: red, blue
    let s = surface(4, 1, fill: 0)
    Tier2.draw(s, rect: SpiceRect(top: 0, left: 0, bottom: 1, right: 4),
               source: .pattern(pat, seed: SpicePoint(x: 1, y: 0)), rop: ROPD.opPut, mask: nil)
    #expect(s.pixels[0] == 255 && s.pixels[2] == 0)    // x=0 blue
    #expect(s.pixels[4] == 0 && s.pixels[6] == 255)    // x=1 red
}

@Test func maskGatesTheWrite() {
    let s = surface(2, 1, fill: 0x11)
    let mask = ResolvedMask(width: 2, height: 1, origin: SpicePoint(x: 0, y: 0), coverage: [255, 0])
    Tier2.draw(s, rect: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
               source: .solid(0xFFFFFF), rop: ROPD.opPut, mask: mask)
    #expect(s.pixels[0] == 0xFF)                       // covered pixel written
    #expect(s.pixels[4] == 0x11)                       // uncovered pixel untouched
}

@Test func scaledNearestDoublesPixels() {
    let src = DecodedImage(width: 2, height: 1, pixels: [1,1,1,255, 9,9,9,255], hasAlpha: false)
    let out = Tier2.scaled(src, from: SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
                           toWidth: 4, toHeight: 1, nearest: true)
    #expect(out.pixels[0] == 1 && out.pixels[4] == 1 && out.pixels[8] == 9 && out.pixels[12] == 9)
}
```

- [x] **Step 2: Run to verify failure**

Run: `swift test --filter Tier2Tests` — expected: compile errors.

- [x] **Step 3: Implement `Tier2.swift`**

```swift
import Accelerate
import SpiceWire

enum PixelSource { /* as in Interfaces */ }
struct ResolvedMask { /* as in Interfaces */
    func covers(x: Int, y: Int) -> Bool {
        let mx = x - Int(origin.x), my = y - Int(origin.y)
        guard mx >= 0, mx < width, my >= 0, my < height else { return false }
        return coverage[my * width + mx] != 0
    }
}

enum Tier2 {
    static func ropCombine(dst: UInt8, src: UInt8, rop: UInt16) -> UInt8 {
        // INVERS_SRC and INVERS_BRUSH both invert the incoming value; the caller passes whichever
        // pixel stream the command names, so one flag check covers both.
        let s = rop & (ROPD.inversSrc | ROPD.inversBrush) != 0 ? ~src : src
        let d = rop & ROPD.inversDest != 0 ? ~dst : dst
        var r: UInt8
        if rop & ROPD.opPut != 0 { r = s }
        else if rop & ROPD.opOr != 0 { r = d | s }
        else if rop & ROPD.opAnd != 0 { r = d & s }
        else if rop & ROPD.opXor != 0 { r = d ^ s }
        else if rop & ROPD.opBlackness != 0 { r = 0 }
        else if rop & ROPD.opWhiteness != 0 { r = 0xFF }
        else if rop & ROPD.opInvers != 0 { r = ~d }
        else { r = s }
        if rop & ROPD.inversRes != 0 { r = ~r }
        return r
    }

    static func draw(_ dst: Surface, rect: SpiceRect, source: PixelSource, rop: UInt16, mask: ResolvedMask?) {
        for y in Int(rect.top) ..< Int(rect.bottom) {
            for x in Int(rect.left) ..< Int(rect.right) {
                if let mask, !mask.covers(x: x, y: y) { continue }
                let (b, g, r): (UInt8, UInt8, UInt8)
                switch source {
                case let .solid(c):
                    (b, g, r) = (UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF))
                case let .image(img, origin):
                    let sx = Int(origin.x) + x - Int(rect.left), sy = Int(origin.y) + y - Int(rect.top)
                    guard sx >= 0, sx < img.width, sy >= 0, sy < img.height else { continue }
                    let i = (sy * img.width + sx) * 4
                    (b, g, r) = (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2])
                case let .pattern(img, seed):
                    let px = ((x - Int(seed.x)) % img.width + img.width) % img.width
                    let py = ((y - Int(seed.y)) % img.height + img.height) % img.height
                    let i = (py * img.width + px) * 4
                    (b, g, r) = (img.pixels[i], img.pixels[i + 1], img.pixels[i + 2])
                }
                let d = y * dst.stride + x * 4
                dst.pixels[d] = ropCombine(dst: dst.pixels[d], src: b, rop: rop)
                dst.pixels[d + 1] = ropCombine(dst: dst.pixels[d + 1], src: g, rop: rop)
                dst.pixels[d + 2] = ropCombine(dst: dst.pixels[d + 2], src: r, rop: rop)
                dst.pixels[d + 3] = 0xFF
            }
        }
    }

    /// Crops `from` out of `src` and scales it. Interpolated scaling goes through vImage;
    /// nearest is a manual loop (vImage has no nearest mode).
    static func scaled(_ src: DecodedImage, from: SpiceRect, toWidth: Int, toHeight: Int, nearest: Bool) -> DecodedImage {
        // crop first (extract rows), then scale; ~20 lines. vImageScale_ARGB8888 is
        // channel-order-agnostic, so BGRA passes straight through.
    }
}
```

Fast path: when `mask == nil && rop == ROPD.opPut`, `.image` delegates to `Tier1.copy` and `.solid` to `Tier1.fill` — tier 2 must not slow the 95% case down.

- [x] **Step 4: Run to verify pass**

Run: `swift test --filter Tier2Tests` — expected: PASS.

- [x] **Step 5: Route Canvas through Tier2 and delete the PUT shims**

In `Canvas.applyThrowing`:

- `.fill`: brush → `PixelSource` (`.solid`, or `.pattern` after resolving the image); `Tier2.draw` with the command's `rop` and `try resolveMask(f.mask, …)`. Delete the `cont.yield(.unsupported("fill rop …"))` line.
- `.copy` / `.blend`: resolve source; if `sourceArea` size ≠ box size, `Tier2.scaled` first (`scaleMode == 1` is nearest, per `SPICE_IMAGE_SCALE_MODE_NEAREST`); `.copy` keeps rop (spice servers send COPY with non-PUT rops), `.blend` likewise. Delete the shim yield.
- `.opaque`: temp `DecodedImage` = scaled source; `Tier2.draw` the *brush* into a temp `Surface` seeded with the source pixels using `o.rop`; blit the temp through the mask with PUT. (Build the temp as a `Surface(id: .max, …)` scratch — it never emits events.)
- Keep `forEachClipRect` exactly as is — tier 2 runs inside the same per-clip-rect loop and emits the same updates.

Add a `CanvasTests` case proving routing end-to-end (builder helpers exist in the file):

```swift
@Test func fillWithXorRopInverts() async throws {
    let c = Canvas(); await c.apply(create(2, 2))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 2, right: 2), color: 0xFFFFFF))
    var w = SpiceWriter(); drawBase(&w, SpiceRect(top: 0, left: 0, bottom: 2, right: 2))
    w.u8(1); w.u32(0xFFFFFF); w.u16(ROPD.opXor); noMask(&w)
    await c.apply(try DisplayMessage(type: DisplayServerMsg.drawFill.rawValue, payload: w.bytes))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 0, y: 0) & 0xFFFFFF == 0)       // white XOR white = black
}
```

Run: `swift test` — expected: PASS; the desktop replay tally shrinks (rop/mask/scale shims gone).

- [x] **Step 6: Commit**

```bash
git add Sources/SpiceCanvas Tests/SpiceCanvasTests
git commit -m "feat(canvas): tier-2 kernels — ROPs, pattern brushes, masks, scaled blits"
```

---

### Task 5: ROP3 and TRANSPARENT

**Files:**
- Modify: `Sources/SpiceCanvas/Tier2.swift` (rop3 kernel), `Sources/SpiceCanvas/Canvas.swift`
- Test: `Tests/SpiceCanvasTests/Tier2Tests.swift`

**Interfaces:**
- Consumes: Task 2's `.rop3`/`.transparent` cases, Task 4's `PixelSource`/mask machinery.
- Produces: `Tier2.rop3(_ code: UInt8, p: UInt8, s: UInt8, d: UInt8) -> UInt8` and Canvas handling for both commands (replacing Task 2's temporary throws).

- [x] **Step 1: Write failing tests**

```swift
@Test func rop3KnownCodes() {
    let p: UInt8 = 0xF0, s: UInt8 = 0xCC, d: UInt8 = 0xAA
    #expect(Tier2.rop3(0xCC, p: p, s: s, d: d) == s)          // SRCCOPY
    #expect(Tier2.rop3(0xF0, p: p, s: s, d: d) == p)          // PATCOPY
    #expect(Tier2.rop3(0x55, p: p, s: s, d: d) == ~d)         // DSTINVERT
    #expect(Tier2.rop3(0x5A, p: p, s: s, d: d) == (p ^ d))    // PATINVERT
    #expect(Tier2.rop3(0x66, p: p, s: s, d: d) == (s ^ d))    // SRCINVERT
    #expect(Tier2.rop3(0x00, p: p, s: s, d: d) == 0)          // BLACKNESS
    #expect(Tier2.rop3(0xFF, p: p, s: s, d: d) == 0xFF)       // WHITENESS
}

@Test func transparentSkipsKeyedPixels() async throws {
    let c = Canvas(); await c.apply(create(2, 1))
    await c.apply(fill(SpiceRect(top: 0, left: 0, bottom: 1, right: 2), color: 0x112233))
    // 2×1 source: green (the key) and red — only red lands.
    let src: [UInt8] = [0,255,0,255, 0,0,255,255]
    await c.apply(transparentDraw(SpiceRect(top: 0, left: 0, bottom: 1, right: 2),
                                  pixels: src, w: 2, h: 1, trueColor: 0x00FF00))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 0, y: 0) & 0xFFFFFF == 0x112233)       // keyed pixel untouched
    #expect(s.pixel(x: 1, y: 0) & 0xFFFFFF == 0xFF0000)       // red copied
}
```

`transparentDraw` is a builder helper following `copyBitmap`'s pattern (drawBase, ptr to a `.bitmap` image, src_area, src_color = trueColor, true_color).

- [x] **Step 2: Run to verify failure** — `swift test --filter "rop3KnownCodes|transparentSkipsKeyedPixels"`: compile error / unsupported throw.

- [x] **Step 3: Implement**

```swift
static func rop3(_ code: UInt8, p: UInt8, s: UInt8, d: UInt8) -> UInt8 {
    var r: UInt8 = 0
    for minterm in 0 ..< 8 where code & (1 << minterm) != 0 {
        let pm = minterm & 4 != 0 ? p : ~p
        let sm = minterm & 2 != 0 ? s : ~s
        let dm = minterm & 1 != 0 ? d : ~d
        r |= pm & sm & dm
    }
    return r
}
```

Canvas `.rop3`: resolve source (scaled if needed, same as copy), resolve brush pixel per (x, y) (solid or tiled pattern), resolve mask; per-pixel per-channel `rop3(code, p:, s:, d:)`, alpha 0xFF. This needs its own small loop in Tier2 (`Tier2.drawRop3(dst:rect:src:srcOrigin:brush:code:mask:)`) since it combines *two* sources — don't force it through `PixelSource`.

Canvas `.transparent`: resolve source; copy pixels whose decoded RGB (`pixel & 0xFFFFFF`) ≠ `trueColor & 0xFFFFFF`, skip the rest. Clip handling identical to `.copy`.

- [x] **Step 4: Run to verify pass** — `swift test`: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/SpiceCanvas Tests/SpiceCanvasTests
git commit -m "feat(canvas): ROP3 and TRANSPARENT draws"
```

---

### Task 6: Tier 3 — STROKE

CoreGraphics rasterizes the path into an 8-bit coverage mask; the brush lands through Tier2. CoreGraphics is used for *rasterization only* (design spec §4) — no CGBlendMode.

**Files:**
- Create: `Sources/SpiceCanvas/Tier3.swift`
- Modify: `Sources/SpiceCanvas/Canvas.swift`
- Test: `Tests/SpiceCanvasTests/Tier3Tests.swift`

**Interfaces:**
- Consumes: `SpicePath`, `FixedPoint`, `PathFlags`, `DrawStroke`; Task 4's `Tier2.draw`/`ResolvedMask`.
- Produces: `Tier3.strokeMask(_ path: SpicePath, in rect: SpiceRect) -> ResolvedMask` (coverage for the path stroked at 1px within `rect`), and Canvas `.stroke` handling.

- [x] **Step 1: Write failing test**

```swift
import Testing
import SpiceWire
@testable import SpiceCanvas

@Test func horizontalStrokePaintsTheLine() {
    let seg = SpicePathSegment(flags: PathFlags.begin | PathFlags.end,
                               points: [FixedPoint(x: 2 * 16, y: 3 * 16), FixedPoint(x: 8 * 16, y: 3 * 16)])
    let mask = Tier3.strokeMask(SpicePath(segments: [seg]),
                                in: SpiceRect(top: 0, left: 0, bottom: 10, right: 10))
    #expect(mask.covers(x: 5, y: 3))       // on the line
    #expect(!mask.covers(x: 5, y: 7))      // off the line
    #expect(!mask.covers(x: 0, y: 3))      // before the start
}

@Test func bezierSegmentRasterizes() {
    let seg = SpicePathSegment(flags: PathFlags.begin | PathFlags.end | PathFlags.bezier,
                               points: [FixedPoint(x: 0, y: 0),
                                        FixedPoint(x: 5 * 16, y: 0), FixedPoint(x: 5 * 16, y: 5 * 16),
                                        FixedPoint(x: 10 * 16, y: 5 * 16)])
    let mask = Tier3.strokeMask(SpicePath(segments: [seg]),
                                in: SpiceRect(top: 0, left: 0, bottom: 10, right: 12))
    #expect(mask.coverage.contains { $0 != 0 })
}
```

Note the first bezier point is the current-point move-to start; triples after it are (c1, c2, end). A segment without BEZIER draws line-tos from point 0. CLOSE closes the subpath.

- [x] **Step 2: Run to verify failure** — compile error.

- [x] **Step 3: Implement `Tier3.strokeMask`**

```swift
import CoreGraphics
import SpiceWire

enum Tier3 {
    static func strokeMask(_ path: SpicePath, in rect: SpiceRect) -> ResolvedMask {
        let w = Int(rect.width), h = Int(rect.height)
        var coverage = [UInt8](repeating: 0, count: w * h)
        coverage.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Surface y grows down; CG y grows up. Flip once here so callers stay in guest coords.
            ctx.translateBy(x: -CGFloat(rect.left), y: CGFloat(rect.bottom))
            ctx.scaleBy(x: 1, y: -1)
            let cg = CGMutablePath()
            for seg in path.segments {
                guard let first = seg.points.first else { continue }
                if seg.flags & PathFlags.begin != 0 { cg.move(to: CGPoint(x: first.cgX, y: first.cgY)) }
                if seg.flags & PathFlags.bezier != 0 {
                    var i = 1
                    while i + 2 < seg.points.count {
                        let c1 = seg.points[i], c2 = seg.points[i + 1], end = seg.points[i + 2]
                        cg.addCurve(to: CGPoint(x: end.cgX, y: end.cgY),
                                    control1: CGPoint(x: c1.cgX, y: c1.cgY),
                                    control2: CGPoint(x: c2.cgX, y: c2.cgY))
                        i += 3
                    }
                } else {
                    for p in seg.points.dropFirst() { cg.addLine(to: CGPoint(x: p.cgX, y: p.cgY)) }
                }
                if seg.flags & PathFlags.close != 0 { cg.closeSubpath() }
            }
            ctx.setLineWidth(1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.addPath(cg)
            ctx.strokePath()
        }
        return ResolvedMask(width: w, height: h, origin: SpicePoint(x: rect.left, y: rect.top), coverage: coverage)
    }
}
```

Canvas `.stroke` (replacing Task 2's throw): for each clip rect, `strokeMask` over the *clipped* rect, then `Tier2.draw` with the stroke's brush as `PixelSource` and `foreMode` as the rop, mask = the stroke coverage. `brush == .none` → nothing to draw (skip). `back_mode`/styled dashes are parsed and ignored — QXL strokes solid; if the desktop replay ever shows dashed artifacts, that is the first place to look.

- [x] **Step 4: Run to verify pass** — `swift test --filter Tier3Tests && swift test`: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/SpiceCanvas Tests/SpiceCanvasTests/Tier3Tests.swift
git commit -m "feat(canvas): tier-3 STROKE via CGPath coverage masks"
```

---

### Task 7: TEXT — glyph mask blits

`TEXT` carries glyph bitmaps, not fonts: each glyph is an alpha mask blitted with the fore brush; `back_area` (when non-empty) fills with the back brush first.

**Files:**
- Modify: `Sources/SpiceCanvas/Tier3.swift`, `Sources/SpiceCanvas/Canvas.swift`
- Test: `Tests/SpiceCanvasTests/Tier3Tests.swift`

**Interfaces:**
- Consumes: `SpiceString`, `RasterGlyph`, `StringFlags`, Task 4's `Tier2.draw`.
- Produces: `Tier3.glyphMask(_ glyph: RasterGlyph, bpp: Int, topDown: Bool) -> ResolvedMask` (origin = renderPos), and Canvas `.text` handling.

- [x] **Step 1: Write failing tests**

```swift
@Test func a1GlyphMaskIsMSBFirst() {
    let g = RasterGlyph(renderPos: SpicePoint(x: 4, y: 2), origin: SpicePoint(x: 0, y: 0),
                        width: 8, height: 1, data: [0b1000_0001])
    let m = Tier3.glyphMask(g, bpp: 1, topDown: true)
    #expect(m.covers(x: 4, y: 2))          // bit 7 → leftmost pixel
    #expect(m.covers(x: 11, y: 2))         // bit 0 → rightmost
    #expect(!m.covers(x: 5, y: 2))
}

@Test func a4GlyphHighNibbleFirst() {
    let g = RasterGlyph(renderPos: SpicePoint(x: 0, y: 0), origin: SpicePoint(x: 0, y: 0),
                        width: 2, height: 1, data: [0xF0])
    let m = Tier3.glyphMask(g, bpp: 4, topDown: true)
    #expect(m.covers(x: 0, y: 0) && !m.covers(x: 1, y: 0))
}

@Test func bottomUpGlyphFlips() {
    let g = RasterGlyph(renderPos: SpicePoint(x: 0, y: 0), origin: SpicePoint(x: 0, y: 0),
                        width: 8, height: 2, data: [0xFF, 0x00])    // first row in data = bottom row
    let m = Tier3.glyphMask(g, bpp: 1, topDown: false)
    #expect(!m.covers(x: 0, y: 0) && m.covers(x: 0, y: 1))
}

@Test func textDrawsGlyphWithForeBrush() async throws {
    let c = Canvas(); await c.apply(create(16, 8))
    await c.apply(textDraw(glyphData: [0xFF], w: 8, h: 1, at: SpicePoint(x: 3, y: 4), color: 0x00FF00))
    let s = try #require(await c.snapshot(surfaceID: 0))
    #expect(s.pixel(x: 3, y: 4) & 0xFFFFFF == 0x00FF00)
    #expect(s.pixel(x: 3, y: 5) & 0xFFFFFF == 0)
}
```

`textDraw` builds the wire message with `SpiceWriter` following Task 2's `drawTextParsesGlyphs` layout.

- [x] **Step 2: Run to verify failure.**

- [x] **Step 3: Implement**

`glyphMask`: decode A1 (MSB-first), A4 (high nibble first), A8 (bytes) into `coverage`, rows flipped when `!topDown`; `origin` = `renderPos`. Threshold at != 0 (A4/A8 partial coverage collapses to on/off for now — anti-aliased subpixel text from QXL is A1 in practice; note it in a comment).

Canvas `.text`: if `backArea` non-empty and `backBrush != .none`, `Tier2.draw` the back brush over `backArea ∩ clip` with `backMode`. Then per glyph, per clip rect: `Tier2.draw(source: foreBrush-as-PixelSource, rop: foreMode, mask: glyphMask ∩ effective rect)`. The draw rect for a glyph is `(renderPos, renderPos + (width, height)) ∩ clip ∩ surface bounds`; emit one update per glyph is wasteful — emit one update for `base.box` after all glyphs land (the box bounds the string).

- [x] **Step 4: Run to verify pass** — `swift test`: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/SpiceCanvas Tests/SpiceCanvasTests/Tier3Tests.swift
git commit -m "feat(canvas): TEXT glyph blits"
```

---

### Task 8: The desktop replay goes strict — zero unsupported, reviewed golden

> **Amended 2026-08-30 — read before implementing.** This task was written believing the
> `win-desktop` recording exercised tiers 2-3. It does not: the whole capture is 126 `DRAW_COPY`
> and nothing else, so "zero unsupported" is already true at the branch point and cannot
> discriminate. Implement this task as a **tier-1 regression golden** over real traffic — the
> zero-unsupported assertion stays (it is still a genuine corruption alarm for the copy path,
> and cheap), but it must be documented in the test as such, NOT as the milestone's
> draw-correctness gate. Tiers 2-3 are proven by Tasks 4-7's unit tests. `expectClose` is still
> produced here for Task 14. Do not claim in the commit message that this gates tiers 2-3.

**Files:**
- Modify: `Tests/SpiceKitTests/ReplayTests.swift`
- Create: `Tests/SpiceKitTests/Fixtures/win-desktop.golden.png` (generated, then **reviewed by eye**)

**Interfaces:**
- Consumes: everything from Tasks 2–7.
- Produces: the M4 draw-correctness gate, plus `expectClose` used again by Task 13.

- [x] **Step 1: Tighten the test**

Replace `winDesktopReplayCompletes` with:

```swift
/// The M4 exit gate for draws: the installed Windows/QXL desktop replays with ZERO unsupported
/// commands (an unimplemented command is permanent corruption — there is no redraw request)
/// and matches a visually reviewed golden.
@Test func winDesktopReplayMatchesGolden() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-desktop.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let t = InMemoryTransport(input: [UInt8](try Data(contentsOf: url)))
    let channel = try await DisplayChannel.open(transport: t, connectionID: 0, id: 0, password: nil)
    let canvas = Canvas()
    let collector = Task {
        var unsupported: [String] = []
        for await e in canvas.events { if case let .unsupported(what) = e { unsupported.append(what) } }
        return unsupported
    }
    for await m in channel.messages { await canvas.apply(m) }
    await canvas.finish()
    #expect(await collector.value == [])
    let id = try #require(await canvas.primarySurfaceID)
    let frame = try #require(await canvas.snapshot(surfaceID: id))
    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/win-desktop.golden.png")
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        try PNG.encode(frame).write(to: goldenURL)
        Issue.record("golden written to \(goldenURL.path) — review it visually, then re-run")
        return
    }
    let golden = try PNG.decode(try Data(contentsOf: goldenURL))
    expectClose(frame, golden, maxChannelDelta: 0, maxMismatchFraction: 0)
}

/// Tolerant image compare for pipelines that are not bit-exact across OS releases (JPEG, H.264).
/// maxChannelDelta 0 + fraction 0 degrades to the exact compare the lossless goldens use.
func expectClose(_ got: DecodedImage, _ want: DecodedImage, maxChannelDelta: Int, maxMismatchFraction: Double,
                 sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(got.width == want.width && got.height == want.height, sourceLocation: sourceLocation)
    guard got.width == want.width, got.height == want.height else { return }
    var mismatches = 0
    for i in stride(from: 0, to: got.pixels.count, by: 4) {
        for c in 0 ..< 3 where abs(Int(got.pixels[i + c]) - Int(want.pixels[i + c])) > maxChannelDelta {
            mismatches += 1; break
        }
    }
    let fraction = Double(mismatches) / Double(got.width * got.height)
    #expect(fraction <= maxMismatchFraction, "\(mismatches) pixels differ (\(fraction))", sourceLocation: sourceLocation)
}
```

If the recorded session includes JPEG images (it can, if the server chose lossy for some region — the tally from Task 1 tells you), use `maxChannelDelta: 3, maxMismatchFraction: 0.001` instead of exact, and say so in the commit message.

- [x] **Step 2: Run, review, re-run**

```bash
swift test --filter winDesktopReplayMatchesGolden      # first run writes the golden
open Tests/SpiceKitTests/Fixtures/win-desktop.golden.png
```

**Look at the PNG.** It must be a coherent Windows desktop with the context menu / start menu / drag artifacts of Task 1's script — no torn rectangles, no inverted regions, no black holes. If it is corrupt, the corruption names the broken kernel; fix it before committing anything. Then:

```bash
swift test --filter winDesktopReplayMatchesGolden      # second run compares
```

Expected: PASS with zero unsupported. If unsupported is non-empty, the tally names the missing command — implement it before this task is done (that is the point of the gate).

- [x] **Step 3: Full suite** — `swift test`: PASS (the old `winDisplayReplayMatchesGolden` must still pass byte-exact: tier-1 traffic must be untouched by the routing changes).

- [x] **Step 4: Commit**

```bash
git add Tests/SpiceKitTests
git commit -m "test(kit): Windows/QXL desktop replay gate — zero unsupported, reviewed golden"
```

---

### Task 9: Wire parsing for stream messages + STREAM_REPORT encoder

**Files:**
- Create: `Sources/SpiceWire/StreamMessages.swift`
- Modify: `Sources/SpiceWire/DisplayMessages.swift` (cases + switch arms), `Sources/SpiceWire/ClientMessages.swift`, `Sources/SpiceCanvas/Canvas.swift` (ignore-arms)
- Test: `Tests/SpiceWireTests/StreamMessageTests.swift`

**Interfaces:**
- Produces (consumed by Tasks 10–12):

```swift
public enum VideoCodecType: UInt8, Sendable { case mjpeg = 1, vp8, h264, vp9, h265 }
public enum StreamFlags { public static let topDown: UInt8 = 1 }

public struct StreamCreate: Sendable, Equatable {
    public var surfaceID: UInt32, id: UInt32, flags: UInt8, codec: VideoCodecType
    public var streamWidth: UInt32, streamHeight: UInt32, srcWidth: UInt32, srcHeight: UInt32
    public var dest: SpiceRect, clip: SpiceClip
}
public struct StreamData: Sendable, Equatable {
    public var id: UInt32, mmTime: UInt32, data: [UInt8]
    public var sized: (width: UInt32, height: UInt32, dest: SpiceRect)?   // set for STREAM_DATA_SIZED
}
public struct StreamActivateReport: Sendable, Equatable {
    public var streamID: UInt32, uniqueID: UInt32, maxWindowSize: UInt32, timeoutMs: UInt32
}
public struct StreamReport: Sendable, Equatable {
    public var streamID: UInt32, uniqueID: UInt32
    public var startFrameMMTime: UInt32, endFrameMMTime: UInt32
    public var numFrames: UInt32, numDrops: UInt32
    public var lastFrameDelay: Int32, audioDelay: UInt32
}
// DisplayMessage cases:
case streamCreate(StreamCreate), streamData(StreamData), streamClip(id: UInt32, clip: SpiceClip)
case streamDestroy(UInt32), streamDestroyAll, streamActivateReport(StreamActivateReport)
// ClientMessage:
public static func streamReport(_ r: StreamReport) -> [UInt8]
```

`sized` as an optional tuple keeps one `StreamData` type for both data messages — the player treats a sized frame as "this frame also moves/resizes the stream". Tuples aren't `Equatable` in older modes but are in Swift 6 for ≤6 elements of Equatable; if the compiler disagrees, make it a small struct `SizedInfo`.

- [x] **Step 1: Write failing tests**

```swift
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
    #expect(d.sized?.width == 320 && d.data == [9, 9])
}

@Test func hostileStreamDataSizeRejected() throws {
    var w = SpiceWriter(); w.u32(3); w.u32(0); w.u32(0xFFFF_FFFF)
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

@Test func streamReportEncodes32Bytes() {
    let b = ClientMessage.streamReport(StreamReport(streamID: 3, uniqueID: 7, startFrameMMTime: 100,
                                                    endFrameMMTime: 200, numFrames: 30, numDrops: 1,
                                                    lastFrameDelay: -5, audioDelay: .max))
    #expect(b.count == 32)
    #expect(b[0] == 3 && b[4] == 7)
    #expect(b[24] == 0xFB && b[25] == 0xFF)           // -5 little-endian
}
```

- [x] **Step 2: Run to verify failure.**

- [x] **Step 3: Implement**

`StreamMessages.swift` per the protocol reference; `data_size` capped at `1 << 26` like images (a hostile size throws before allocation). The `DisplayMessage.init` arms replace `default` for types 122–126, 315, 319. A destroyed-codec byte outside `VideoCodecType` throws `WireError.badValue(field: "codec_type", …)` — an unknown codec must fail the *parse* so the channel logs and drops it (existing pump behaviour), not reach the player. `Canvas.applyThrowing` gets one combined arm: `case .streamCreate, .streamData, .streamClip, .streamDestroy, .streamDestroyAll, .streamActivateReport: break` — with the comment that `SpiceSession` routes streams to the player before the canvas ever sees them; the arm exists so a mis-route is inert rather than corrupting.

- [x] **Step 4: Run to verify pass** — `swift test`: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/SpiceWire Sources/SpiceCanvas/Canvas.swift Tests/SpiceWireTests/StreamMessageTests.swift
git commit -m "feat(wire): stream messages and STREAM_REPORT encoder"
```

---

### Task 10: SpiceMedia target with VideoDecoder (MJPEG + H.264)

One `VTDecompressionSession` path for both codecs, per the spec's codec table. Synchronous decode (no async flag) keeps everything inside the owning actor — no Sendable gymnastics.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SpiceMedia/VideoDecoder.swift`
- Test: `Tests/SpiceMediaTests/VideoDecoderTests.swift`

**Interfaces:**
- Consumes: `VideoCodecType` from SpiceWire.
- Produces (consumed by Task 11):

```swift
public struct VideoFrame: Sendable {
    public var width: Int, height: Int
    public var pixels: [UInt8]                     // BGRA, tightly packed
}
public enum VideoDecodeError: Error, Sendable { case format(String), decode(OSStatus), noKeyframe }

/// One per stream, owned by the StreamPlayer actor. Not Sendable; ~Copyable like ImageDecoder.
public struct VideoDecoder: ~Copyable {
    public init(codec: VideoCodecType)
    /// MJPEG: data is one complete JPEG. H264: data is Annex-B NAL units; frames before the
    /// first SPS/PPS+IDR throw .noKeyframe (the server always opens a stream with a keyframe;
    /// tolerate loss by skipping, not by crashing).
    public mutating func decode(_ data: [UInt8]) throws -> VideoFrame
}
```

- [x] **Step 1: Package.swift**

Add to targets (and `SpiceKit` deps in Task 12 — not yet):

```swift
.target(name: "SpiceMedia", dependencies: ["SpiceWire"]),
.testTarget(name: "SpiceMediaTests", dependencies: ["SpiceMedia", "SpiceWire"]),
```

- [x] **Step 2: Write failing tests**

```swift
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import SpiceWire
@testable import SpiceMedia

private func jpegFrame(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    for i in stride(from: 0, to: px.count, by: 4) { px[i] = b; px[i + 1] = g; px[i + 2] = r }
    let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return [UInt8](data as Data)
}

@Test func mjpegDecodesToBGRA() throws {
    var d = VideoDecoder(codec: .mjpeg)
    let frame = try d.decode(try jpegFrame(width: 64, height: 48, r: 200, g: 30, b: 10))
    #expect(frame.width == 64 && frame.height == 48)
    #expect(frame.pixels.count == 64 * 48 * 4)
    #expect(abs(Int(frame.pixels[2]) - 200) < 12)      // red channel, JPEG-lossy tolerance
}

@Test func h264RoundTripsThroughVideoToolbox() throws {
    // SELF-CONSISTENT: encodes with VT and decodes with VT. Real-server H.264 remains unverified
    // (see "What cannot be verified"). What this does prove: Annex-B parsing, SPS/PPS extraction,
    // AVCC conversion, session lifecycle, BGRA output geometry.
    let annexB = try H264TestEncoder.encodeGradient(width: 64, height: 48, frames: 3)  // helper below
    var d = VideoDecoder(codec: .h264)
    var decoded = 0
    for frame in annexB {
        if let f = try? d.decode(frame) { decoded += 1; #expect(f.width == 64 && f.height == 48) }
    }
    #expect(decoded >= 2)     // the first delivery can be parameter-sets-only
}

@Test func garbageInputThrowsNotTraps() {
    var d = VideoDecoder(codec: .mjpeg)
    #expect(throws: (any Error).self) { _ = try d.decode([0xDE, 0xAD, 0xBE, 0xEF]) }
    var h = VideoDecoder(codec: .h264)
    #expect(throws: (any Error).self) { _ = try h.decode([0, 0, 0, 1, 0x41, 0xFF]) }  // P-slice before SPS
}
```

`H264TestEncoder` (test-only, in the test file): `VTCompressionSession` (codec `.h264`, realtime, all-intra via `kVTCompressionPropertyKey_MaxKeyFrameInterval = 1`), encode N BGRA gradient frames; for each sample buffer, pull SPS/PPS from the format description (`CMVideoFormatDescriptionGetH264ParameterSetAtIndex`) and emit Annex-B: `[00 00 00 01]+SPS + [00 00 00 01]+PPS + per-NAL [00 00 00 01]+payload` (AVCC lengths from the block buffer converted). ~60 lines; it is the inverse of the decoder's converter, which is exactly why the test is labelled self-consistent.

- [x] **Step 3: Run to verify failure** — `swift test --filter VideoDecoderTests`: compile errors.

- [x] **Step 4: Implement `VideoDecoder`**

Key mechanics (implementer writes the full ~200 lines):

- **MJPEG:** per frame, `CMVideoFormatDescriptionCreate(codecType: kCMVideoCodecType_JPEG, width:, height:)` — width/height parsed from the JPEG SOF header (scan markers; SOF0/SOF2 carry them; a malformed header throws `.format`). Recreate the `VTDecompressionSession` only when dimensions change.
- **H.264:** split Annex-B on start codes (`00 00 01` / `00 00 00 01`); stash SPS (NAL type 7) and PPS (type 8); on both present, `CMVideoFormatDescriptionCreateFromH264ParameterSets` (nalUnitHeaderLength 4) and (re)create the session; VCL NALs (types 1, 5) become one sample: AVCC = 4-byte big-endian length + NAL, concatenated into a `CMBlockBuffer` → `CMSampleBuffer`.
- **Session:** `VTDecompressionSessionCreate` with `destinationImageBufferAttributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]`. Decode with `VTDecompressionSessionDecodeFrame(_, sampleBuffer:, flags: [], infoFlagsOut: nil, outputHandler:)` — empty flags = synchronous, the handler runs before return, so writing into a local `var result` is race-free. Copy out under `CVPixelBufferLockBaseAddress` row by row (respect `bytesPerRow`), unlock, return.
- `deinit`: `VTDecompressionSessionInvalidate`.
- Errors carry the `OSStatus`; no `fatalError`, no `!` on server-derived data.

- [x] **Step 5: Run to verify pass** — `swift test --filter VideoDecoderTests`: PASS.

- [x] **Step 6: Commit**

```bash
git add Package.swift Sources/SpiceMedia Tests/SpiceMediaTests
git commit -m "feat(media): SpiceMedia target — VideoToolbox decoder for MJPEG and H.264"
```

---

### Task 11: StreamPlayer actor — state, mm clock, drops, reports

**Files:**
- Create: `Sources/SpiceMedia/StreamPlayer.swift`
- Test: `Tests/SpiceMediaTests/StreamPlayerTests.swift`

**Interfaces:**
- Consumes: `VideoDecoder`, `VideoFrame`; SpiceWire's `StreamCreate`, `StreamData`, `StreamActivateReport`, `StreamReport`, `SpiceRect`, `SpiceClip`.
- Produces (consumed by Task 12):

```swift
public struct StreamFrame: Sendable {
    public var streamID: UInt32, surfaceID: UInt32
    public var dest: SpiceRect, clip: SpiceClip
    public var width: Int, height: Int
    public var pixels: [UInt8]                        // BGRA
}
public enum StreamPlayerEvent: Sendable {
    case frame(StreamFrame)
    case destroyed(streamID: UInt32)
    case allDestroyed
    case report(StreamReport)
}

public actor StreamPlayer {
    public nonisolated let events: AsyncStream<StreamPlayerEvent>
    public init()
    public func handle(create: StreamCreate)
    public func handle(data: StreamData)              // decode → pace → emit or drop
    public func handle(clipChange id: UInt32, clip: SpiceClip)
    public func handle(destroy id: UInt32)
    public func handleDestroyAll()
    public func handle(activateReport: StreamActivateReport)
    public func setMMTime(_ serverTime: UInt32)       // MAIN_INIT and MSG_MAIN_MULTI_MEDIA_TIME
    public func finish()                              // ends events; mirrors Canvas.finish()
}
```

Behaviour contract, stated here because the consumer's own task can outrun state changes (same reasoning as `AgentEvent`): every `StreamFrame` carries dest/clip **as they stood when its data arrived** — stamped onto the event, never queried back.

Pacing: `setMMTime` records `base = (serverTime, ContinuousClock.now)`; server-now at any instant is `serverTime + elapsed ms`. A data frame whose `mmTime` is more than **80 ms** behind server-now is dropped *before decode* (count it, skip the VT work — dropping after decode wastes the very CPU the drop protects); anything else decodes and emits immediately. No sleeps, no timers — the display link downstream coalesces to vsync. Before `setMMTime` is ever called, nothing drops (base unknown → assume on time). A frame that fails to decode is counted as a drop and logged, never fatal to the stream.

Reports: per stream, after `activateReport`, count frames+drops; when the count reaches `maxWindowSize`, or a new frame arrives more than `timeoutMs` after the window opened, emit `.report` with `startFrameMMTime`/`endFrameMMTime` = first/last frame mm-times in the window, `lastFrameDelay` = signed (server-now − mmTime) of the last frame, `audioDelay = UInt32.max` (no audio until M6), then reset the window. No timer: a stalled stream reports on its next frame, which is when the server can react anyway.

MJPEG frames with `flags & StreamFlags.topDown == 0` flip rows before emit (reuse the flip the canvas uses — a private copy; SpiceMedia cannot import SpiceCanvas).

- [x] **Step 1: Write failing tests**

```swift
import Testing
import SpiceWire
@testable import SpiceMedia

private func mjpegCreate(id: UInt32 = 1, dest: SpiceRect = SpiceRect(top: 0, left: 0, bottom: 48, right: 64)) -> StreamCreate {
    StreamCreate(surfaceID: 0, id: id, flags: StreamFlags.topDown, codec: .mjpeg,
                 streamWidth: 64, streamHeight: 48, srcWidth: 64, srcHeight: 48, dest: dest, clip: .none)
}

@Test func frameCarriesGeometryAtArrival() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    await p.handle(data: StreamData(id: 1, mmTime: 0, data: try jpegFrame(width: 64, height: 48, r: 9, g: 9, b: 9), sized: nil))
    await p.handle(clipChange: 1, clip: .rects([SpiceRect(top: 0, left: 0, bottom: 10, right: 10)]))
    await p.finish()
    var frames: [StreamFrame] = []
    for await e in p.events { if case let .frame(f) = e { frames.append(f) } }
    #expect(frames.count == 1)
    #expect(frames[0].clip == .none)          // the clip change came after this frame
    #expect(frames[0].dest.width == 64)
}

@Test func lateFramesDropBeforeDecode() async throws {
    let p = StreamPlayer()
    await p.setMMTime(10_000)
    await p.handle(create: mjpegCreate())
    // 5 seconds behind the mm clock: must be dropped without touching the decoder,
    // so garbage data here must NOT produce a decode error.
    await p.handle(data: StreamData(id: 1, mmTime: 5_000, data: [0xFF], sized: nil))
    await p.handle(data: StreamData(id: 1, mmTime: 10_000, data: try jpegFrame(width: 64, height: 48, r: 1, g: 1, b: 1), sized: nil))
    await p.finish()
    var frames = 0
    for await e in p.events { if case .frame = e { frames += 1 } }
    #expect(frames == 1)
}

@Test func reportEmittedAtWindow() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    await p.handle(activateReport: StreamActivateReport(streamID: 1, uniqueID: 42, maxWindowSize: 2, timeoutMs: 60_000))
    let jpeg = try jpegFrame(width: 64, height: 48, r: 0, g: 0, b: 0)
    await p.handle(data: StreamData(id: 1, mmTime: 100, data: jpeg, sized: nil))
    await p.handle(data: StreamData(id: 1, mmTime: 133, data: jpeg, sized: nil))
    await p.finish()
    var reports: [StreamReport] = []
    for await e in p.events { if case let .report(r) = e { reports.append(r) } }
    #expect(reports.count == 1)
    #expect(reports[0].uniqueID == 42 && reports[0].numFrames == 2 && reports[0].numDrops == 0)
    #expect(reports[0].startFrameMMTime == 100 && reports[0].endFrameMMTime == 133)
    #expect(reports[0].audioDelay == .max)
}

@Test func sizedFrameMovesTheStream() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    let newDest = SpiceRect(top: 100, left: 100, bottom: 148, right: 164)
    await p.handle(data: StreamData(id: 1, mmTime: 0,
                                    data: try jpegFrame(width: 64, height: 48, r: 2, g: 2, b: 2),
                                    sized: (width: 64, height: 48, dest: newDest)))
    await p.finish()
    for await e in p.events { if case let .frame(f) = e { #expect(f.dest == newDest) } }
}

@Test func destroyStopsEmission() async throws {
    let p = StreamPlayer()
    await p.handle(create: mjpegCreate())
    await p.handle(destroy: 1)
    await p.handle(data: StreamData(id: 1, mmTime: 0, data: [1, 2, 3], sized: nil))  // stale data after destroy
    await p.finish()
    var destroyed = false, frames = 0
    for await e in p.events {
        if case .destroyed(1) = e { destroyed = true }
        if case .frame = e { frames += 1 }
    }
    #expect(destroyed && frames == 0)
}
```

(`jpegFrame` moves to a shared test-support file in `Tests/SpiceMediaTests/` used by both test files.)

- [x] **Step 2: Run to verify failure.**

- [x] **Step 3: Implement `StreamPlayer`**

Internal state: `[UInt32: StreamState]` where `StreamState` holds `create` fields, current `dest`/`clip`, a `VideoDecoder`, appearance order, and an optional `ReportWindow { uniqueID, maxWindowSize, timeoutMs, opened: ContinuousClock.Instant, firstMM: UInt32?, lastMM: UInt32, frames: UInt32, drops: UInt32 }`. `StreamState` holds a `~Copyable` decoder, so store states in a `Dictionary` of classes or use `consume`-friendly handling — simplest: make `StreamState` a `final class` (actor-confined, never escapes, not Sendable — fine inside the actor). Data for an unknown id is dropped silently (destroy raced data — normal, not an error). Events stream is `.unbounded` like Canvas's.

- [x] **Step 4: Run to verify pass** — `swift test --filter StreamPlayerTests`: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/SpiceMedia Tests/SpiceMediaTests
git commit -m "feat(media): StreamPlayer — stream state, mm-time pacing, report bookkeeping"
```

---

### Task 12: SpiceKit wiring — routing, report send, session events

**Files:**
- Modify: `Package.swift` (SpiceKit deps += SpiceMedia; SpiceKitTests deps += SpiceMedia), `Sources/SpiceCore/DisplayChannel.swift`, `Sources/SpiceKit/SpiceSession.swift`
- Test: `Tests/SpiceKitTests/StreamSessionTests.swift`

**Interfaces:**
- Consumes: `StreamPlayer`, `StreamPlayerEvent`, `StreamFrame` (SpiceMedia); `ClientMessage.streamReport`.
- Produces (consumed by Task 13's app work):

```swift
// SpiceCore.DisplayChannel
public func send(streamReport: StreamReport) async throws

// SpiceKit.SessionEvent gains:
case streamFrame(StreamFrame, displayID: UInt8)
case streamDestroyed(id: UInt32, displayID: UInt8)
case allStreamsDestroyed(displayID: UInt8)
```

- [x] **Step 1: Write failing tests**

`Tests/SpiceKitTests/StreamSessionTests.swift`, following `SpiceSessionTests`'s fixture pattern (`fakeLink` + `frame(...)` builders from `TestSupport.swift`):

```swift
import Foundation
import Testing
import SpiceWire
import SpiceMedia
@testable import SpiceCore
@testable import SpiceKit

/// A display channel that opens a stream, sends one MJPEG frame, and destroys it must surface
/// exactly streamFrame + streamDestroyed session events — and the canvas must never see them.
@Test func streamMessagesRouteToPlayerNotCanvas() async throws {
    var body: [UInt8] = []
    var sc = SpiceWriter()
    sc.u32(0); sc.u32(800); sc.u32(600); sc.u32(32); sc.u32(1)
    body += frame(DisplayServerMsg.surfaceCreate.rawValue, sc.bytes)
    var cr = SpiceWriter()
    cr.u32(0); cr.u32(7); cr.u8(StreamFlags.topDown); cr.u8(VideoCodecType.mjpeg.rawValue); cr.u64(0)
    cr.u32(64); cr.u32(48); cr.u32(64); cr.u32(48)
    cr.i32(0); cr.i32(0); cr.i32(48); cr.i32(64); cr.u8(0)
    body += frame(DisplayServerMsg.streamCreate.rawValue, cr.bytes)
    let jpeg = try jpegFrame(width: 64, height: 48, r: 5, g: 5, b: 5)
    var da = SpiceWriter(); da.u32(7); da.u32(0); da.u32(UInt32(jpeg.count)); da.bytes(jpeg)
    body += frame(DisplayServerMsg.streamData.rawValue, da.bytes)
    var de = SpiceWriter(); de.u32(7)
    body += frame(DisplayServerMsg.streamDestroy.rawValue, de.bytes)

    let session = try await makeSession(displayBody: body)      // existing TestSupport pattern
    var sawFrame = false, sawDestroy = false, sawUnsupportedCanvas = false
    for await e in session.events {
        switch e {
        case let .streamFrame(f, displayID: 0): sawFrame = f.streamID == 7 && f.width == 64
        case .streamDestroyed(id: 7, displayID: 0): sawDestroy = true
        case .canvas(.unsupported): sawUnsupportedCanvas = true
        case .disconnected: break
        default: continue
        }
        if case .disconnected = e { break }
    }
    #expect(sawFrame && sawDestroy && !sawUnsupportedCanvas)
}
```

Also a `DisplayChannel.send(streamReport:)` unit test in `Tests/SpiceCoreTests` asserting the sent frame's type is `DisplayClientMsg.streamReport.rawValue` and the payload is 32 bytes (capture via the existing recording-transport test helper in SpiceCoreTests, if present; otherwise assert through `ClientMessage.streamReport` composition — the channel method is 2 lines).

Check `TestSupport.swift` for the existing session-builder helper name (`SpiceSessionTests` constructs sessions from `fakeLink` bodies); reuse it rather than inventing `makeSession` if one exists under another name.

- [x] **Step 2: Run to verify failure.**

- [x] **Step 3: Implement**

`DisplayChannel`:

```swift
public func send(streamReport r: StreamReport) async throws {
    try await reader.send(type: DisplayClientMsg.streamReport.rawValue, payload: ClientMessage.streamReport(r))
}
```

`SpiceSession.start`, display case — one `StreamPlayer` per display channel, routing in the pump:

```swift
case .display:
    let d = try await DisplayChannel.open(...)
    displays.append(d)
    let player = StreamPlayer()
    let playerPump = Task { [cont, weak self] in
        for await e in player.events {
            switch e {
            case let .frame(f): cont.yield(.streamFrame(f, displayID: desc.id))
            case let .destroyed(id): cont.yield(.streamDestroyed(id: id, displayID: desc.id))
            case .allDestroyed: cont.yield(.allStreamsDestroyed(displayID: desc.id))
            case let .report(r): await self?.sendStreamReport(r, on: d)
            }
        }
    }
    tasks.append(playerPump)
    players.append(player)
    let pump = Task { [canvas, weak self] in
        for await m in d.messages {
            switch m {
            case let .streamCreate(c): await player.handle(create: c)
            case let .streamData(data): await player.handle(data: data)
            case let .streamClip(id, clip): await player.handle(clipChange: id, clip: clip)
            case let .streamDestroy(id): await player.handle(destroy: id)
            case .streamDestroyAll: await player.handleDestroyAll()
            case let .streamActivateReport(a): await player.handle(activateReport: a)
            default: await canvas.apply(m)
            }
        }
        await player.finish()
        _ = await playerPump.value      // drain order: player events precede channelEnded, like canvas
        await self?.channelEnded(desc)
    }
```

`sendStreamReport` is a private method that logs a failed send and does not end the session (a lost report degrades adaptation, nothing else). `handleMain` gains `case let .multiMediaTime(t): for p in players { await p.setMMTime(t.time) }` and `startAgent`-adjacent init seeds `setMMTime(info.mainInit.multiMediaTime)` for each player at open. Check `MultiMediaTime`'s field name in `MainMessages.swift:126` before writing `t.time`.

Mind the existing drain comment in `start`: `.disconnected` must still come after every pixel — the display pump above awaits the player pump before `channelEnded`, preserving that order for stream frames too.

- [x] **Step 4: Run to verify pass** — `swift test`: PASS, including every pre-existing session/replay test (the routing change must not disturb draw traffic: `winDisplayReplayMatchesGolden` and `winDesktopReplayMatchesGolden` are the canaries).

- [x] **Step 5: Commit**

```bash
git add Package.swift Sources/SpiceCore Sources/SpiceKit Tests/SpiceKitTests Tests/SpiceCoreTests
git commit -m "feat(kit): route stream messages to StreamPlayer, send STREAM_REPORT"
```

---

### Task 13: App — seam events and Metal stream compositing

The sanctioned view changes: `GuestSurfaceView` composites stream layers; `SessionModel` routes two new event cases. Everything else is adapter work in `SpiceKitBackend`.

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift`, `Sources/SpiceSee/SpiceKitBackend.swift`, `Sources/SpiceSee/SessionModel.swift`, `Sources/SpiceSee/MetalSurfaceView.swift`
- Test: `Tests/SpiceSeeTests/StreamSeamTests.swift`

**Interfaces:**
- Consumes: Task 12's `SessionEvent` stream cases.
- Produces:

```swift
// SessionBackend.swift
struct GuestRect: Sendable, Equatable { var x, y, width, height: Int }
/// One decoded video frame for a stream layer, in guest pixels. dest is where it composites;
/// clip (nil = whole dest) is intersected in the view. Pixels are width×height BGRA.
struct StreamFrameUpdate: Sendable {
    var viewportID: Int
    var streamID: UInt32
    var dest: GuestRect
    var clip: [GuestRect]?
    var width: Int, height: Int
    var pixels: [UInt8]
}
// BackendEvent gains: case streamFrame(StreamFrameUpdate), streamDestroyed(viewportID: Int, streamID: UInt32?)
//   (streamID nil = all streams — DESTROY_ALL)
// ViewportEvent gains: case stream(StreamFrameUpdate), streamDestroyed(UInt32?)
```

- [x] **Step 1: Write failing seam-mapping test**

`Tests/SpiceSeeTests/StreamSeamTests.swift` (this bundle compiles `Sources/SpiceSee` into itself; follow `ClipboardBridgeTests`'s import style):

```swift
import Testing
import SpiceWire
import SpiceMedia
@testable import SpiceSeeTests_Sources   // match the module name ClipboardBridgeTests uses

@Test func streamFrameMapsToSeamGeometry() {
    let f = SpiceMedia.StreamFrame(streamID: 3, surfaceID: 0,
                                   dest: SpiceRect(top: 10, left: 20, bottom: 58, right: 84),
                                   clip: .rects([SpiceRect(top: 10, left: 20, bottom: 30, right: 40)]),
                                   width: 64, height: 48, pixels: [UInt8](repeating: 0, count: 64 * 48 * 4))
    let u = SpiceKitBackend.translate(f, viewportID: 0)
    #expect(u.dest == GuestRect(x: 20, y: 10, width: 64, height: 48))
    #expect(u.clip == [GuestRect(x: 20, y: 10, width: 20, height: 20)])
    #expect(u.streamID == 3)
}

@Test func noneClipMapsToNil() {
    let f = SpiceMedia.StreamFrame(streamID: 1, surfaceID: 0,
                                   dest: SpiceRect(top: 0, left: 0, bottom: 1, right: 1),
                                   clip: .none, width: 1, height: 1, pixels: [0, 0, 0, 255])
    #expect(SpiceKitBackend.translate(f, viewportID: 0).clip == nil)
}
```

(`translate(_:viewportID:)` becomes an internal static on `SpiceKitBackend`, like the existing cursor/clipboard translators.)

- [x] **Step 2: Run to verify failure**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: compile failure (missing types).

- [x] **Step 3: Implement the seam and adapter**

- `SessionBackend.swift`: the types above.
- `SpiceKitBackend.connect`'s event loop:

```swift
case let .streamFrame(f, displayID: id):
    continuation.yield(.streamFrame(Self.translate(f, viewportID: Int(id))))
case let .streamDestroyed(id: sid, displayID: id):
    continuation.yield(.streamDestroyed(viewportID: Int(id), streamID: sid))
case let .allStreamsDestroyed(displayID: id):
    continuation.yield(.streamDestroyed(viewportID: Int(id), streamID: nil))
```

- `SessionModel`'s backend-event switch: `.streamFrame(u)` → `publish(.stream(u), to: u.viewportID)`; `.streamDestroyed(vid, sid)` → `publish(.streamDestroyed(sid), to: vid)`. On `.disconnected`/`.failed`, also publish `.streamDestroyed(nil)` so a dead session never leaves a frozen video layer.
- `MetalSurfaceView.Coordinator.pump`: two new cases → `view.apply(streamUpdate:)` / `view.removeStream(_:)`.

- [x] **Step 4: Implement compositing in `GuestSurfaceView`**

```swift
// MARK: Stream layers

private final class StreamLayer {
    var texture: MTLTexture?
    var dest = CGRect.zero
    var clip: [CGRect]?          // guest coords; nil = whole dest
    let order: Int               // creation order = z-order, oldest underneath
    init(order: Int) { self.order = order }
}
private var streams: [UInt32: StreamLayer] = [:]
private var streamOrder = 0

func apply(streamUpdate u: StreamFrameUpdate) {
    let layer = streams[u.streamID] ?? { let l = StreamLayer(order: streamOrder); streamOrder += 1; streams[u.streamID] = l; return l }()
    if layer.texture?.width != u.width || layer.texture?.height != u.height {
        layer.texture = makeTexture(width: u.width, height: u.height)
    }
    guard let tex = layer.texture, u.pixels.count >= u.width * u.height * 4 else { return }
    u.pixels.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, u.width, u.height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: u.width * 4)
    }
    layer.dest = CGRect(x: u.dest.x, y: u.dest.y, width: u.dest.width, height: u.dest.height)
    layer.clip = u.clip.map { $0.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } }
    setNeedsPresent()
}

func removeStream(_ id: UInt32?) {
    if let id { streams[id] = nil } else { streams.removeAll() }
    setNeedsPresent()
}
```

In `render()`, between the primary quad and the cursor overlay:

```swift
// Stream layers: video is composited here, never drawn into the surface (design spec §4).
// Scissor rects are in drawable (device) pixels; clamp — MTLScissorRect outside the
// drawable is API misuse, not a soft clip.
let scale = backingScale
for layer in streams.values.sorted(by: { $0.order < $1.order }) {
    guard let tex = layer.texture else { continue }
    let viewRect = t.viewRect(forGuest: layer.dest)
    var placement = Self.clipSpace(viewRect, in: bounds.size)
    let clips = layer.clip ?? [layer.dest]
    for clipRect in clips {
        let v = t.viewRect(forGuest: clipRect)
        let dev = CGRect(x: v.origin.x * scale, y: v.origin.y * scale,
                         width: v.width * scale, height: v.height * scale)
            .intersection(CGRect(origin: .zero, size: metalLayer.drawableSize))
        guard !dev.isEmpty else { continue }
        encoder.setScissorRect(MTLScissorRect(x: Int(dev.minX), y: Int(dev.minY),
                                              width: Int(dev.width), height: Int(dev.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&placement, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.setFragmentSamplerState(smoothSampler ?? sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
// Reset the scissor before the cursor overlay:
encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(metalLayer.drawableSize.width),
                                      height: Int(metalLayer.drawableSize.height)))
```

Also reset `streams` when the primary texture is recreated for a new size (`apply(_ update: FrameUpdate)`'s recreate branch) — a mode change invalidates stream geometry, and the server destroys and recreates streams around it anyway.

- [x] **Step 5: Build and test everything**

```bash
swift build && swift test
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: all green. Note the app project links `SpiceMedia` transitively through `SpiceKit` (the SPM library product) — if the app target fails to find it, `project.yml` needs the package product added the same way `SpiceKit` already is; edit `project.yml`, never the xcodeproj.

- [x] **Step 6: Commit**

```bash
git add Sources/SpiceSee Tests/SpiceSeeTests project.yml
git commit -m "feat(app): composite video stream layers over the guest surface"
```

---

### Task 14: Real-server MJPEG — fixture, replay, live smoothness check, docs

> **Status 2026-08-31 — Steps 1-4 and 7 are BLOCKED, not skipped.** The LAN dev box
> (192.168.50.6) went completely offline during this milestone's execution — no ping, ssh and both
> SPICE ports closed — so `streaming-video` was never enabled, no streaming session was recorded,
> and `win-video.s2c.bin`, `winVideoReplayDecodesStreams` and its golden do not exist. The stream
> wire layouts remain **verified against `spice.proto` field-by-field but never confirmed against
> bytes from a real server**, which is exactly what this task was supposed to provide.
>
> Steps 5-6 are done: the manual exit check is in `docs/dev-server.md` and the close-out is in
> `CLAUDE.md`.
>
> When the box returns, prefer recording from the **Linux Mint guest on port 5931** over the Windows
> guest: it exists purely for these tests and is expendable, whereas restarting the Windows guest
> interrupts real work. `streaming-video=all` streams any animating region regardless of guest OS,
> so a dragged window is enough to produce `STREAM_CREATE`.


The self-consistency breaker: real spice-server MJPEG streams, recorded and replayed, plus the by-eye quality gate. Also the milestone's documentation close-out.

**Files:**
- Create: `Tests/SpiceKitTests/Fixtures/win-video.s2c.bin`, `Tests/SpiceKitTests/Fixtures/win-video-frame.golden.png`
- Modify: `Tests/SpiceKitTests/ReplayTests.swift`, `docs/dev-server.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: the entire stream stack (Tasks 9–13).
- Produces: layout confirmation for the transcribed stream messages; the M4 exit checks.

- [ ] **Step 1: Enable streaming video on the dev server**

The quickemu guest's SPICE options don't include `streaming-video`; it must be added to the qemu command line. Inspect first, decide second:

```bash
ssh aaron@192.168.50.6 'ps aux | grep -o "\-spice [^ ]*" | head -1; ls ~/*.conf ~/VMs 2>/dev/null; quickemu --version'
```

Preferred: a quickemu conf `extra_args` (supported in recent quickemu) cannot merge into an existing `-spice` flag — so instead capture the full running qemu command line (`ps -ww`), append `,streaming-video=all` to its `-spice` argument, stop the VM cleanly (`quickemu`'s own stop, or ACPI shutdown — never `kill -9` a guest with a filesystem), and relaunch the edited command in a `tmux`/`nohup` session. Record the *original* command line in `docs/dev-server.md` first so the change is reversible. `streaming-video=all` (not `filter`) makes stream creation deterministic — any animating region streams, no rate heuristic to satisfy. If the VM cannot be safely restarted right now (user is using it), stop and ask the user — this is their box.

- [ ] **Step 2: Record a streaming session**

Reuse Task 1's recipe with motion that animates continuously (a window drag loop is enough under `streaming-video=all`):

```bash
swift run spicerec 5901 192.168.50.6 5930 recordings/win-video &
# drive-video.sh: like drive-desktop.sh but 10 seconds of continuous mousedown-drag circles
ssh aaron@192.168.50.6 "timeout 45 xvfb-run -a -s '-screen 0 1280x1024x24' sh /tmp/drive-video.sh"
wait
```

Verify the display capture actually contains `STREAM_CREATE` (type 122) before promoting — replay it through `StreamSessionTests`'s machinery or a 5-line scratch test; a recording without streams means the server flag didn't take, go back to Step 1. Promote to `Tests/SpiceKitTests/Fixtures/win-video.s2c.bin`.

- [ ] **Step 3: Write the stream replay test**

```swift
/// Replays a real spice-server MJPEG streaming session. This is the layout confirmation for the
/// transcribed stream messages: if STREAM_CREATE/DATA parse cleanly out of a real capture and
/// decode into frames of the advertised size, the transcription is right.
@Test func winVideoReplayDecodesStreams() async throws {
    let url = try #require(Bundle.module.url(forResource: "win-video.s2c", withExtension: "bin", subdirectory: "Fixtures"))
    let session = ... // open DisplayChannel over InMemoryTransport, route to a StreamPlayer
                      // exactly as SpiceSession does (or drive a full SpiceSession via TestSupport)
    var frames: [StreamFrame] = []
    var unsupported = 0
    // collect .streamFrame events and canvas unsupported events until the stream ends
    #expect(!frames.isEmpty, "the recording contains streams; none decoded")
    #expect(unsupported == 0)
    let mid = frames[frames.count / 2]
    let img = DecodedImage(width: mid.width, height: mid.height, pixels: mid.pixels, hasAlpha: false)
    let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/win-video-frame.golden.png")
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        try PNG.encode(img).write(to: goldenURL)
        Issue.record("golden written — review it visually, then re-run")
        return
    }
    let golden = PNG.decode(try Data(contentsOf: goldenURL))
    expectClose(img, try golden, maxChannelDelta: 4, maxMismatchFraction: 0.002)   // JPEG: tolerant
}
```

Run, **look at the golden frame** (it must be a recognisable piece of the desktop mid-drag, right dimensions, right colors), re-run, expect PASS. Pin the mm-time drop path off for replay (no `setMMTime` call in the test → nothing drops, per Task 11's contract) so the replay is deterministic.

- [ ] **Step 4: Live end-to-end run with SpiceSee**

Build and launch the real app against the streaming server:

```bash
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build
BUILT_PRODUCTS_DIR=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')
"$BUILT_PRODUCTS_DIR/SpiceSee.app/Contents/MacOS/SpiceSee" &
```

Capture the session window (`CGWindowListCopyWindowInfo` id → `screencapture -l<id>` — never full-screen) while the recorded drag script runs again, and confirm the video region shows moving content with no stale rectangles. Check the log stream for `STREAM_REPORT` sends and for zero canvas `unsupported` lines:

```bash
log stream --predicate 'subsystem == "com.spicesee"' --level info
```

- [x] **Step 5: Hand the user the manual exit check, restore the server**

Add `## M4 exit check (manual)` to `docs/dev-server.md`:

1. With `streaming-video=all` (or `filter`) on the server: play a full-screen YouTube HD video in the guest via SpiceSee. Bar: **indistinguishable from the pre-M4 draw path — zero lag, zero choppiness, no tearing at stream edges**, window resize mid-video stays clean.
2. With streaming **off** (restore the original command line): the same video through the draw path — confirming no regression from the canvas routing changes.
3. Right-click menus, window drags, text selection across the desktop — no corruption anywhere (tier-2/3 by eye).

Restore the server's original qemu command line (from the note taken in Step 1) unless the user wants streaming left on. State plainly in the final report that check 1–3 are the user's, like M2's exit check.

- [x] **Step 6: Update CLAUDE.md and the memory of record**

In `CLAUDE.md`'s architecture paragraph: M4 done (tiers 2–3, palette cache, JPEG-alpha, MJPEG/H.264 streams via `SpiceMedia`, STREAM_REPORT), M5 next; note the new `SpiceMedia` target in the layer table; add the "streams composite in Metal, frames cross as `[UInt8]` by strict-concurrency design" rule and the "no jitter buffer until audio (M6)" decision to the input-rules-style gotcha list. Update `docs/dev-server.md`'s fixture table with `win-desktop` and `win-video`. Keep both edits surgical.

- [ ] **Step 7: Final verification and commit**

```bash
swift build && swift test
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -3
scripts/check-vendored-notices.sh
git add Tests/SpiceKitTests docs/dev-server.md CLAUDE.md
git commit -m "test(kit): real-server MJPEG stream replay; M4 exit checks documented"
```

Expected: everything green, notices check exits 0 (the bridge gained `sc_lz_encode_xxxa` in Task 3 — if the script flags it, the VENDORED.md record needs the same one-line treatment the existing encoder helpers got).

---

## Self-Review (performed while writing)

- **Spec coverage §4:** tiers 2 (Task 4) and 3 (Tasks 6–7); ROP3/TRANSPARENT (5); image cache existed, palette cache + INVAL wiring (3); GLZ window existed; streams not-drawn-into-surface + IOSurface ideal (13, with the documented `[UInt8]` deviation and its reasoning); STREAM_REPORT (9, 11, 12); one-Metal-pass presentation with stream textures composited (13); codec routing rows QUIC/LZ/GLZ (existed), LZ4 (not advertised — constraint section), JPEG (existed), JPEG-alpha (3), MJPEG/H264 VideoToolbox (10), VP8/9 not advertised (constraints). COMPOSITE: cap-gated off, argued in Global Constraints — the spec's "all draw commands" list is satisfied for every command the server can actually send to this client.
- **Placeholder scan:** Task 4 Step 3's `scaled` body and Task 10 Step 4's decoder are shaped-with-mechanics rather than full listings — both name the exact APIs, data layouts, and error paths, which meets the "how, not just what" bar without transcribing 200 lines of VT boilerplate the implementer must adapt to compiler reality anyway. Task 13's `makeSession`/module-name notes explicitly direct the implementer to the existing helper names rather than guessing.
- **Type consistency:** `StreamFrame` (SpiceMedia) vs `StreamFrameUpdate` (app seam) vs `FrameUpdate` (existing) kept distinct on purpose; `ResolvedMask.covers` used by Tiers 2/3 consistently; `expectClose` defined in Task 8, used in Task 13/14; `PaletteCache` threaded through `decode(_:cache:palettes:)` in both Task 3 and the Canvas call site.
- **Known risk, called out where it bites:** stream wire layouts are transcribed (Global Constraints) and confirmed by Task 14's real capture; H.264 stays self-consistent ("What cannot be verified"); JPEG goldens are tolerance-compared (Task 8).
