# SpiceSee M5 — Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resize-follows-window over `VD_AGENT_MONITORS_CONFIG` (with the per-connection HiDPI toggle finally doing something), a real viewport/head model for multi-monitor windows, and PNG clipboard images both ways.

**Architecture:** Head-model first. `SpiceCanvas` stays head-ignorant; SpiceKit gains one `Canvas` per display channel, a pure `ViewportMapper` that carves head rects out of primary surfaces and slices dirty rects per head, and a `sendMonitorsConfig` path gated on the guest's capability. The `SessionBackend` seam grows `viewportsChanged`, `requestDisplayLayout`, and kind-aware clipboard methods — no view edits beyond wiring `SessionWindowView`'s size reports.

**Tech Stack:** Swift 6 strict concurrency, SPM engine targets + xcodegen app target, Swift Testing, `Tools/agentref.c` against the real `spice/vd_agent.h`.

**Spec:** `docs/superpowers/specs/2026-09-01-spicesee-m5-agent-design.md` (and `docs/superpowers/specs/2026-08-22-spicesee-design.md` §5 for the monitors model). One correction to the M5 spec discovered during planning: `AdvancedSettings.hiDPI` and the toolbar's HiDPI toggle **already exist** (`Models.swift:60`, `SessionWindowView.swift:157`) — no new `SavedConnection` field is needed; M5 makes the existing toggle effective. And the spec's "bytes fetched only on actual paste" for guest→host images is not implementable on macOS: `NSPasteboardItemDataProvider` is synchronous and cannot await the agent, which is why the shipped **text** path already fetches eagerly on `guestOffers`. Images follow the same eager shape.

## Global Constraints

- Swift 6 strict concurrency; **no locks, no `@unchecked Sendable`, no `nonisolated(unsafe)`**. Cross-actor pixel data is `[UInt8]`.
- `SpiceWire` is the security boundary: every reader accessor throws; no `!` unwraps or unchecked subscripts on wire data.
- Packed C structs are never transcribed by eye: `Tools/agentref.c` builds them with the real headers and the test pins our encoder against its printed bytes.
- The `SessionBackend` seam rule: if a view needs editing to accommodate the engine, fix the adapter. (Wiring a new seam method into a view is sanctioned; reshaping a view for engine reasons is not.)
- Library code logs via `os.Logger(subsystem: "com.spicesee", category:)`; no `print` outside executables.
- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`). Tests use Swift Testing (`import Testing`).
- `SpiceSession.send` / `sendInput` stay synchronous and ordered — never wrap input in its own `Task`.
- After adding/removing files under `Sources/SpiceSee/` **or** `Tests/SpiceSeeTests/`: `xcodegen generate` before building the app or its tests.
- Engine tests: `swift test`. App-target tests: `xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test`.

## File Structure

| File | Role in M5 |
|---|---|
| `Sources/SpiceWire/AgentMessages.swift` | + `AgentMonitorConfig`, `AgentMonitorsFlags`, `.monitorsConfig` encoder |
| `Tools/agentref.c` | + monitors-config reference bytes; sparse cap added to announce |
| `Sources/SpiceCore/AgentSession.swift` | + `guestSupportsMonitorsConfig`; clientCaps gains sparse cap |
| `Sources/SpiceKit/SpiceSession.swift` | per-display canvases; displayID-tagged events; `.monitorsConfig` event; `sendMonitorsConfig` |
| `Sources/SpiceKit/ViewportMapper.swift` (new) | `HeadRect`, `ViewportLayout`, slicing, pixel extraction, `MonitorTiling` |
| `Sources/SpiceSee/SessionBackend.swift` | + `viewportsChanged`, `DisplayLayout`, `requestDisplayLayout`, `ClipboardKind` seam |
| `Sources/SpiceSee/SpiceKitBackend.swift` | mapper-driven routing; input origin translation; new seam methods |
| `Sources/SpiceSee/SessionModel.swift` | viewport list updates; resize debounce; HiDPI scaling |
| `Sources/SpiceSee/SessionWindowView.swift` | size/close reporting only |
| `Sources/SpiceSee/ClipboardBridge.swift` | image offers/requests/writes |
| `Sources/SpiceSee/MockSessionBackend.swift` | second display frames; resize response |
| `Sources/spicesee-cli/main.swift` | `resize` probe; clipboard `--send-image`/`--save-image` |
| `docs/dev-server.md`, `CLAUDE.md` | M5 exit checks; architecture paragraph |

Tests: `Tests/SpiceWireTests/AgentMessagesTests.swift`, `Tests/SpiceCoreTests/AgentSessionMonitorsTests.swift` (new), `Tests/SpiceKitTests/ViewportMapperTests.swift` (new), `Tests/SpiceSeeTests/ResizeRequestTests.swift` (new), `Tests/SpiceSeeTests/ClipboardBridgeTests.swift`.

---

### Task 1: `VD_AGENT_MONITORS_CONFIG` wire encoder, pinned by agentref

**Files:**
- Modify: `Tools/agentref.c`
- Modify: `Sources/SpiceWire/AgentMessages.swift`
- Test: `Tests/SpiceWireTests/AgentMessagesTests.swift`

**Interfaces:**
- Produces: `AgentMonitorConfig(width:height:depth:x:y:)` (all `UInt32` except `x,y: Int32`), `AgentMonitorsFlags.usePosition`, `AgentMessage.monitorsConfig(flags: UInt32, monitors: [AgentMonitorConfig])` — encode-only (the guest never sends this type to the client; `init(frame:)` keeps routing type 2 to `.other`).

The wire layout (from `spice/vd_agent.h`, both structs `SPICE_ATTR_PACKED`): `VDAgentMonitorsConfig { u32 num_of_monitors; u32 flags; }` followed by one `VDAgentMonConfig { u32 height; u32 width; u32 depth; i32 x; i32 y; }` per monitor — **height before width**, which is exactly the field-order trap agentref exists to catch. A disabled monitor (sparse config) is an all-zero entry.

- [ ] **Step 1: Extend `Tools/agentref.c`** — append before `return 0;`:

```c
    /* MONITORS_CONFIG, flags=USE_POS: one enabled 1920x1080 head, then a
       sparse two-head config whose second head is disabled (all zeros). */
    printf("sizeof(VDAgentMonitorsConfig) = %zu\n", sizeof(VDAgentMonitorsConfig));
    printf("sizeof(VDAgentMonConfig)      = %zu\n", sizeof(VDAgentMonConfig));
    printf("flag USE_POS=%d cap MONITORS=%d SPARSE=%d\n",
           VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS,
           VD_AGENT_CAP_MONITORS_CONFIG, VD_AGENT_CAP_SPARSE_MONITORS_CONFIG);

    size_t msize = sizeof(VDAgentMonitorsConfig) + sizeof(VDAgentMonConfig);
    VDAgentMonitorsConfig *mc = calloc(1, msize);
    mc->num_of_monitors = 1;
    mc->flags = VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS;
    VDAgentMonConfig *mon = (VDAgentMonConfig *)(mc + 1);
    mon->width = 1920; mon->height = 1080; mon->depth = 32; mon->x = 0; mon->y = 0;
    msg.type = VD_AGENT_MONITORS_CONFIG; msg.size = msize;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, mc, msize);
    dump("monitors_config_1", buf, sizeof msg + msize);
    free(mc);

    size_t m2size = sizeof(VDAgentMonitorsConfig) + 2 * sizeof(VDAgentMonConfig);
    VDAgentMonitorsConfig *mc2 = calloc(1, m2size);
    mc2->num_of_monitors = 2;
    mc2->flags = VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS;
    VDAgentMonConfig *mons = (VDAgentMonConfig *)(mc2 + 1);
    mons[0].width = 2560; mons[0].height = 1440; mons[0].depth = 32;
    mons[0].x = 0; mons[0].y = 0;
    /* mons[1] stays calloc-zero: a disabled head in a sparse config */
    msg.type = VD_AGENT_MONITORS_CONFIG; msg.size = m2size;
    memcpy(buf, &msg, sizeof msg); memcpy(buf + sizeof msg, mc2, m2size);
    dump("monitors_config_sparse", buf, sizeof msg + m2size);
    free(mc2);
```

- [ ] **Step 2: Build and run agentref; record its output**

Run: `cc -I$(brew --prefix spice-protocol)/include/spice-1 -o /tmp/agentref Tools/agentref.c && /tmp/agentref`
Expected: `sizeof(VDAgentMonConfig) = 20`, and two `monitors_config_*` hex lines. Copy those hex strings **verbatim** — they are the test expectations. (The computed values below should match; if they differ, the C output wins and the discrepancy must be understood, not papered over.)

- [ ] **Step 3: Write the failing test** — append to `AgentMessagesTests.swift`, substituting the hex captured in Step 2:

```swift
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
```

- [ ] **Step 4: Run to verify it fails**

Run: `swift test --filter AgentMessagesTests`
Expected: FAIL — `AgentMessage` has no member `monitorsConfig`.

- [ ] **Step 5: Implement the encoder** in `Sources/SpiceWire/AgentMessages.swift`. Below `ClipboardSelection`:

```swift
/// `VDAgentMonConfig` — one requested guest monitor. All zeros = a disabled head (sparse config).
public struct AgentMonitorConfig: Sendable, Equatable {
    public var width: UInt32, height: UInt32, depth: UInt32
    public var x: Int32, y: Int32
    public init(width: UInt32, height: UInt32, depth: UInt32 = 32, x: Int32 = 0, y: Int32 = 0) {
        self.width = width; self.height = height; self.depth = depth; self.x = x; self.y = y
    }
}

public enum AgentMonitorsFlags {
    /// `VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS`
    public static let usePosition: UInt32 = 1 << 0
}
```

Add the case to `AgentMessage` (after `clipboardRelease`):

```swift
    /// Client → guest only; the guest never sends this type back, so there is no decoder for it.
    case monitorsConfig(flags: UInt32, monitors: [AgentMonitorConfig])
