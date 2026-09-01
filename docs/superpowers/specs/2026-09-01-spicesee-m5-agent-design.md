# SpiceSee M5 — Agent: viewports, resize-follows-window, clipboard images

Design for milestone M5 of `2026-08-22-spicesee-design.md` ("Clipboard both ways,
resize-follows-window, multi-monitor windows"). Text clipboard shipped early during M2/M3; this
milestone delivers the rest of the row plus the per-connection HiDPI setting the main spec folds
into the monitors work. Staging decision: **head-model first** — the viewport model is the
backbone, resize is written once against it, clipboard images run as an independent track.

**Out of scope:** file transfer and clipboard file lists, pointer/audio-volume agent messages
(they stay unannounced in `AgentSession.clientCaps`), audio (M6), jitter buffering. HiDPI applies
to resolution requests only; input coordinate mapping stays with `ViewportTransform`.

## 1. Viewport/head model (SpiceKit)

One abstraction, both server shapes normalized into it:

```
Viewport = (channelID, headIndex, rect-into-surface)

(a) N qxl devices   -> N display channels: one viewport per channel, head 0,
                       rect = that channel's whole primary surface
(b) 1 qxl, N heads  -> DISPLAY_MONITORS_CONFIG carves N head rects out of one primary
```

- `SpiceCanvas` stays head-ignorant: it renders the primary surface whole, as today. The carving
  lives in SpiceKit: each dirty rect is intersected with every head rect and re-emitted per
  intersecting head, translated to head-local coordinates, as that viewport's `FrameUpdate`.
  `ViewportInfo` sizes come from the head rects.
- Shape (a)'s work is routing: `SpiceKitBackend` currently stamps `displays.first`'s id on every
  frame, so a second channel's viewport would show monitor 0's pixels. Frames, cursor changes and
  stream frames route by the channel they arrived on.
- Layout changes at runtime — a new `MONITORS_CONFIG`, or a channel's primary recreated at a new
  size — re-publish the viewport list as a new `BackendEvent` case (`viewportsChanged`).
  `SessionWindowOpener` already reacts to `session.viewports` changing, so windows open, close and
  resize with **no view edits** — the `SessionBackend` seam holds, per the standing rule.
- Input: `InputEvent.pointerPosition` already carries `viewportID`; the adapter adds the head
  rect's origin to reach surface coordinates and stamps the channel id into `MOUSE_POSITION`'s
  `display_id`. Exact multi-head coordinate semantics are confirmed against spice-gtk during
  implementation, not guessed.

## 2. Resize-follows-window and HiDPI

**Wire.** New `AgentMessage.monitorsConfig([MonitorConfig])` encoder for
`VD_AGENT_MONITORS_CONFIG`. Both structs are `SPICE_ATTR_PACKED`: `Tools/agentref.c` grows a case
built from the real `vd_agent.h` structs and `AgentMessagesTests` pins the encoder against its
bytes — the 20-byte lesson applied up front.

**Gating.** Sent only when the guest announced `VD_AGENT_CAP_MONITORS_CONFIG`; without it the
feature is silently absent, like clipboard without an agent — no error UI. Whether we must
announce `sparseMonitorsConfig` as a client cap (spice-gtk does) is checked against spice-gtk
during implementation; the `clientCaps` comment is updated to say monitors config is now honoured.

**Flow.** Viewport window live-resize ends → ~250 ms debounce in `SessionModel` → one new seam
method `requestDisplayLayout([DisplayLayout])` covering **all** heads — `DisplayLayout` is a seam
type (viewport id, size, position, enabled), no SPICE type crossing: each open window contributes
its size and position, a closed window's head is sent disabled. The guest answers
through §1's path (new primary or new `MONITORS_CONFIG` → `viewportsChanged`) and the window
content follows.

**Loop guard.** Only a user-initiated resize triggers a send (AppKit live-resize detection); a
guest-initiated size change that resizes the window programmatically must not echo a second
request back.

**HiDPI.** Per-connection toggle in Advanced, off by default. Off: sizes in points, guest at 1×.
On: sizes × `backingScaleFactor`; `ViewportTransform` (which already takes `backingScale`)
presents at one guest pixel per device pixel. `SavedConnection` gains the field as an
**Optional** — the `nameIsCustom` decode rule — covered beside `ConnectionNamingTests`' decode
cases.

## 3. Clipboard images

**Seam.** `ClipboardEvent`'s text-only cases generalize to a seam-level
`ClipboardKind { text, png }`: `.guestOffers([ClipboardKind])`, `.guestRequests(ClipboardKind)`,
matching data cases; the three backend methods become kind-aware (`offerClipboard(_:)`,
`sendClipboard(kind:data:)`, `requestClipboard(kind:)`). No SPICE type crosses the seam.

**PNG only**, per the main spec. Windows vdagent converts DIB↔PNG itself and spice-vdagent speaks
PNG natively; BMP/TIFF/JPG stay unannounced — announcing types we don't honour is the same
mistake as announcing caps we don't.

- Host → guest: `ClipboardBridge`'s changeCount poll also detects image content; the grab offers
  `imagePNG` (with text when both are present). PNG encoding (`NSBitmapImageRep`) happens at
  request time, not grab time — grab-lazy, like text.
- Guest → host: on a guest grab offering `imagePNG`, register an `NSPasteboardItem` data provider
  for `.png`; bytes are fetched only on actual paste.
- Bounds: the `AgentReassembler` 100 MB ceiling already caps a hostile size before allocation.
  CRLF conversion remains text-only.

## 4. Testing and exit criteria

| Layer | Covers |
|---|---|
| `AgentMessagesTests` + `agentref.c` | monitors-config bytes against the real packed structs |
| `SpiceKitTests` | head-carving geometry, layout-change republish, per-channel routing; a synthetic two-head `MONITORS_CONFIG` drives shape (b) with no server |
| `SpiceSeeTests` | `ClipboardBridge` image paths (`NSPasteboard` lives here), `SavedConnection` optional-field decode |
| `ReplayTests` | existing single-head goldens stay green — the regression guard for the routing refactor |
| Mock | the two-viewport scenario is the design-review surface for multi-window chrome |

**Probes.** `spicesee-cli` gains `resize` (send a monitors config, report the new surface
dimensions coming back) and `clipboard --send-image <png>` / received-image-to-file, so both exit
checks are wire-verifiable from this machine before the in-app manual pass.

**Exit criteria:**

1. Dragging a viewport window resizes the guest desktop to match, live against an agent guest
   (Proxmox Linux and/or the Windows dev guest). `spicesee-cli resize` proves the wire path; the
   actual window drag is a manual check.
2. An image copies guest→host and host→guest through the app — folded into `docs/dev-server.md`'s
   M5 clipboard checklist, whose outstanding text boxes get ticked in the same pass.
3. Multi-head: geometry/routing tests green and the mock's two windows behave (open,
   close-disables-head, reopen via Show Displays). A real multi-head guest is explicitly **not**
   required — recorded in `docs/dev-server.md` the way M4's vacuous tier-2/3 gate was, so
   mock-proven is never mistaken for server-proven.
