# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SpiceSee is a native macOS SPICE client (remote console for Proxmox VE and plain QEMU/libvirt guests).

## General Rules:
- Before implementing any new function or type, grep the codebase for something that already does this.
- If you're not sure whether a change affects other parts of the system, say so explicitly before writing code, don't guess and proceed.
- Performance first: Choose optimal algorithms and data structures.
- Modern syntax: Use language-specific best practices, async/await patterns, and native methods.

## Commenting & Documentation Rules
- No obvious comments: Do not explain what the code does if it is readable.
- Explain the Why: Only use comments to explain complex business logic, non-obvious workarounds, or critical edge cases.
- Docstrings: Provide concise docstrings for public APIs, complex functions, and modules. State parameters and return types clearly.

## Two build systems, and what each one covers

This trips people up: **`swift build` does not compile the app.**

- `Package.swift` builds the engine only — `CSpiceCodec`, `SpiceWire`, `SpiceCore`, `SpiceCanvas`, `SpiceKit`, plus the `spicesee-cli` and `spicerec` executables. Nothing there imports SwiftUI, which is what keeps the whole stack testable headless.
- `SpiceSeeTests` is the app target's own test bundle. It compiles `Sources/SpiceSee` **into itself** rather than hosting the app, because the Debug app is a launcher stub plus `SpiceSee.debug.dylib` and a `TEST_HOST` bundle cannot load that reliably. It is where anything needing AppKit — `ClipboardBridge` and `NSPasteboard`, say — gets covered; `swift test` never sees this code, which is how a clipboard bug that only broke one direction shipped.
- The app target lives in `Sources/SpiceSee/` and is **not** a member of the SPM package. It is built by an Xcode project generated from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen). `SpiceSee.xcodeproj` is generated output and is gitignored — never edit it, edit `project.yml`.

```bash
# engine libraries + tests
swift build
swift test
swift test --filter SpiceWireTests          # one test target
swift test --filter packageBuilds           # one test

# the app (re-run xcodegen after adding or removing files under Sources/SpiceSee)
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build

# the app's own tests — `swift test` does NOT cover Sources/SpiceSee
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test

# regenerate app + document icons into Assets.xcassets (idempotent)
swift Tools/make-icons.swift
```

Swift 6 language mode with strict concurrency, macOS 14 deployment target, arm64 only. No locks, no `@unchecked Sendable`.

**Clean up app builds when a piece of work ends.** Every checkout (worktrees included) gets its own
`~/Library/Developer/Xcode/DerivedData/SpiceSee-*`, so `SpiceSee.app` copies accumulate and Spotlight
becomes a lottery for which one is current. When a worktree or milestone is done: delete its
DerivedData directory (`defaults read <dir>/info WorkspacePath` says which checkout owns it), and if
`~/Applications/SpiceSee.app` exists, refresh it from the main checkout's Release build so the
launchable copy is never stale. The main checkout's DerivedData is the only one that should survive.

## Running against a real SPICE server

The dev server is a quickemu Windows guest on the LAN, not a local process — endpoint, ticket state
and the bug it flushed out are in `docs/dev-server.md`. `scripts/dev-server.sh` reports reachability.

```bash
swift run spicesee-cli connect 192.168.50.6 5930            # prints MAIN_INIT and the channel list
swift run spicesee-cli dump 192.168.50.6 5930 5 /tmp/f.png  # captures the guest for 5s, writes a PNG
swift run spicerec 5901 192.168.50.6 5930 recordings/x      # recording TCP proxy, one file per channel
swift run spicesee-cli audio 192.168.50.6 5930 15 /tmp/guest.wav   # records the playback channel to a WAV
```

`spicerec` is how fixtures are made: proxy a *reference* client (`remote-viewer` under `xvfb-run`,
since the guest host is headless) and keep the per-channel captures. `Tests/SpiceKitTests/Fixtures/`
holds the display and main recordings plus `win-display.golden.png`; `ReplayTests` renders the
recording headless and compares pixel-for-pixel, so a regression anywhere in the stack fails there
first. **Only commit a golden you have actually looked at.**

`scripts/check-vendored-notices.sh` must exit 0 before any release — it enforces the LGPL record in
`Packages/CSpiceCodec/Sources/CSpiceCodec/VENDORED.md`. Re-run it after touching anything under `vendor/`.