```

And to `frame(hasSelection:)` (before `case let .other`):

```swift
        case let .monitorsConfig(flags, monitors):
            w.u32(UInt32(monitors.count)); w.u32(flags)
            // VDAgentMonConfig is height-first — pinned against the packed C struct in agentref.
            for m in monitors { w.u32(m.height); w.u32(m.width); w.u32(m.depth); w.i32(m.x); w.i32(m.y) }
            return AgentFrame(type: AgentMsgType.monitorsConfig.rawValue, payload: w.bytes)
```

- [ ] **Step 6: Run to verify it passes**

Run: `swift test --filter AgentMessagesTests`
Expected: PASS (all agent message tests, old and new).

- [ ] **Step 7: Commit**

```bash
git add Tools/agentref.c Sources/SpiceWire/AgentMessages.swift Tests/SpiceWireTests/AgentMessagesTests.swift
git commit -m "feat: encode VD_AGENT_MONITORS_CONFIG, pinned against the packed C structs"
```

---

### Task 2: Capability gate and the send path

**Files:**
- Modify: `Sources/SpiceCore/AgentSession.swift`
- Modify: `Sources/SpiceKit/SpiceSession.swift`
- Modify: `Tools/agentref.c` (announce builder gains the sparse cap)
- Test: Create `Tests/SpiceCoreTests/AgentSessionMonitorsTests.swift`; modify `Tests/SpiceWireTests/AgentMessagesTests.swift` (pinned announce bytes change)

**Interfaces:**
- Consumes: `AgentMessage.monitorsConfig(flags:monitors:)`, `AgentMonitorConfig` (Task 1).
- Produces: `AgentSession.guestSupportsMonitorsConfig: Bool` (async, actor-isolated), `AgentSession.clientCaps` now `[clipboardByDemand, clipboardSelection, sparseMonitorsConfig]`, `SpiceSession.sendMonitorsConfig(_ monitors: [AgentMonitorConfig]) async`.

Announcing `sparseMonitorsConfig` is a **client** capability spice-gtk announces (it means "my monitors-config may contain disabled heads"); it is honest now that we send them. Sending itself is gated on the **guest** announcing `monitorsConfig`.

- [ ] **Step 1: Write the failing tests** — `Tests/SpiceCoreTests/AgentSessionMonitorsTests.swift`:

```swift
import Testing
import SpiceWire
@testable import SpiceCore

/// The monitors-config gate: nothing goes out until the guest has said it does monitors config,
/// and what goes out once it has is the message Task 1 pinned.
@Suite struct AgentSessionMonitorsTests {
    private actor Sink {
        private(set) var chunks: [[UInt8]] = []
        func add(_ c: [UInt8]) { chunks.append(c) }
    }

    /// One MAIN_AGENT_DATA payload carrying `m`, as the server would relay it from the guest.
    private func fromGuest(_ m: AgentMessage) -> [UInt8] {
        AgentMessage.chunks(m.frame(hasSelection: true)).flatMap { $0 }
    }

    private func started(_ sink: Sink, guestCaps bits: [UInt32]) async -> AgentSession {
        let agent = AgentSession { chunk in await sink.add(chunk) }
        await agent.setTokens(10)
        await agent.agentConnected()
        await agent.receive(fromGuest(.announceCapabilities(request: false, caps: CapabilitySet(bits: bits))))
        return agent
    }

    @Test func guestWithoutTheCapIsNotSentAConfig() async {
        let sink = Sink()
        let agent = await started(sink, guestCaps: [AgentCap.clipboardByDemand])
        #expect(await agent.guestSupportsMonitorsConfig == false)
    }

    @Test func guestWithTheCapIs() async {
        let sink = Sink()
        let agent = await started(sink, guestCaps: [AgentCap.clipboardByDemand, AgentCap.monitorsConfig])
        #expect(await agent.guestSupportsMonitorsConfig)
        await agent.send(.monitorsConfig(flags: AgentMonitorsFlags.usePosition,
                                         monitors: [AgentMonitorConfig(width: 1920, height: 1080)]))
        // Chunk 0 is our announceCapabilities; the config must have followed it.
        let sent = await sink.chunks
        #expect(sent.count == 2)
        var r = SpiceReader(sent[1])
        _ = try? r.u32()                      // protocol
        #expect((try? r.u32()) == AgentMsgType.monitorsConfig.rawValue)
    }

    @Test func clientAnnouncesSparseMonitorsConfig() {
        #expect(AgentSession.clientCaps.contains(AgentCap.sparseMonitorsConfig))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter AgentSessionMonitorsTests`
Expected: FAIL — no member `guestSupportsMonitorsConfig`; the sparse-cap expectation fails.

- [ ] **Step 3: Implement in `AgentSession.swift`.** Replace the `clientCaps` declaration and its comment:

```swift
    /// What the client announces. Clipboard, plus `sparseMonitorsConfig` because our
    /// `VD_AGENT_MONITORS_CONFIG` may carry disabled heads (M5). Still absent on purpose: the
    /// pointer and audio-volume paths, which SpiceSee does not route — announcing a capability it
    /// does not honour would tell the guest to stop using the paths that do work.
    public static let clientCaps = CapabilitySet(bits: [AgentCap.clipboardByDemand,
                                                        AgentCap.clipboardSelection,
                                                        AgentCap.sparseMonitorsConfig])
```

Below `clipboardReady`:

```swift
    /// Whether a monitors config may be sent: the guest must have announced it applies them.
    public var guestSupportsMonitorsConfig: Bool {
        connected && capsReceived && guestCaps.contains(AgentCap.monitorsConfig)
    }
```

- [ ] **Step 4: Add the session method** in `SpiceSession.swift`, after `releaseClipboard()`:

```swift
    /// Asks the guest to adopt this monitor layout (`VD_AGENT_MONITORS_CONFIG`). Silently absent
    /// without a guest that announced the capability, like every other agent feature. The guest
    /// answers with a new primary surface and/or DISPLAY_MONITORS_CONFIG, never with a reply here.
    public func sendMonitorsConfig(_ monitors: [AgentMonitorConfig]) async {
        guard let agent, await agent.guestSupportsMonitorsConfig, !monitors.isEmpty else { return }
        await agent.send(.monitorsConfig(flags: AgentMonitorsFlags.usePosition, monitors: monitors))
    }
```

- [ ] **Step 5: Update the pinned announce bytes.** In `Tools/agentref.c`, add to the announce builder (after the two existing `VD_AGENT_SET_CAPABILITY` lines): `VD_AGENT_SET_CAPABILITY(caps->caps, VD_AGENT_CAP_SPARSE_MONITORS_CONFIG);`. Rebuild and rerun (`cc -I$(brew --prefix spice-protocol)/include/spice-1 -o /tmp/agentref Tools/agentref.c && /tmp/agentref`), then update `announceCapabilitiesMatchesSpiceGTK` in `AgentMessagesTests.swift`: the caps set becomes `[AgentCap.clipboardByDemand, AgentCap.clipboardSelection, AgentCap.sparseMonitorsConfig]` and the trailing caps word `"60000000"` becomes `"e0000000"` (bits 5, 6, 7) — confirm against the fresh agentref output, and check `ClipboardSessionTests` for any test asserting the announced caps word.

- [ ] **Step 6: Run the affected suites**

Run: `swift test --filter AgentSessionMonitorsTests && swift test --filter AgentMessagesTests && swift test --filter ClipboardSessionTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SpiceCore/AgentSession.swift Sources/SpiceKit/SpiceSession.swift Tools/agentref.c \
        Tests/SpiceCoreTests/AgentSessionMonitorsTests.swift Tests/SpiceWireTests/AgentMessagesTests.swift
git commit -m "feat: monitors-config send path, gated on the guest's capability"
```

---

### Task 3: Per-display canvases and displayID-tagged session events

**Files:**
- Modify: `Sources/SpiceKit/SpiceSession.swift`
- Modify: `Sources/SpiceKit/ViewportMapper.swift` — no; `HeadRect` lands here in Task 4. In this task define it inline in `SpiceSession.swift`? **No** — create `Sources/SpiceKit/ViewportMapper.swift` now containing only `HeadRect` (Task 4 fills in the mapper), so the type has its final home from the start.
- Modify (compile fixes): `Tests/SpiceKitTests/ReplayTests.swift`, `Tests/SpiceKitTests/ZlibGlzReplayTests.swift`, `Tests/SpiceKitTests/SpiceSessionTests.swift`, `Tests/SpiceKitTests/StreamSessionTests.swift`, `Tests/SpiceKitTests/SessionLossTests.swift`, `Sources/SpiceSee/SpiceKitBackend.swift`, `Sources/spicesee-cli/main.swift` — wherever `SessionEvent.canvas` is pattern-matched (grep first: `grep -rn "case .canvas\|\.canvas(" Sources Tests --include="*.swift" | grep -v worktrees`)
- Test: `Tests/SpiceKitTests/ViewportMapperTests.swift` (created here with the `HeadRect` conversion test; grows in Task 4)

**Interfaces:**
- Produces:
  - `SessionEvent.canvas(CanvasEvent, displayID: UInt8)` — replaces `case canvas(CanvasEvent)`.
  - `SessionEvent.monitorsConfig([HeadRect], displayID: UInt8)` — new.
  - `public struct HeadRect: Sendable, Equatable { public var id: UInt32; public var x, y, width, height: Int; public init(id:x:y:width:height:) }` in `ViewportMapper.swift`, plus `HeadRect.heads(from: MonitorsConfig) -> [HeadRect]` (filters heads whose `surfaceID != 0` — only primary-surface heads are viewports — and drops zero-area heads).
  - `SpiceSession` internally: one `Canvas` per display channel; `snapshotPrimary()` reads the lowest-id display's canvas (unchanged behaviour for every single-display consumer, replay tests included).

Today all display channels feed one shared `Canvas` (`SpiceSession.swift:85`, `:168`), so two channels' surface IDs would collide and every frame is emitted without saying which display drew it. This task makes canvases per-channel and tags every canvas event.

- [ ] **Step 1: Write the failing conversion test** — `Tests/SpiceKitTests/ViewportMapperTests.swift`:

```swift
import Testing
import SpiceWire
@testable import SpiceKit

@Suite struct ViewportMapperTests {
    @Test func headsComeFromPrimarySurfaceEntriesOnly() throws {
        var w = SpiceWriter()
        w.u16(3); w.u16(4)                                    // count, maxAllowed
        // head 0: primary, 1920x1080 at 0,0
        [0, 0, 1920, 1080, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 1: on surface 5 — not a viewport
        [1, 5, 800, 600, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        // head 2: primary, zero area — dropped
        [2, 0, 0, 0, 0, 0, 0].forEach { w.u32(UInt32($0)) }
        var r = SpiceReader(w.bytes)
        let cfg = try MonitorsConfig(reader: &r)
        let heads = HeadRect.heads(from: cfg)
        #expect(heads == [HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080)])
    }
}
```

Note: `MonitorsConfig.init(reader:)` is internal to SpiceWire — if the direct construction above does not compile from SpiceKit tests, build the config through `DisplayMessage(type: DisplayServerMsg.monitorsConfig.rawValue, payload: w.bytes)` and pattern-match `.monitorsConfig(let cfg)` instead; check `DisplayMessageTests.swift` for the exact type constant.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ViewportMapperTests`
Expected: FAIL — no `HeadRect`.

- [ ] **Step 3: Create `Sources/SpiceKit/ViewportMapper.swift`**:

```swift
import SpiceWire

/// One guest monitor's rectangle carved out of a display channel's primary surface, in surface
/// pixels. With no DISPLAY_MONITORS_CONFIG a display has one implicit head covering its primary.
public struct HeadRect: Sendable, Equatable {
    public var id: UInt32
    public var x, y, width, height: Int
    public init(id: UInt32, x: Int, y: Int, width: Int, height: Int) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Viewport-worthy heads from a DISPLAY_MONITORS_CONFIG: only heads on the primary surface
    /// (surface 0) are windows; zero-area heads are disabled.
    public static func heads(from cfg: MonitorsConfig) -> [HeadRect] {
        cfg.heads.filter { $0.surfaceID == 0 && $0.width > 0 && $0.height > 0 }
            .map { HeadRect(id: $0.id, x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height)) }
    }
}
```

- [ ] **Step 4: Restructure `SpiceSession`.**
  - `SessionEvent`: change `case canvas(CanvasEvent)` to `case canvas(CanvasEvent, displayID: UInt8)`; add `case monitorsConfig([HeadRect], displayID: UInt8)`.
  - Remove `private let canvas = Canvas()`; add `private var canvases: [(id: UInt8, canvas: Canvas)] = []`.
  - Delete the single `canvasPump` created at the top of `start(...)`. In the `.display` case, create a canvas per channel and mirror the player's finish-then-await drain shape exactly:

```swift
                case .display:
                    let d = try await DisplayChannel.open(transport: try await transports(desc), connectionID: info.connectionID, id: desc.id, password: password)
                    displays.append(d)
                    let canvas = Canvas()
                    canvases.append((desc.id, canvas))
                    let canvasPump = Task { [cont] in
                        for await e in canvas.events { cont.yield(.canvas(e, displayID: desc.id)) }
                    }
                    tasks.append(canvasPump)
                    // ... player + playerPump exactly as today ...
                    let pump = Task { [weak self] in
                        for await m in d.messages {
                            switch m {
                            case let .streamCreate(c): await player.handle(create: c)
                            case let .streamData(data): await player.handle(data: data)
                            case let .streamClip(id, clip): await player.handle(clipChange: id, clip: clip)
                            case let .streamDestroy(id): await player.handle(destroy: id)
                            case .streamDestroyAll: await player.handleDestroyAll()
                            case let .streamActivateReport(a): await player.handle(activateReport: a)
                            case let .monitorsConfig(cfg):
                                cont.yield(.monitorsConfig(HeadRect.heads(from: cfg), displayID: desc.id))
                            default: await canvas.apply(m)
                            }
                        }
                        await player.finish()
                        _ = await playerPump.value
                        // The canvas drains the same way: no more messages can reach it, so finish
                        // it and await its pump before declaring the channel over — .disconnected
                        // must still come after every pixel.
                        await canvas.finish()
                        _ = await canvasPump.value
                        await self?.channelEnded(desc)
                    }
```

  - The `.monitorsConfig` yield must stay **in message order** relative to that channel's canvas applies, so capture `cont` alongside `weak self` in the pump and write it as `cont.yield(.monitorsConfig(HeadRect.heads(from: cfg), displayID: desc.id))` — no `emit` helper, no actor hop.
  - The final drain task: remove `await canvas.finish(); _ = await canvasPump.value` from the main-ended task (each display pump now owns its canvas's drain); keep the `displayPumps`/`cursorPumps` awaits.
  - `snapshotPrimary()`: `guard let entry = canvases.min(by: { $0.id < $1.id }) else { return nil }` then use `entry.canvas` as before.

- [ ] **Step 5: Fix every `SessionEvent.canvas` consumer.** Grep as listed under Files. In `SpiceKitBackend.connect`, patterns become `case let .canvas(.surfaceCreated(d), displayID:_) where d.isPrimary:` etc. (real routing lands in Task 5 — this step is compile-only, keep semantics identical by ignoring the id). In replay/session tests, add `, displayID: _` to the patterns. In `spicesee-cli` nothing matches `.canvas` (it uses `snapshotPrimary`), but its `clipboardProbe` switch has a `default:` so it compiles.

- [ ] **Step 6: Run the whole engine suite**

Run: `swift test`
Expected: PASS — in particular `ReplayTests` and `ZlibGlzReplayTests` stay green with byte-identical goldens: single display, same canvas, same events, only the tag added.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/SpiceKit Sources/SpiceSee/SpiceKitBackend.swift Tests
git commit -m "feat: per-display canvases; canvas and monitors-config events carry their display id"
```

---

### Task 4: `ViewportMapper` — layouts, slicing, pixel extraction, tiling

**Files:**
- Modify: `Sources/SpiceKit/ViewportMapper.swift`
- Test: `Tests/SpiceKitTests/ViewportMapperTests.swift`

**Interfaces:**
- Consumes: `HeadRect` (Task 3), `AgentMonitorConfig` (Task 1).
- Produces (all in SpiceKit):

```swift
public struct ViewportLayout: Sendable, Equatable {
    public var displayID: UInt8
    public var headIndex: Int
    public var rect: HeadRect          // into that display's primary surface
    /// Stable window identity across layout changes: displayID << 8 | headIndex.
    public var viewportID: Int { Int(displayID) << 8 | headIndex }
}

public struct ViewportMapper: Sendable, Equatable {
    public init()
    public mutating func primaryCreated(displayID: UInt8, width: Int, height: Int)
    public mutating func primaryDestroyed(displayID: UInt8)
    public mutating func headsChanged(displayID: UInt8, heads: [HeadRect])
    public var layouts: [ViewportLayout]                       // sorted displayID, then headIndex
    public struct Slice: Sendable, Equatable {
        public var viewportID: Int
        public var headWidth: Int, headHeight: Int             // the viewport's own size
        public var destX: Int, destY: Int                      // where the piece lands, head-local
        public var srcX: Int, srcY: Int                        // offset into the incoming dirty buffer
        public var width: Int, height: Int
    }
    public func slices(displayID: UInt8, dirtyX: Int, dirtyY: Int, width: Int, height: Int) -> [Slice]
    /// (displayID, head origin in surface pixels) for input translation; nil for an unknown id.
    public func origin(of viewportID: Int) -> (displayID: UInt8, x: Int, y: Int)?
    /// Sub-rect of a tightly-packed BGRA buffer (rowPixels * 4 bytes per row), itself tightly packed.
    public static func extract(_ pixels: [UInt8], rowPixels: Int, x: Int, y: Int, width: Int, height: Int) -> [UInt8]
}

public enum MonitorTiling {
    /// Lays enabled monitors left-to-right at y=0 (remote-viewer's default arrangement); disabled
    /// entries stay in place as all-zero heads for the sparse config.
    public static func compose(_ requests: [(width: Int, height: Int, enabled: Bool)]) -> [AgentMonitorConfig]
}
```

Semantics to implement:
- A display with a primary but no (surviving) heads has **one implicit head**: index 0, full surface.
- Heads are clamped to the surface bounds; a head left with zero area after clamping is dropped. Head order is config order; `headIndex` is the position in the surviving list.
- `headsChanged` before `primaryCreated` is stored and surfaces in `layouts` once the primary exists. `primaryDestroyed` removes the display's layouts but keeps its stored heads (the guest recreates the primary moments later at a new size).
- `slices` intersects the dirty rect with each head of that display and translates: `destX = interLeft − head.x`, `srcX = interLeft − dirtyX` (same for y). Non-intersecting heads produce nothing.

- [ ] **Step 1: Write the failing tests** — append to `ViewportMapperTests.swift`:

```swift
    @Test func aPrimaryWithNoHeadsIsOneFullViewport() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 1280, height: 800)
        #expect(m.layouts == [ViewportLayout(displayID: 0, headIndex: 0,
                                             rect: HeadRect(id: 0, x: 0, y: 0, width: 1280, height: 800))])
        #expect(m.layouts[0].viewportID == 0)
    }

    @Test func headsCarveThePrimaryAndClampToIt() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 3000, height: 1080)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080),
            HeadRect(id: 1, x: 1920, y: 0, width: 2000, height: 1080),   // overhangs; clamps to 1080 wide
            HeadRect(id: 2, x: 3000, y: 0, width: 100, height: 100),     // fully outside; dropped
        ])
        #expect(m.layouts.map(\.rect) == [
            HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080),
            HeadRect(id: 1, x: 1920, y: 0, width: 1080, height: 1080),
        ])
        #expect(m.layouts.map(\.viewportID) == [0, 1])
    }

    @Test func headsSurviveAPrimaryRebuildAtANewSize() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 1920, height: 1080)
        m.headsChanged(displayID: 0, heads: [HeadRect(id: 0, x: 0, y: 0, width: 1920, height: 1080)])
        m.primaryDestroyed(displayID: 0)
        #expect(m.layouts.isEmpty)
        m.primaryCreated(displayID: 0, width: 1024, height: 768)
        #expect(m.layouts.map(\.rect) == [HeadRect(id: 0, x: 0, y: 0, width: 1024, height: 768)])
    }

    @Test func secondDisplayChannelIsItsOwnViewport() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 1920, height: 1080)
        m.primaryCreated(displayID: 1, width: 2560, height: 1440)
        #expect(m.layouts.count == 2)
        #expect(m.layouts[1].viewportID == 1 << 8)
    }

    @Test func dirtyRectsSlicePerHead() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 200, height: 100)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 100, height: 100),
            HeadRect(id: 1, x: 100, y: 0, width: 100, height: 100),
        ])
        // A 40-wide strip straddling the seam at x=80..120, y=10..30.
        let s = m.slices(displayID: 0, dirtyX: 80, dirtyY: 10, width: 40, height: 20)
        #expect(s == [
            ViewportMapper.Slice(viewportID: 0, headWidth: 100, headHeight: 100,
                                 destX: 80, destY: 10, srcX: 0, srcY: 0, width: 20, height: 20),
            ViewportMapper.Slice(viewportID: 1, headWidth: 100, headHeight: 100,
                                 destX: 0, destY: 10, srcX: 20, srcY: 0, width: 20, height: 20),
        ])
    }

    @Test func aWholeHeadSliceCoversTheDirtyRectExactly() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 100, height: 100)
        let s = m.slices(displayID: 0, dirtyX: 10, dirtyY: 20, width: 30, height: 40)
        #expect(s == [ViewportMapper.Slice(viewportID: 0, headWidth: 100, headHeight: 100,
                                           destX: 10, destY: 20, srcX: 0, srcY: 0, width: 30, height: 40)])
    }

    @Test func extractPullsATightlyPackedSubRect() {
        // 4x3 buffer whose pixel (x,y) has blue byte = y*16 + x; take the middle 2x2 at (1,1).
        var px = [UInt8](repeating: 0, count: 4 * 3 * 4)
        for y in 0 ..< 3 { for x in 0 ..< 4 { px[(y * 4 + x) * 4] = UInt8(y * 16 + x) } }
        let sub = ViewportMapper.extract(px, rowPixels: 4, x: 1, y: 1, width: 2, height: 2)
        #expect(sub.count == 2 * 2 * 4)
        #expect([sub[0], sub[4], sub[8], sub[12]] == [0x11, 0x12, 0x21, 0x22])
    }

    @Test func originTranslatesViewportToSurface() {
        var m = ViewportMapper()
        m.primaryCreated(displayID: 0, width: 200, height: 100)
        m.headsChanged(displayID: 0, heads: [
            HeadRect(id: 0, x: 0, y: 0, width: 100, height: 100),
            HeadRect(id: 1, x: 100, y: 0, width: 100, height: 100),
        ])
        #expect(m.origin(of: 1)! == (displayID: 0, x: 100, y: 0))
        #expect(m.origin(of: 99) == nil)
    }

    @Test func tilingLaysEnabledMonitorsLeftToRight() {
        let monitors = MonitorTiling.compose([
            (width: 1920, height: 1080, enabled: true),
            (width: 1280, height: 800, enabled: false),
            (width: 2560, height: 1440, enabled: true),
        ])
        #expect(monitors == [
            AgentMonitorConfig(width: 1920, height: 1080, depth: 32, x: 0, y: 0),
            AgentMonitorConfig(width: 0, height: 0, depth: 0, x: 0, y: 0),
            AgentMonitorConfig(width: 2560, height: 1440, depth: 32, x: 1920, y: 0),
        ])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ViewportMapperTests`
Expected: FAIL — `ViewportMapper` / `MonitorTiling` undefined.

- [ ] **Step 3: Implement** in `ViewportMapper.swift`:

```swift
public struct ViewportLayout: Sendable, Equatable {
    public var displayID: UInt8
    public var headIndex: Int
    public var rect: HeadRect
    public var viewportID: Int { Int(displayID) << 8 | headIndex }
    public init(displayID: UInt8, headIndex: Int, rect: HeadRect) {
        self.displayID = displayID; self.headIndex = headIndex; self.rect = rect
    }
}

/// Normalises both server shapes — N display channels, or one channel carved by
/// DISPLAY_MONITORS_CONFIG — into one list of viewports, and slices dirty rects per head.
/// A value type on purpose: snapshots of it can cross into the input FIFO without shared state.
public struct ViewportMapper: Sendable, Equatable {
    private struct DisplayState: Sendable, Equatable {
        var width: Int?, height: Int?      // nil until the primary exists
        var heads: [HeadRect] = []
    }
    private var displays: [UInt8: DisplayState] = [:]

    public init() {}

    public mutating func primaryCreated(displayID: UInt8, width: Int, height: Int) {
        displays[displayID, default: DisplayState()].width = width
        displays[displayID]!.height = height
    }

    public mutating func primaryDestroyed(displayID: UInt8) {
        displays[displayID]?.width = nil
        displays[displayID]?.height = nil
    }

    public mutating func headsChanged(displayID: UInt8, heads: [HeadRect]) {
        displays[displayID, default: DisplayState()].heads = heads
    }

    /// Heads clamped to the surface; zero-area survivors dropped; the full surface when none apply.
    private func effectiveHeads(_ s: DisplayState) -> [HeadRect] {
        guard let w = s.width, let h = s.height else { return [] }
        let clamped = s.heads.compactMap { head -> HeadRect? in
            let left = max(0, head.x), top = max(0, head.y)
            let right = min(w, head.x + head.width), bottom = min(h, head.y + head.height)
            guard right > left, bottom > top else { return nil }
            return HeadRect(id: head.id, x: left, y: top, width: right - left, height: bottom - top)
        }
        return clamped.isEmpty ? [HeadRect(id: 0, x: 0, y: 0, width: w, height: h)] : clamped
    }

    public var layouts: [ViewportLayout] {
        displays.sorted { $0.key < $1.key }.flatMap { id, state in
            effectiveHeads(state).enumerated().map { i, rect in
                ViewportLayout(displayID: id, headIndex: i, rect: rect)
            }
        }
    }

    public struct Slice: Sendable, Equatable {
        public var viewportID: Int
        public var headWidth: Int, headHeight: Int
        public var destX: Int, destY: Int
        public var srcX: Int, srcY: Int
        public var width: Int, height: Int
        public init(viewportID: Int, headWidth: Int, headHeight: Int, destX: Int, destY: Int,
                    srcX: Int, srcY: Int, width: Int, height: Int) {
            self.viewportID = viewportID; self.headWidth = headWidth; self.headHeight = headHeight
            self.destX = destX; self.destY = destY; self.srcX = srcX; self.srcY = srcY
            self.width = width; self.height = height
        }
    }

    public func slices(displayID: UInt8, dirtyX: Int, dirtyY: Int, width: Int, height: Int) -> [Slice] {
        guard let state = displays[displayID] else { return [] }
        return effectiveHeads(state).enumerated().compactMap { i, head in
            let left = max(dirtyX, head.x), top = max(dirtyY, head.y)
            let right = min(dirtyX + width, head.x + head.width)
            let bottom = min(dirtyY + height, head.y + head.height)
            guard right > left, bottom > top else { return nil }
            return Slice(viewportID: Int(displayID) << 8 | i,
                         headWidth: head.width, headHeight: head.height,
                         destX: left - head.x, destY: top - head.y,
                         srcX: left - dirtyX, srcY: top - dirtyY,
                         width: right - left, height: bottom - top)
        }
    }

    public func origin(of viewportID: Int) -> (displayID: UInt8, x: Int, y: Int)? {
        guard let layout = layouts.first(where: { $0.viewportID == viewportID }) else { return nil }
        return (layout.displayID, layout.rect.x, layout.rect.y)
    }

    public static func extract(_ pixels: [UInt8], rowPixels: Int, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(width * height * 4)
        for row in y ..< y + height {
            let start = (row * rowPixels + x) * 4
            out.append(contentsOf: pixels[start ..< start + width * 4])
        }
        return out
    }
}

public enum MonitorTiling {
    public static func compose(_ requests: [(width: Int, height: Int, enabled: Bool)]) -> [AgentMonitorConfig] {
        var x: Int32 = 0
        return requests.map { r in
            guard r.enabled else { return AgentMonitorConfig(width: 0, height: 0, depth: 0, x: 0, y: 0) }
            defer { x += Int32(r.width) }
            return AgentMonitorConfig(width: UInt32(r.width), height: UInt32(r.height), depth: 32, x: x, y: 0)
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ViewportMapperTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceKit/ViewportMapper.swift Tests/SpiceKitTests/ViewportMapperTests.swift
git commit -m "feat: ViewportMapper — head carving, dirty-rect slicing, monitor tiling"
```

---

### Task 5: Adapter routing — `viewportsChanged`, per-head frames, input translation

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift` (one new event case)
- Modify: `Sources/SpiceSee/SpiceKitBackend.swift`
- Modify: `Sources/SpiceSee/SessionModel.swift`
- Modify: `Sources/SpiceSee/MockSessionBackend.swift` (compiles unchanged — no new protocol members in this task)
- Test: Create `Tests/SpiceSeeTests/ViewportSeamTests.swift`; run `xcodegen generate`

**Interfaces:**
- Consumes: `ViewportMapper`, `ViewportLayout`, `Slice`, `extract` (Task 4); `SessionEvent.canvas(_, displayID:)`, `.monitorsConfig(_, displayID:)` (Task 3).
- Produces: `BackendEvent.viewportsChanged([ViewportInfo])` — the live layout after `.connected` has announced; `SessionModel` applies it by replacing `viewports` (windows follow via the existing `SessionWindowOpener.onChange`). `ViewportInfo.id` is now `ViewportLayout.viewportID`.

- [ ] **Step 1: Write the failing SessionModel test** — `Tests/SpiceSeeTests/ViewportSeamTests.swift` (follow the fake-backend style of `DisplayGraceTests.swift`; read it first and reuse its backend if one is shared):

```swift
import Testing
@testable import SpiceSee

@MainActor
@Suite struct ViewportSeamTests {
    /// Yields a scripted event list, then idles so the session stays up.
    private final class ScriptedBackend: SessionBackend {
        let script: [BackendEvent]
        init(script: [BackendEvent]) { self.script = script }
        func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
            AsyncStream { c in
                for e in script { c.yield(e) }
            }
        }
        func disconnect() async {}
        func sendCtrlAltDel() async {}
        func sendInput(_ event: InputEvent) {}
        func offerClipboardText() async {}
        func sendClipboardText(_ text: String) async {}
        func requestClipboardText() async {}
    }