## Running the app without a SPICE server

`MockSessionBackend` still drives every screen for design review. All flags are gated behind `--mock`:

```bash
open -n /path/to/SpiceSee.app --args --mock --scenario desktop --autoconnect
```

On this machine that form opens no window — `open --args` lands the flags in `NSArgumentDomain`,
which this app doesn't read that early. The form that works is launching the built binary directly
with the mock env var:

```bash
BUILT_PRODUCTS_DIR=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings | grep BUILT_PRODUCTS_DIR | awk '{print $3}')
SPICESEE_MOCK=1 "$BUILT_PRODUCTS_DIR/SpiceSee.app/Contents/MacOS/SpiceSee" --scenario desktop --autoconnect
# quit with: osascript -e 'tell application "SpiceSee" to quit'
```

- `--scenario desktop | noAgent | refused | badPassword | certMismatch | migrate` — drives connect progress, the three failure sheets, the migration sheet, agent states, and a synthetic framebuffer.
- `--autoconnect` — connects the selected host on launch.
- `--open acknowledgements` — opens that window at launch. (`--open settings` exists but is unreliable that early in launch; use ⌘, once the app is frontmost.)

## Architecture

**Dependency rule is strictly downward.** `SpiceCanvas` knows nothing about sockets; `SpiceCore` knows nothing about pixels. Everything below `SpiceKit` is designed to run headless from recorded bytes, which is what makes the replay golden tests possible.

```
SpiceWire    wire types, bounds-checked reader/writer  ← the security boundary
SpiceCore    transport, TLS, link handshake, channel actors
SpiceCanvas  surfaces, draw commands, image cache, codec routing
SpiceMedia   video streams: VideoToolbox MJPEG/H.264 decode, mm-time pacing, STREAM_REPORT; audio: AudioToolbox Opus decode, mm-clock gate
SpiceKit     facade: SpiceSession, all the app sees — bar VVDocument, which parses SpiceCore.VVFile
SpiceSee     SwiftUI + AppKit app
```