    @Test func viewportsChangedReplacesTheListWithoutTouchingThePhase() async throws {
        let one = [ViewportInfo(id: 0, index: 0, total: 1, width: 1920, height: 1080)]
        let two = [ViewportInfo(id: 0, index: 0, total: 2, width: 1920, height: 1080),
                   ViewportInfo(id: 1, index: 1, total: 2, width: 1280, height: 800)]
        let model = SessionModel(backend: ScriptedBackend(script: [
            .connected(viewports: one), .viewportsChanged(two),
        ]))
        model.connect(SavedConnection(name: "t", host: "h"), password: nil)
        // The scripted stream is synchronous; give the pump a beat to drain.
        for _ in 0 ..< 100 where model.viewports.count != 2 { await Task.yield() }
        #expect(model.phase == .connected)
        #expect(model.viewports == two)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run to verify it fails**

Run: `xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: FAIL — `BackendEvent` has no case `viewportsChanged`.

- [ ] **Step 3: Add the event and its handling.**
  - `SessionBackend.swift`, in `BackendEvent` after `case connected`: `/// The guest's monitor layout changed mid-session (new heads, or a primary at a new size). \n case viewportsChanged([ViewportInfo])`.
  - `SessionModel.apply`, after the `.connected` case:

```swift
        case let .viewportsChanged(viewports):
            self.viewports = viewports
```

- [ ] **Step 4: Rework `SpiceKitBackend.connect`'s event loop around the mapper.** Replace the `displays`/`viewportID` prelude and the canvas cases:

```swift
                var mapper = ViewportMapper()
                var announced = false

                func viewportInfos() -> [ViewportInfo] {
                    let layouts = mapper.layouts
                    return layouts.enumerated().map { i, l in
                        ViewportInfo(id: l.viewportID, index: i, total: layouts.count,
                                     width: l.rect.width, height: l.rect.height)
                    }
                }
                func publishLayout() {
                    inputCont.yield(.layout(mapper))
                    let infos = viewportInfos()
                    guard !infos.isEmpty else { return }
                    if announced { continuation.yield(.viewportsChanged(infos)) }
                    else { continuation.yield(.connected(viewports: infos)); announced = true }
                }
```

Event cases (replacing the current `.canvas` handling; `.connected` from the session stays a no-op):

```swift
                    case let .canvas(.surfaceCreated(d), displayID: id) where d.isPrimary:
                        mapper.primaryCreated(displayID: id, width: d.width, height: d.height)
                        publishLayout()
                    case let .canvas(.surfaceDestroyed(sid), displayID: id):
                        // Only the primary is a viewport; the mapper only tracks primaries, and a
                        // destroyed primary must NOT re-announce an empty list — the guest is about
                        // to recreate it at a new size (the resize path), so hold the windows.
                        if sid == 0 { mapper.primaryDestroyed(displayID: id) }
                    case let .monitorsConfig(heads, displayID: id):
                        mapper.headsChanged(displayID: id, heads: heads)
                        publishLayout()
                    case let .canvas(.updated(u), displayID: id) where u.isPrimary:
                        for s in mapper.slices(displayID: id, dirtyX: Int(u.rect.left), dirtyY: Int(u.rect.top),
                                               width: Int(u.rect.width), height: Int(u.rect.height)) {
                            let whole = s.width == Int(u.rect.width) && s.height == Int(u.rect.height)
                            continuation.yield(.frame(FrameUpdate(
                                viewportID: s.viewportID,
                                surfaceWidth: s.headWidth, surfaceHeight: s.headHeight,
                                x: s.destX, y: s.destY, width: s.width, height: s.height,
                                pixels: whole ? u.pixels : ViewportMapper.extract(
                                    u.pixels, rowPixels: Int(u.rect.width),
                                    x: s.srcX, y: s.srcY, width: s.width, height: s.height))))
                        }
                    case .canvas(.updated, displayID: _), .canvas(.surfaceCreated, displayID: _):
                        break   // off-screen surfaces are scratch buffers, not viewport content
                    case let .canvas(.unsupported(what), displayID: _):
                        log.notice("canvas: \(what, privacy: .public)")
```

Cursor and stream events translate per head of their display (shape (a) single-head displays reduce to today's behaviour):

```swift
                    case let .cursor(change, displayID):
                        for l in mapper.layouts where l.displayID == displayID {
                            switch change {
                            case .shape:
                                continuation.yield(.cursor(viewportID: l.viewportID, Self.translate(change)))
                            case let .moved(x, y):
                                continuation.yield(.cursor(viewportID: l.viewportID,
                                                           .moved(x: x - l.rect.x, y: y - l.rect.y)))
                            }
                        }
                    case let .streamFrame(f, displayID: id):
                        for l in mapper.layouts where l.displayID == id {
                            var u = Self.translate(f, viewportID: l.viewportID)
                            u.dest.x -= l.rect.x; u.dest.y -= l.rect.y
                            u.clip = u.clip.map { $0.map { r in
                                var r = r; r.x -= l.rect.x; r.y -= l.rect.y; return r } }
                            continuation.yield(.streamFrame(u))
                        }
                    case let .streamDestroyed(id: sid, displayID: id):
                        for l in mapper.layouts where l.displayID == id {
                            continuation.yield(.streamDestroyed(viewportID: l.viewportID, streamID: sid))
                        }
                    case let .allStreamsDestroyed(displayID: id):
                        for l in mapper.layouts where l.displayID == id {
                            continuation.yield(.streamDestroyed(viewportID: l.viewportID, streamID: nil))
                        }
```

  - **Input translation.** Add to `Queued`: `case layout(ViewportMapper)`. The `init()` consumer keeps a local `var mapper = ViewportMapper()`; `case let .layout(m): mapper = m`. `Self.translate(e)` gains the mapper for the one case that needs it — change the signature to `translate(_ e: InputEvent, mapper: ViewportMapper) -> [GuestInput]` and the pointer case to:

```swift
        case let .pointerPosition(x, y, id):
            guard let o = mapper.origin(of: id) else { return [] }
            return [.pointerPosition(x: UInt32(max(0, x + o.x)), y: UInt32(max(0, y + o.y)),
                                     displayID: o.displayID)]
```

The FIFO carrying layout snapshots is the loophole-free way to share the mapper with the input consumer under strict concurrency — no locks, and ordering with `.begin`/`.end` is preserved. On a fresh consumer before any `.layout`, `origin(of:)` returns nil and the event is dropped, matching the existing "input before the session is up is dropped" rule.
  - Remove the now-unused `let displays = ...` / `viewportID` prelude lines; keep the `.step`/`.agent` yields.

- [ ] **Step 5: Build and test everything**

Run: `swift test && xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS, including the new `ViewportSeamTests`.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/SpiceSee Tests/SpiceSeeTests
git commit -m "feat: route frames, cursors, streams and input through the viewport head model"
```

---

### Task 6: `requestDisplayLayout` through the seam

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift`
- Modify: `Sources/SpiceSee/SpiceKitBackend.swift`
- Modify: `Sources/SpiceSee/MockSessionBackend.swift` (empty conformance for now; Task 9 animates it)
- Test: extend `Tests/SpiceSeeTests/ViewportSeamTests.swift` is not possible for the wire half (app tests have no SPICE server) — the composition is already covered by `MonitorTiling` tests; this task's test is the protocol shape compiling everywhere plus one `MonitorTiling` mapping assertion at the adapter's input ordering.

**Interfaces:**
- Produces:

```swift
/// One head's requested state, in guest pixels. The seam's own type — no SPICE type crosses.
struct DisplayLayout: Sendable, Equatable {
    var viewportID: Int
    var width: Int
    var height: Int
    var enabled: Bool
}
// on SessionBackend:
/// Asks the guest to adopt this layout, one entry per known viewport, closed windows disabled.
/// Silently ignored without an agent that does monitors-config.
func requestDisplayLayout(_ layouts: [DisplayLayout]) async
```

- [ ] **Step 1: Add the type and protocol member** to `SessionBackend.swift` (type near `ViewportEvent`, member after `requestClipboardText`).

- [ ] **Step 2: Implement in `SpiceKitBackend`:**

```swift
    func requestDisplayLayout(_ layouts: [DisplayLayout]) async {
        let ordered = layouts.sorted { $0.viewportID < $1.viewportID }
        await live.session?.sendMonitorsConfig(MonitorTiling.compose(
            ordered.map { (width: $0.width, height: $0.height, enabled: $0.enabled) }))
    }
```

- [ ] **Step 3: Stub in `MockSessionBackend`:** `func requestDisplayLayout(_ layouts: [DisplayLayout]) async {}` — and in the `ScriptedBackend` inside `ViewportSeamTests` and any other test double conforming to `SessionBackend`.

- [ ] **Step 4: Build both worlds**

Run: `swift build && xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpiceSee Tests/SpiceSeeTests
git commit -m "feat: requestDisplayLayout crosses the seam to VD_AGENT_MONITORS_CONFIG"
```

---

### Task 7: Resize-follows-window — debounce, HiDPI, window hooks

**Files:**
- Modify: `Sources/SpiceSee/SessionModel.swift`
- Modify: `Sources/SpiceSee/SessionWindowView.swift`
- Test: Create `Tests/SpiceSeeTests/ResizeRequestTests.swift`; run `xcodegen generate`

**Interfaces:**
- Consumes: `SessionBackend.requestDisplayLayout` (Task 6), `session.hiDPI` (exists), `session.agent` (exists).
- Produces on `SessionModel`:

```swift
var resizeDebounce: Duration = .milliseconds(250)     // tests shrink it
func viewportSizeChanged(_ viewportID: Int, points: CGSize, backingScale: CGFloat)
func viewportWindowClosed(_ viewportID: Int)
```

Behaviour:
- Requested pixel size = `points × (hiDPI ? backingScale : 1)`, rounded.
- **Loop guards:** the first report for a viewport is recorded but never sent (a window opening is not the user asking for a resolution); a report equal to the viewport's current guest size is recorded but not sent (the guest already granted it, or the window was programmatically fit).
- Debounce: each qualifying report cancels and restarts a `resizeDebounce` sleep; on expiry, if `phase == .connected` and `agent == .connected`, compose one `DisplayLayout` per entry in `viewports`: open windows (a viewport with at least one subscriber in `viewportSubscribers`) enabled at their last-reported pixel size (guest size if never reported), closed windows disabled. **If no window is open, send nothing** — a session left running from the Window menu must not blank the whole guest.
- Toggling `session.hiDPI` mid-session recomputes every viewport's request from its stored `(points, backingScale)` and schedules a send — this is what makes the existing toolbar toggle effective.

- [ ] **Step 1: Write the failing tests** — `Tests/SpiceSeeTests/ResizeRequestTests.swift`:

```swift
import Testing
@testable import SpiceSee

@MainActor
@Suite struct ResizeRequestTests {
    private final class SpyBackend: SessionBackend, @unchecked Sendable {}
    // ^ NO. @unchecked Sendable is banned. Use the actor-spy shape below.

    private actor LayoutSpy {
        private(set) var calls: [[DisplayLayout]] = []
        func record(_ l: [DisplayLayout]) { calls.append(l) }
    }

    private final class Backend: SessionBackend {
        let spy = LayoutSpy()
        func connect(_ target: ConnectionTarget) -> AsyncStream<BackendEvent> {
            AsyncStream { c in
                c.yield(.connected(viewports: [ViewportInfo(id: 0, index: 0, total: 1, width: 1920, height: 1080)]))
                c.yield(.agent(.connected))
            }
        }
        func requestDisplayLayout(_ layouts: [DisplayLayout]) async { await spy.record(layouts) }
        func disconnect() async {}
        func sendCtrlAltDel() async {}
        func sendInput(_ event: InputEvent) {}
        func offerClipboardText() async {}
        func sendClipboardText(_ text: String) async {}
        func requestClipboardText() async {}
    }

    private func connectedModel(_ backend: Backend) async -> SessionModel {
        let model = SessionModel(backend: backend)
        model.resizeDebounce = .milliseconds(1)
        model.connect(SavedConnection(name: "t", host: "h"), password: nil)
        for _ in 0 ..< 200 where model.agent != .connected { await Task.yield() }
        _ = model.viewportEvents(for: 0)      // an open window, as MetalSurfaceView would register
        return model
    }

    private func drained(_ spy: LayoutSpy, count: Int) async -> [[DisplayLayout]] {
        for _ in 0 ..< 500 {
            if await spy.calls.count >= count { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await spy.calls
    }

    @Test func firstReportIsRecordedNotSent() async {
        let backend = Backend()
        let model = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 1440, height: 900), backingScale: 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.spy.calls.isEmpty)
    }

    @Test func aResizeAfterTheFirstReportIsSentDebounced() async {
        let backend = Backend()
        let model = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 1440, height: 900), backingScale: 2)
        model.viewportSizeChanged(0, points: CGSize(width: 1500, height: 920), backingScale: 2)
        model.viewportSizeChanged(0, points: CGSize(width: 1512, height: 945), backingScale: 2)
        let calls = await drained(backend.spy, count: 1)
        #expect(calls == [[DisplayLayout(viewportID: 0, width: 1512, height: 945, enabled: true)]])
    }

    @Test func hiDPIScalesThePixelsAndRetriggers() async {
        let backend = Backend()
        let model = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 1440, height: 900), backingScale: 2)
        model.viewportSizeChanged(0, points: CGSize(width: 1500, height: 920), backingScale: 2)
        _ = await drained(backend.spy, count: 1)
        model.hiDPI = true
        let calls = await drained(backend.spy, count: 2)
        #expect(calls.last == [DisplayLayout(viewportID: 0, width: 3000, height: 1840, enabled: true)])
    }

    @Test func aReportMatchingTheGuestSizeIsNotEchoed() async {
        let backend = Backend()
        let model = await connectedModel(backend)
        model.viewportSizeChanged(0, points: CGSize(width: 800, height: 600), backingScale: 2)
        // The guest is already 1920x1080; a fitted window reporting exactly that must not resend.
        model.viewportSizeChanged(0, points: CGSize(width: 1920, height: 1080), backingScale: 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await backend.spy.calls.isEmpty)
    }
}
```

(Remove the dead `SpyBackend` stub lines before committing — they are in the listing only to warn the implementer off `@unchecked Sendable`.)

- [ ] **Step 2: `xcodegen generate`; run to verify they fail**

Run: `xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: FAIL — `SessionModel` lacks the members.

- [ ] **Step 3: Implement in `SessionModel`.** New state near `graceTask`:

```swift
    /// Resize-follows-window. Sizes are requested, not imposed: the guest answers with a new
    /// primary, which flows back as `.viewportsChanged`. The first report per viewport and any
    /// report matching the guest's current size are recorded but not sent — those are windows
    /// opening or fitting, not the user asking for a resolution.
    var resizeDebounce: Duration = .milliseconds(250)
    private var resizeTask: Task<Void, Never>?
    private var windowMetrics: [Int: (points: CGSize, backingScale: CGFloat)] = [:]
```

`hiDPI` gains a `didSet { scheduleResizeRequest() }`. The methods:

```swift
    func viewportSizeChanged(_ viewportID: Int, points: CGSize, backingScale: CGFloat) {
        let first = windowMetrics[viewportID] == nil
        windowMetrics[viewportID] = (points, backingScale)
        guard !first else { return }
        let (w, h) = requestedPixels(points: points, backingScale: backingScale)
        if let current = viewports.first(where: { $0.id == viewportID }),
           current.width == w, current.height == h { return }
        scheduleResizeRequest()
    }

    func viewportWindowClosed(_ viewportID: Int) {
        windowMetrics[viewportID] = nil
        guard phase == .connected else { return }
        scheduleResizeRequest()
    }

    private func requestedPixels(points: CGSize, backingScale: CGFloat) -> (Int, Int) {
        let s = hiDPI ? backingScale : 1
        return (Int((points.width * s).rounded()), Int((points.height * s).rounded()))
    }

    private func scheduleResizeRequest() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            guard let debounce = self?.resizeDebounce else { return }
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled, self.phase == .connected, self.agent == .connected else { return }
            let open = Set(self.viewportSubscribers.values.map(\.viewportID))
            guard !open.isEmpty else { return }   // never disable every head from the Window menu
            let layouts = self.viewports.map { v -> DisplayLayout in
                guard open.contains(v.id) else {
                    return DisplayLayout(viewportID: v.id, width: 0, height: 0, enabled: false)
                }
                let (w, h) = self.windowMetrics[v.id].map { self.requestedPixels(points: $0.points, backingScale: $0.backingScale) }
                    ?? (v.width, v.height)
                return DisplayLayout(viewportID: v.id, width: w, height: h, enabled: true)
            }
            let backend = self.backend
            Task { await backend.requestDisplayLayout(layouts) }
        }
    }
```