**M0–M4 are done, with one caveat on M4 spelled out below: a real guest renders, can be driven, a `.vv` connects over TLS, every draw command is implemented, and video streams decode and composite.** `docs/superpowers/plans/2026-08-22-spicesee-m0-m1-pixels.md`, `docs/superpowers/plans/2026-08-24-spicesee-m2-input.md`, and `docs/superpowers/plans/2026-08-24-spicesee-m3-proxmox.md` (all tasks ticked) built the stack; `docs/superpowers/specs/2026-08-22-spicesee-design.md` is the design spec it argues from. What exists now: the link handshake with ticket auth, main/display/inputs/cursor channels, the vendored QUIC/LZ/GLZ codecs, tier-1 draws, `SpiceSession`, positional keyboard mapping (`SpiceKit.KeyMap`), both mouse modes with server-mode capture, the guest cursor, `.vv` file parsing, TLS pinned to the file's CA with `host-subject` matching, migration reconnect messages, and opening a `.vv` connects immediately. **Clipboard sharing (part of M5) landed early**, out of milestone order, because ⌘V was the bug report that surfaced it: the VD agent protocol (`SpiceWire.AgentMessages`), agent capability negotiation and token flow control (`SpiceCore.AgentSession`), and UTF-8 text in both directions with the guest's line endings, bridged to `NSPasteboard` by `SpiceSee.ClipboardBridge`. **M4 added** draw tiers 2–3 (general ROPs, brushes, masks, scaled blits, ROP3, TRANSPARENT, STROKE, TEXT), the palette cache and JPEG-alpha, and the video-stream path: `SpiceMedia` decodes MJPEG and H.264 through VideoToolbox, paces frames against the mm clock, and sends `STREAM_REPORT` so the server adapts bitrate. **M5 added** the viewport head model (`SpiceKit.ViewportMapper`: `HeadRect`, `ViewportLayout`, per-head dirty-rect slicing, `MonitorTiling`), one `Canvas` per display channel in `SpiceSession` with `SessionEvent.canvas(_, displayID:)`/`.monitorsConfig(_, displayID:)`, resize-follows-window over `VD_AGENT_MONITORS_CONFIG` gated on the guest's `monitorsConfig` cap (encoder pinned by `Tools/agentref.c`, `AgentSession.clientCaps` also announcing `sparseMonitorsConfig`), a debounced (250 ms) resize path with first-report and guest-size loop guards, a working HiDPI toggle, and `ClipboardKind {text, png}` with PNG clipboard images both ways. **M6 added** the playback channel (`SpiceWire.PlaybackMessages`, `SpiceCore.PlaybackChannel`), `SpiceMedia.OpusDecoder` probing AudioToolbox for Opus at connect time, `AudioPlayer` applying the same 80 ms drop-before-decode rule as video, `SpiceSee.AudioOutput` playing PCM through an `AVAudioPlayerNode` behind a 50 ms prebuffer, a toolbar mute that is now real, and `spicesee-cli audio` for probing a live server's playback channel. **M6 carries M4's caveat: the audio DATA path has not been seen against a real server** — a live probe parsed PLAYBACK_VOLUME and PLAYBACK_MUTE from the real thing, but nothing was playing in the guest, so START/MODE/DATA, Opus decode and the output are covered by unit tests and the libopus fixture only; `docs/dev-server.md`'s `## M6 exit check (manual)` is that check. What does not exist: file transfer, the record (microphone) channel, and the rest of the agent — pointer, audio volume — which SpiceSee deliberately does not announce a capability for. M7 (ship) is next. Later plans are written one at a time, after the previous milestone ships. M2 shipped pending the manual exit check in `docs/dev-server.md` (`## M2 exit check (manual)`) — synthetic input is impossible on this machine, so that step is the user's. M3's exit criterion **was** driven from this machine, unlike M2's (`docs/dev-server.md`, `## M3 exit criterion`): a cold `open` of a `.vv` file connected over TLS end to end, confirmed server-side by connections landing on the TLS port and none on the plain one. **A genuine Proxmox `.vv` was exercised end to end on 2026-08-31** — proxy, TLS, one-shot ticket, all four channels, guest agent — and found three shipped bugs, each invisible to LAN testing: (1) Proxmox routes every console through pveproxy's HTTP CONNECT proxy (`proxy=` key; the file's `host` is an opaque token only the proxy can resolve) and the key was being ignored — `VVFile` now parses it into `HTTPConnectProxy` and `NWTransport` tunnels via `ProxyConfiguration`; (2) a long-idle Linux guest blanks its console and the qxl driver destroys the primary surface, so the display channel stays silent until *input* wakes it — the viewport window was gated on that surface, a deadlock `SessionModel.displayGraceSeconds` breaks by opening a placeholder viewport after 2 s; (3) spice-server zlib-wraps GLZ (`ZLIB_GLZ_RGB`, type 107) for clients it classifies low-bandwidth — a VPN link, never a LAN one — and the image's TWO length fields (`glz_data_size`, then `data_size`) were read as one, dropping every draw as truncated. Diagnosis ran on `ChannelReader`'s debug-level wire tracing (`log stream --predicate 'subsystem == "com.spicesee"' --debug`) plus the display drop log's public payload hex — keep both. Still untested against the real thing: a real live migration — the migration wire layout is transcribed from `spice.proto` with **no local header confirming it**; it parses defensively and drops what it cannot read.

**M4's caveat, stated plainly: none of it has been seen working against a real server.** The draw tiers and the whole stream path are covered by unit tests only. Neither guest on the dev box emits a single tier-2/3 draw command — Windows 11's QXL driver is WDDM and composites in-guest, and the Linux guest's X server loads `modesetting` because `xf86-video-qxl` cannot bind under KMS — so the "zero unsupported on a real desktop recording" gate the plan proposed is vacuous and was relabelled a tier-1 regression canary (`docs/dev-server.md`, "Where tier-2/3 draw commands actually come from"). The MJPEG stream fixture was never recorded: the box went offline before `streaming-video` could be enabled. H.264 is verified only against VideoToolbox's own encoder — self-consistent by construction. So tiers 2-3, MJPEG and H.264 all still want a real-traffic check; `docs/dev-server.md`'s `## M4 exit check (manual)` is that check.

M4 rules that are easy to break: **video streams are never drawn into the surface** — they are composited over the primary quad in `GuestSurfaceView`'s Metal pass, scissored to the stream clip (design spec §4), and the scissor is reset before the cursor overlay or the cursor gets clipped to the last stream's rect. Decoded frames cross actor boundaries as `[UInt8]` BGRA, not `CVPixelBuffer`/`IOSurface`, because strict concurrency rules those out between actors — do not "optimize" that with an unsafe `Sendable` wrapper. There is **no jitter buffer**: a frame more than 80 ms behind the mm clock is counted and dropped *before* decode, since dropping after decode wastes exactly the CPU the drop protects; M6 shipped with no lip-sync buffering — audio and video are each paced to the mm clock independently, deliberately, not synced to each other. Like `AgentEvent`, a `StreamFrame` carries its `dest`/`clip` **as they stood when the data arrived** — stamped on the event, never queried back, because a later `STREAM_CLIP` would otherwise answer for the wrong moment. Mask origins are bbox-relative (`dst − bbox.topLeft + mask.pos`) everywhere *except* TEXT glyphs, which upstream places in absolute surface coordinates at `renderPos + glyph_origin`; that asymmetry is real and was confirmed against `canvas_base.c`. `VideoDecoder`'s synchronous decode leaves a `#SendableClosureCaptures` warning that is expected and documented in place — do not silence it with a lock, `@unchecked Sendable` or `nonisolated(unsafe)`.

M6 rules that are easy to break: **audio never touches a realtime render thread** — `AudioOutput.scheduleBuffer`, called from the main actor, is the whole output path, and the ~50 ms prebuffer in `AudioOutput` is the only jitter buffer in the system. **Two volume controls multiply**: guest volume/mute lands on the `AVAudioPlayerNode`, toolbar mute on the mixer — never fold one into the other. `AVAudioMixerNode.outputVolume` changes are smoothed over one render cycle — ordinary anti-click behaviour, not a bug — so a mute test must render one window past the change before asserting silence, as `Tests/SpiceSeeTests/AudioOutputTests.swift`'s `toolbarMuteSilencesTheMixerButNotThePlayer` does. The **Opus capability is announced only when `OpusDecoder.isAvailable()` passes** its `AudioConverterNew`/`kAudioFormatOpus` probe at connect time — do not hard-code it, and never test the decoder against an Apple-encoded fixture; the fixture is libopus-encoded via `Tools/opusref.c` so the decoder is never tested against itself. **A closed playback channel ends audio, not the session** — unlike display or cursor, whose loss is fatal: the pump yields `.audio(.stopped)` and the session runs on, because a guest that loses its sound device still has a working desktop. `PLAYBACK_START` is validated before anything is sized from it (1–8 channels, 8–192 kHz, S16): those are wire-controlled u32s and a large channel count traps or allocates.

Input rules that are easy to break: `SpiceSession.send`/`SessionBackend.sendInput` are synchronous and ordered on purpose — never wrap an input event in its own `Task`. Caps lock is synced as lock *state* (`INPUTS_KEY_MODIFIERS`), never sent as a scancode. AppKit never routes a `keyUp` to the responder chain while ⌘ is held — `NSApplication` receives it and drops it — so `GuestInputView` picks those off a local event monitor; without it a ⌘ chord leaves its letter made and the guest auto-repeats it forever. ⌘ maps to **Super** by default (design spec §6), which means ⌘V in the viewport is Win+V and *not* paste: paste in the guest is ⌃V, or the user sets ⌘→Ctrl per connection. This is deliberate — do not "fix" it by special-casing the clipboard chords. `ViewportTransform` is the single source of fit/1:1 geometry for present, mouse mapping and the cursor overlay, and takes a `backingScale` so 1:1 means one guest pixel per *device* pixel. Keys go out as `INPUTS_KEY_SCANCODE` (message 104, raw scancode bytes) when the server advertises the capability, falling back to `KEY_DOWN`/`KEY_UP` (101/102) otherwise — the plan assumed 101/102 only; `remote-viewer` against the dev server proved otherwise (`docs/dev-server.md`). `SpiceKitBackend`'s input FIFO has exactly one consumer, started in `init` and never cancelled — cancelling an `AsyncStream` consumer would leave every later session silent, and a second consumer would race the first for elements — with `.begin`/`.end` sentinels carrying the session they delimit so an unwinding connect cannot silence the session that replaced it. Viewport ids are `displayID << 8 | headID`, where the head half is the guest's **own monitor id** from `DISPLAY_MONITORS_CONFIG` (clamped to `0...255`), never a position in the head list — windows key on the id, and deriving it positionally renumbered every head that survived a removal, orphaning its window and opening a second. The input FIFO carries `ViewportMapper` snapshots (`Queued.layout`) — never read layout state back from outside the FIFO, for the same stamped-not-queried reason as `AgentEvent`. `.monitorsConfig` is yielded straight onto the session's event continuation while canvas events take an extra hop through the per-display canvas pump, so it can arrive *before* the `surfaceCreated` that preceded it on the wire; `ViewportMapper` and the adapter are order-tolerant by design.

The dev guest is now in **client** mouse mode (USB tablet), so server-mode capture can only be exercised via `--mock --scenario noAgent`.

**TLS and `.vv`.** When the `.vv` embeds a `ca` it is the *only* trust anchor (`SecTrustSetAnchorCertificatesOnly`); with no `ca` the system store is the anchor instead. Identity is checked on both paths, as in spice-gtk: with a `host-subject` the peer's subject is compared entry-by-entry in DER order under a basic X.509 policy, and without one the dialled hostname is verified by the chain evaluation itself (`SecPolicyCreateSSL`). Never neither — a policy that skips both accepts any certificate for any name. `TLSPolicy.verify` holds every trust decision and is testable without a socket — the `sec_protocol` verify block in `NWTransport` is plumbing only. That block can answer the handshake with a plain yes/no, so the *reason* for a no travels out through a synchronous `AsyncStream` yield before `complete(false)` — never turn that into a `Task` hop, or the rejection reason can arrive after the connection has already failed generically. That ordering is also what makes a refused certificate surface as `SpiceError.tls` rather than a bare `.connect` failure. `Certificates.subjectComponents` throws on an unreadable subject entry rather than dropping it — fail closed, since a silently shortened subject could spuriously match a shorter `host-subject`. Tickets are never persisted or logged. `scripts/dev-tls.sh` plus `socat` on the dev box is how the TLS path is exercised against a real (non-SPICE) TLS implementation; `.dev-tls/` is gitignored.

**`SessionBackend` is the seam.** The UI talks to a protocol (`Sources/SpiceSee/SessionBackend.swift`), never to SPICE. `SpiceKitBackend` is the real implementation and `MockSessionBackend` still backs `--mock` for design review, so every screen stays reviewable without a server. Landing the real engine required **no view changes**; M3 needed two small sanctioned ones (certificate subjects wrapping in the failure sheet, the `.vv` import call site in `ConnectionManagerView`). Keep the bar there: **if a view needs editing to accommodate the engine, the seam is wrong — fix the adapter, not the view.** Error classification lives in `SpiceKit.ConnectFailureKind` (tested); the failure wording stays in the app, and the raw `SpiceError` goes to the log, never to the sheet.

**`SpiceWire` is the security boundary.** Every reader accessor throws; a hostile or malformed server message must produce a caught error, never a trap. No `!` unwraps or unchecked subscripts on wire data. `AgentReassembler` is part of this: `VDAgentMessage.size` is server-controlled and unbounded in the protocol, so it is capped before anything is allocated, and a length it refuses drops the agent rather than resynchronising into rubbish.

**Transcribing a C struct by eye is not good enough.** `VDAgentMessage` is `SPICE_ATTR_PACKED` and therefore **20 bytes**, not the 24 that natural alignment of its `uint64` implies — a wrong guess puts every field four bytes out and the guest simply never answers. `Tools/agentref.c` builds each agent message with the real `spice/vd_agent.h` structs and macros and prints the bytes; `AgentMessagesTests` pins the encoder against that output. Do the same for any new packed struct.

**Anything the agent decides is stamped onto the event, not queried back.** `AgentEvent` carries `clipboardReady` and `guestWantsCRLF` as they stood when the message arrived, because the consumer runs in its own task: a later message can change the capabilities — or drop the agent — before an earlier event is interpreted, and re-reading the actor would answer for the wrong moment. `ClipboardBridge` follows the input FIFO's shape for the same class of reason: one queue, one consumer started in `init` and never cancelled, so `.guestOffersText` cannot overtake the `.available(true)` that enables it. Both text and PNG images are fetched from the guest eagerly, on offer, rather than lazily on paste: `NSPasteboardItemDataProvider` is synchronous and cannot await the agent.

## UI conventions

`docs/design/design-text.txt` (a plain-text extraction of `docs/design/SpiceSee UI.dc.html`) is the authoritative UI spec — it carries every dimension in points, SF Symbol name, and semantic color. When the text is ambiguous, grep the `.dc.html` for the label and read the surrounding inline styles.

- `Sources/SpiceSee/Theme.swift` owns all dimensions (`Metric.*`) and the single tint token `Color.chiliRed`. Add constants there rather than scattering literals; everything not accent is a macOS semantic color.
- Chili red is the *accent* only. Status uses system colors — green connected / amber no-agent / neutral negotiating, green completed step. Do not tint status affordances red.
- **Do not draw custom backgrounds behind toolbar controls.** macOS draws its own item chrome, which is taller than the design's 22pt control, and the two cannot be kept in register — this caused repeated misalignment and overhanging hover highlights. Toolbar state is carried by color alone.
- **A connection's name is the detail pane's heading, and that heading *is* the rename field** — artboard 01 has no `Name:` row, so editing happens in place rather than as a new form row. Until someone names it, the name follows the host (`SavedConnection.hostDidChange`, applied on edit and again when the store loads); an emptied field hands the name back to the host. `nameIsCustom` is `Optional` **on purpose**: synthesised `Codable` throws on a missing key even with a default value, and `ConnectionStore` decodes with `try?`, so a non-optional field added to `SavedConnection` silently empties every saved connection. Add fields there as optionals, and cover them in `ConnectionNamingTests`.
- `Sources/SpiceSee/SessionPresentation.swift` is the glue deciding which window presents what (failure sheet, migration sheet, opening viewport windows). Screens themselves are self-contained views.
- Licences in `Sources/SpiceSee/Licenses/` are a resources build phase and land **flat** in `Contents/Resources/`, not in a `Licenses/` subdirectory — look them up accordingly.

## Verifying UI work on this machine

`osascript`/System Events has no assistive access and synthetic `CGEvent` mouse events are ignored, so **you cannot hover, click, or open menus**. Static layout is still verifiable:

- Get a window id from `CGWindowListCopyWindowInfo`, then `screencapture -l<id> out.png`. **Never take a full-screen screenshot** — it captures the user's unrelated private screen content.
- To compare against the design, strip the `<x-dc>`/`<helmet>` wrapper off the `.dc.html`, serve it over `http://127.0.0.1`, and open it in Chrome (the browser tools refuse `file://`).
- Measuring pixel rows/columns of a captured window beats eyeballing — it is how the "window is too tall" bug was traced to SwiftUI sizing the window to the screen's visible height rather than to content.
- Hover states and anything full-screen must be handed to the user to verify; say so rather than claiming it works.

## Licensing constraint (affects distribution)

The SPICE image codecs (`quic.c`, `lz.c`, GLZ decoder) are LGPL-2.1+ and unavoidable — the server defaults to `auto_glz` with no client opt-out. Plan task 13 vendors them into `CSpiceCodec`, which **must** build as a dynamic framework embedded in the bundle, with `com.apple.security.cs.disable-library-validation` so a user can substitute their own build (LGPL §6(b)). This rules out the Mac App Store — the one hard constraint the licence imposes. Everything else about distribution is a choice, not a requirement: because it ships direct, Gatekeeper (not the LGPL) makes Developer ID signing and notarization necessary, and the chosen artifact is a **notarized DMG** hosted at https://somecoolthings.com/spicesee, with Sparkle for updates (M7). A Homebrew cask was considered and **declined** — it asks nothing of the build and would only be a second front door to the same file. The acknowledgements window carries the written offer and must keep doing so.

## Conventions

Conventional-commit prefixes (`feat:`, `fix:`, `build:`, `docs:`, `chore:`). Library code logs via `os.Logger(subsystem: "com.spicesee", category:)` — no `print` outside executables. Tests use Swift Testing (`import Testing`), with fixtures under `Tests/<Target>Tests/Fixtures/`.