Also clear the state on teardown: in `apply`'s `.disconnected` and `.failed` cases and in `disconnect()`/`cancel()`, add `resizeTask?.cancel(); windowMetrics.removeAll()`.

- [ ] **Step 4: Wire the window.** In `SessionWindowView`, the `GeometryReader` already provides `proxy`; add state + two modifiers on the outer content (alongside `.onAppear`):

```swift
    @State private var window: NSWindow?
    // inside body, on the GeometryReader content:
                .background(WindowAccessor { window = $0 })
                .onChange(of: proxy.size) { _, size in
                    session.viewportSizeChanged(viewport.id, points: size,
                                                backingScale: window?.backingScaleFactor ?? 2)
                }
                .onDisappear { session.viewportWindowClosed(viewport.id) }
```

`WindowReader` in this file is `private` to its section but in the same file — reuse it (rename usage accordingly; it is called `WindowReader`). Report the **content** size (`proxy.size` is the Metal area below the toolbar), which is exactly what the guest should fill. `onDisappear` also fires on disconnect teardown — `viewportWindowClosed` guards on `phase == .connected`, and by the time windows are dismissed the phase is already `.idle`, so no disable is sent.

- [ ] **Step 5: Run the app test suite**

Run: `xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpiceSee/SessionModel.swift Sources/SpiceSee/SessionWindowView.swift Tests/SpiceSeeTests/ResizeRequestTests.swift
git commit -m "feat: resize-follows-window with debounce, loop guards, and a working HiDPI toggle"
```

---

### Task 8: Clipboard images through the seam and the bridge

**Files:**
- Modify: `Sources/SpiceSee/SessionBackend.swift`
- Modify: `Sources/SpiceSee/SpiceKitBackend.swift`
- Modify: `Sources/SpiceSee/ClipboardBridge.swift`
- Modify: `Sources/SpiceSee/MockSessionBackend.swift` + every test double conforming to `SessionBackend`
- Test: `Tests/SpiceSeeTests/ClipboardBridgeTests.swift`

**Interfaces:**
- Produces (seam, replacing the text-only clipboard surface):

```swift
enum ClipboardKind: Sendable, Equatable { case text, png }

enum ClipboardEvent: Sendable, Equatable {
    case available(Bool)
    case guestOffers([ClipboardKind])          // replaces guestOffersText
    case guestRequests(ClipboardKind)          // replaces guestRequestsText
    case guestText(String)
    case guestImagePNG([UInt8])                // new
    case guestReleased
}
// SessionBackend methods (offerClipboardText/requestClipboardText replaced):
func offerClipboard(_ kinds: [ClipboardKind]) async
func requestClipboard(_ kind: ClipboardKind) async
func sendClipboardText(_ text: String) async   // unchanged
func sendClipboardPNG(_ bytes: [UInt8]) async  // new
```

Both directions stay **eager on offer** like the shipped text path (`ClipboardBridge.process` requests on `guestOffersText` today) — a synchronous `NSPasteboardItemDataProvider` cannot await the agent. PNG is the only image type announced or honoured. When the guest offers both text and image, text wins (the far more common paste); an image-only offer requests the image.

- [ ] **Step 1: Read the existing tests first**: `Tests/SpiceSeeTests/ClipboardBridgeTests.swift` — the new tests must reuse its spy-backend and unique-pasteboard idioms, and the old tests must be updated to the new event/method names, not deleted.

- [ ] **Step 2: Write the failing tests** (adapt naming to the file's existing style; unique pasteboard per test via `NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))`):

```swift
    @Test func hostImageIsOfferedAsPNG() async {
        // Arrange a pasteboard holding TIFF (what ⌘C on an image usually produces).
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pb.clearContents()
        pb.writeObjects([image])
        let backend = SpyBackend()                    // the file's existing spy, extended
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        await drainUntil { await backend.offers.contains([.png]) }
        #expect(await backend.offers.last == [.png])
    }

    @Test func aGuestPNGRequestIsAnsweredWithEncodedPNG() async {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pb.clearContents(); pb.writeObjects([image])
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.handle(.guestRequests(.png))
        await drainUntil { await backend.sentPNGs.count == 1 }
        let png = await backend.sentPNGs.first ?? []
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])     // PNG magic
    }

    @Test func guestImageLandsOnThePasteboardWithoutBouncingBack() async {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend, pasteboard: pb)
        bridge.handle(.available(true))
        bridge.start()
        let png: [UInt8] = pngFixture()          // tiny valid PNG; encode one via NSBitmapImageRep in the test
        bridge.handle(.guestOffers([.png]))
        await drainUntil { await backend.requests.contains(.png) }
        bridge.handle(.guestImagePNG(png))
        await drainUntil { pb.data(forType: .png) != nil }
        #expect(pb.data(forType: .png).map(Array.init) == png)
        // The write bumped changeCount; the poll must not offer our own write back.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await backend.offers.count(where: { $0.contains(.png) }) == 0)
    }

    @Test func guestOfferingTextAndImageGetsAskedForText() async {
        let backend = SpyBackend()
        let bridge = ClipboardBridge(backend: backend,
                                     pasteboard: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)))
        bridge.handle(.available(true))
        bridge.handle(.guestOffers([.text, .png]))
        await drainUntil { !(await backend.requests.isEmpty) }
        #expect(await backend.requests == [.text])
    }
```

`drainUntil`/`pngFixture` are small local helpers (poll with `Task.yield`/short sleeps up to a timeout; build the PNG fixture with `NSBitmapImageRep.representation(using: .png, ...)`). The spy backend records `offers: [[ClipboardKind]]`, `requests: [ClipboardKind]`, `sentPNGs: [[UInt8]]`, `sentTexts: [String]` in an actor, mirroring how the file's existing spy records text calls.

- [ ] **Step 3: Run to verify they fail**

Run: `xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: FAIL — `ClipboardKind` undefined.

- [ ] **Step 4: Implement.**
  - `SessionBackend.swift`: swap in the enum and method set above (delete `guestOffersText`, `guestRequestsText`, `offerClipboardText`, `requestClipboardText`; keep the doc comment style, and update the `ClipboardEvent` header comment — it promised this widening).
  - `SpiceKitBackend`:

```swift
    func offerClipboard(_ kinds: [ClipboardKind]) async {
        await live.session?.offerClipboard(kinds.map(Self.wireType))
    }
    func requestClipboard(_ kind: ClipboardKind) async {
        await live.session?.requestClipboard(Self.wireType(kind))
    }
    func sendClipboardPNG(_ bytes: [UInt8]) async {
        await live.session?.sendClipboard(.imagePNG, bytes)
    }
    private static func wireType(_ k: ClipboardKind) -> ClipboardType { k == .text ? .utf8Text : .imagePNG }
    private static func kind(_ t: ClipboardType) -> ClipboardKind? {
        switch t { case .utf8Text: .text; case .imagePNG: .png; default: nil }
    }

    /// Types the seam does not speak (BMP, TIFF, file lists) are dropped here: announcing an offer
    /// the app cannot answer would strand the guest waiting.
    private static func translate(_ e: SpiceKit.ClipboardEvent) -> ClipboardEvent? {
        switch e {
        case let .available(on): .available(on)
        case let .guestOffers(types):
            { let kinds = types.compactMap(kind); return kinds.isEmpty ? nil : .guestOffers(kinds) }()
        case let .guestRequests(type): kind(type).map(ClipboardEvent.guestRequests)
        case let .guestData(type, bytes):
            switch type {
            case .utf8Text: .guestText(String(decoding: bytes, as: UTF8.self))
            case .imagePNG: .guestImagePNG(bytes)
            default: nil
            }
        case .guestReleased: .guestReleased
        }
    }
```

  - `ClipboardBridge.process` — the changed cases:

```swift
        case let .available(on):
            available = on
            if on, enabled {
                let kinds = hostKinds()
                if !kinds.isEmpty { await backend.offerClipboard(kinds) }
            }
        case let .guestOffers(kinds):
            guard enabled else { return }
            // Text wins when both are offered — the overwhelmingly common paste. Eager fetch on
            // purpose: NSPasteboard's data provider is synchronous and cannot await the agent,
            // which is the same reason the text path has always fetched on offer.
            if kinds.contains(.text) { await backend.requestClipboard(.text) }
            else if kinds.contains(.png) { await backend.requestClipboard(.png) }
        case let .guestText(text):
            guard enabled else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ownChangeCount = pasteboard.changeCount
            lastSeenChangeCount = pasteboard.changeCount
        case let .guestImagePNG(bytes):
            guard enabled else { return }
            pasteboard.clearContents()
            pasteboard.setData(Data(bytes), forType: .png)
            ownChangeCount = pasteboard.changeCount
            lastSeenChangeCount = pasteboard.changeCount
        case let .guestRequests(kind):
            guard enabled else { return }
            switch kind {
            case .text:
                guard let text = pasteboard.string(forType: .string) else { return }
                await backend.sendClipboardText(text)
            case .png:
                guard let png = hostPNG() else { return }
                await backend.sendClipboardPNG(png)
            }
```

With the helpers (and `checkHostClipboard` switching to `hostKinds()`):

```swift
    private func hostKinds() -> [ClipboardKind] {
        var kinds: [ClipboardKind] = []
        if pasteboard.string(forType: .string) != nil { kinds.append(.text) }
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil { kinds.append(.png) }
        return kinds
    }

    /// PNG is encoded at request time, not at grab time — the grab is only an announcement.
    private func hostPNG() -> [UInt8]? {
        if let png = pasteboard.data(forType: .png) { return Array(png) }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return Array(png)
    }
```

  - `MockSessionBackend` and every test double: replace the two removed methods with the new no-op set.
  - Update the pre-existing text tests in `ClipboardBridgeTests` to the renamed events/methods — behaviour assertions unchanged.

- [ ] **Step 5: Run both suites**

Run: `swift test && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/SpiceSee Tests/SpiceSeeTests
git commit -m "feat: PNG clipboard images both ways through a kind-aware seam"
```

---

### Task 9: CLI probes — `resize`, image clipboard

**Files:**
- Modify: `Sources/spicesee-cli/main.swift`

**Interfaces:**
- Consumes: `SpiceSession.sendMonitorsConfig` (Task 2), `SessionEvent.monitorsConfig`/`.canvas(_, displayID:)` (Task 3), `MonitorTiling` not needed here (a single explicit head).
- Produces: `spicesee-cli resize <host> <port> <width> <height> [password] [--seconds n]` and `clipboard … [--send-image file.png] [--save-image out.png]`.

- [ ] **Step 1: Add the resize probe** (below `clipboardProbe`):

```swift
/// Asks a live guest to change resolution and reports what comes back. Proves the whole wire path
/// — capability gate, packed message, guest reaction — without dragging a window.
func resizeProbe(_ config: ConnectionConfig, width: UInt32, height: UInt32, seconds: Double) async throws {
    let session = try await SpiceSession.connect(config)
    print("connected; requesting \(width)x\(height), watching for \(seconds)s")
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await session.disconnect()
    }
    defer { deadline.cancel() }

    for await event in session.events {
        switch event {
        case let .agent(connected):
            print("agent \(connected ? "connected" : "gone")")
        case .clipboard(.available):
            // Capability negotiation is complete once clipboard availability is decided —
            // the same ANNOUNCE_CAPABILITIES answers for monitors config.
            await session.sendMonitorsConfig([AgentMonitorConfig(width: width, height: height)])
            print("sent VD_AGENT_MONITORS_CONFIG \(width)x\(height) (dropped silently if the guest lacks the cap)")
        case let .monitorsConfig(heads, displayID: id):
            print("display \(id) heads: \(heads.map { "\($0.width)x\($0.height)@\($0.x),\($0.y)" }.joined(separator: " "))")
        case let .canvas(.surfaceCreated(d), displayID: id) where d.isPrimary:
            print("display \(id) primary now \(d.width)x\(d.height)")
        case .disconnected:
            print("disconnected")
            return
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Extend the clipboard probe.** `clipboardProbe` gains `sendImage: [UInt8]?` and `saveImageTo: URL?` parameters. Changes inside its event loop:
  - `.available(true)`: also `if sendImage != nil { await session.offerClipboard([.imagePNG]) }` (offer both when `--send` text is also given: `offerClipboard([.utf8Text, .imagePNG])` built from what was passed).
  - `.guestOffers(types)`: if `types.contains(.imagePNG), saveImageTo != nil { await session.requestClipboard(.imagePNG) }` (keep the text request as-is otherwise).
  - `.guestRequests(.imagePNG)`: answer with `await session.sendClipboard(.imagePNG, sendImage ?? [])` and print the byte count.
  - `.guestData(.imagePNG, bytes)`: write to `saveImageTo` (`try Data(bytes).write(to: url)`), print `"wrote \(bytes.count) bytes to \(url.path)"`.

- [ ] **Step 3: Wire the argument parsing.** Add to `usage()`:

```
           spicesee-cli resize <host> <port> <width> <height> [password] [--seconds <n>]
```

and extend the `clipboard` usage line with `[--send-image <png>] [--save-image <out.png>]`. New `case "resize":` mirroring the `clipboard` case's shape (`takeFlags` with `["--seconds"]`, four positionals). In `case "clipboard":` add `"--send-image", "--save-image"` to the flag set, load the send-image file bytes up front (`try Data(contentsOf:)`), and pass both through.

- [ ] **Step 4: Build and smoke-test locally**

Run: `swift build && swift run spicesee-cli resize 2>&1 | head -3`
Expected: builds; the bare invocation prints usage. (A live run against the dev guest is the exit check, not this step: `swift run spicesee-cli resize 192.168.50.6 5930 1600 900`.)

- [ ] **Step 5: Commit**

```bash
git add Sources/spicesee-cli/main.swift
git commit -m "feat: cli resize probe and clipboard image flags"
```

---

### Task 10: Mock backend — second display renders, resize responds

**Files:**
- Modify: `Sources/SpiceSee/MockSessionBackend.swift`

**Interfaces:**
- Consumes: `DisplayLayout`, `BackendEvent.viewportsChanged` (Tasks 5–6).
- Produces: `--mock` review surface for multi-window and resize-follows-window. Mock viewport ids stay `0` and `1`.

- [ ] **Step 1: Give the second viewport pixels.** Parameterise the synthetic desktop: `desktop(width:height:viewportID:band:)` where viewport 1 gets a visibly different band colour (e.g. `(32, 42, 60)` — a blue band against viewport 0's warm one) so a swapped window is obvious in review. In `connect`, after the existing viewport-0 frame: `continuation.yield(.frame(Self.desktop(width: 2560, height: 1440, viewportID: 1, band: (60, 42, 32))))` — adjust the helper's signature so `FrameUpdate.viewportID` is the parameter, and keep the caret loop on viewport 0 only.

- [ ] **Step 2: Answer `requestDisplayLayout`.** Add to the class:

```swift
    /// One live consumer per app run — the mock assumes a single active session, which is what
    /// `--mock` review is. Layout requests are answered ~200 ms later the way a guest would:
    /// a new viewport list, then a full repaint at the granted size.
    private let resizeStream: AsyncStream<[DisplayLayout]>
    private let resizeCont: AsyncStream<[DisplayLayout]>.Continuation
    // in init():  (resizeStream, resizeCont) = AsyncStream.makeStream(of: [DisplayLayout].self)
    func requestDisplayLayout(_ layouts: [DisplayLayout]) async { resizeCont.yield(layouts) }
```

Inside `connect`'s task, after the initial `.connected` block, start a child task (cancel it in `onTermination` alongside the main one, or run it inside the same task group as the caret loop via `async let` — simplest is a second `Task` captured and cancelled in `onTermination`):

```swift
                    let resizer = Task {
                        for await layouts in resizeStream {
                            try? await Task.sleep(for: .milliseconds(200))
                            let enabled = layouts.filter(\.enabled)
                            guard !enabled.isEmpty else { continue }
                            continuation.yield(.viewportsChanged(enabled.enumerated().map { i, l in
                                ViewportInfo(id: l.viewportID, index: i, total: enabled.count,
                                             width: l.width, height: l.height)
                            }))
                            for l in enabled {
                                continuation.yield(.frame(Self.desktop(width: l.width, height: l.height,
                                                                       viewportID: l.viewportID,
                                                                       band: l.viewportID == 0 ? (60, 42, 32) : (32, 42, 60))))
                            }
                        }
                    }
```

The caret loop must then draw against the *current* viewport-0 size — hold `var size` as `var` and update it from the resizer's granted layouts (move the resizer's loop inline before the caret loop is not possible since both await; instead have the resizer store nothing and accept the caret blinking at a stale offset — it is a review mock, and the full repaint already proved the resize. Add a one-line comment saying so).

- [ ] **Step 3: Verify by eye (the design-review gate for this milestone's UI).**

```bash
xcodegen generate
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build
BUILT_PRODUCTS_DIR=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings | grep BUILT_PRODUCTS_DIR | awk '{print $3}')
SPICESEE_MOCK=1 "$BUILT_PRODUCTS_DIR/SpiceSee.app/Contents/MacOS/SpiceSee" --scenario desktop --autoconnect
```

Expected: **two** viewport windows (with `openWindowPerMonitor` on), differently-banded desktops, correct per-window subtitles ("Display 1 of 2 · 1920 × 1080"). Dragging a window's edge repaints its desktop at the new size ~450 ms after the drag ends (250 ms debounce + 200 ms mock latency). Capture each window via `screencapture -l<id>` for the record; **never a full-screen shot**. Window drags cannot be synthesized on this machine — if running non-interactively, build + launch + capture the static two-window state, and list the drag check as the user's.
Quit: `osascript -e 'tell application "SpiceSee" to quit'`.

- [ ] **Step 4: Commit**

```bash
git add Sources/SpiceSee/MockSessionBackend.swift
git commit -m "feat: mock backend renders the second display and answers resize requests"
```

---

### Task 11: Exit checks and docs

**Files:**
- Modify: `docs/dev-server.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Live resize check (driveable from this machine).**

```bash
scripts/dev-server.sh                       # is the guest up?
swift run spicesee-cli resize 192.168.50.6 5930 1600 900
```

Expected: `agent connected`, the sent line, then `display 0 primary now 1600x900` (Windows guests may instead answer with a `monitorsConfig` heads line first). If the dev box is offline, record that in the exit-check doc instead of skipping silently. Then restore: `swift run spicesee-cli resize 192.168.50.6 5930 1920 1080`.

- [ ] **Step 2: Live image-clipboard check (wire half).**

```bash
swift Tools/make-icons.swift >/dev/null 2>&1 || true   # any small PNG will do; or use an existing fixture
swift run spicesee-cli clipboard 192.168.50.6 5930 --send-image Tests/SpiceKitTests/Fixtures/win-display.golden.png --save-image /tmp/guest-copy.png --seconds 30
```

The guest-side halves (someone pasting/copying in Windows) are manual; the probe printing `guest is pasting, wants imagePNG` / writing `/tmp/guest-copy.png` is the machine-side evidence.

- [ ] **Step 3: Write `docs/dev-server.md` → new section after the M4 exit check:**

```markdown
## M5 exit check (manual)

Machine-driveable halves first — run them before handing the rest over:

- [ ] `spicesee-cli resize <host> <port> 1600 900` reports the guest's primary at 1600x900
      (then restore 1920x1080). Proves cap gating, the packed message, and the guest applying it.
- [ ] `spicesee-cli clipboard --send-image <png> --save-image /tmp/g.png` moves an image each way
      (needs a person at the guest console to copy/paste, as with the text checks above).

In the app, needing a person on both ends:

- [ ] Drag a viewport window: ~250 ms after the drag ends the guest desktop matches the new size.
      With the 2× toolbar toggle on, the guest resolution doubles the window's point size and 1:1
      shows one guest pixel per device pixel.
- [ ] Copy an image in the guest, ⌘V on the Mac; copy an image on the Mac (⌘⇧4 to clipboard works),
      paste in the guest (⌃V — ⌘V is Win+V, see the M5 clipboard notes above). Clipboard toggle off
      stops both.
- [ ] The outstanding text-clipboard boxes in "M5 clipboard exit check" above.

**Multi-head is mock-proven, not server-proven** — the same honesty rule as M4's tier-2/3 gate.
Neither dev guest exposes a second head (Windows/WDDM single-QXL; the Proxmox guest runs
modesetting), so the viewport model's evidence is `ViewportMapperTests` + the two-window `--mock`
review. A future guest with `qxl.heads=2` (or two qxl devices) upgrades this to a live check:
open both windows, close one, and the guest should drop to one active monitor.
```

- [ ] **Step 4: Update `CLAUDE.md`'s architecture paragraph** — surgical edits only: M5 shipped (viewport head model in `SpiceKit.ViewportMapper`, resize-follows-window over `VD_AGENT_MONITORS_CONFIG` with the encoder pinned by `agentref.c`, working HiDPI toggle, PNG clipboard images; pointer and audio-volume still deliberately unannounced; file transfer still absent, M6 audio next). Move "clipboard images" out of the does-not-exist list. Add two gotcha lines to the input/M4-style rules: *viewport ids are `displayID << 8 | headIndex` and windows key on them, so layout changes must keep ids stable for surviving heads*; *the input FIFO carries `ViewportMapper` snapshots (`Queued.layout`) — never read layout state back from outside the FIFO, for the same stamped-not-queried reason as `AgentEvent`*. Note the eager clipboard fetch rationale (sync `NSPasteboardItemDataProvider`) beside the existing clipboard notes.

- [ ] **Step 5: Full suites one last time**

Run: `swift test && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests -destination 'platform=macOS' test 2>&1 | tail -5 && scripts/check-vendored-notices.sh`
Expected: all PASS; the notices script exits 0 (nothing under `vendor/` was touched, this is the cheap regression guard).

- [ ] **Step 6: Commit**

```bash
git add docs/dev-server.md CLAUDE.md
git commit -m "docs: M5 exit checks; architecture notes for the viewport model and clipboard images"
```

---

## Self-Review Notes (already applied)

- Spec §1 → Tasks 3–5; §2 → Tasks 1–2, 6–7; §3 → Task 8; §4 → Tasks 9–11. The spec's `SavedConnection` HiDPI field and lazy image fetch are amended in this plan's header (existing field; sync provider), and the executor should not "restore" either.
- `ViewportInfo.id` changes meaning (was raw channel id, now `displayID << 8 | headIndex`) — for single-display sessions both are `0`, so window restoration and the grace-period placeholder (`id: 0`) are unaffected.
- The grace-period placeholder viewport (`SessionModel.startGracePeriod`) yields `.connected` with id 0; when the real primary later arrives the backend has `announced == false` and yields `.connected` again — same as today's behaviour, unchanged by this plan.
