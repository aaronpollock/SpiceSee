# SpiceSee

A native macOS SPICE client — remote console for Proxmox VE and plain QEMU/libvirt guests.

SwiftUI chrome, AppKit/Metal viewports, Swift 6 strict concurrency, macOS 14+, universal binary.

## Status

The UI is complete and the engine is not started. Every screen — connection manager, connect
progress, failure and migration sheets, session viewport with its responsive toolbar, preferences,
acknowledgements — is built against `MockSessionBackend`. The four library targets are placeholders.

`docs/superpowers/plans/2026-08-22-spicesee-m0-m1-pixels.md` is the task-by-task engine plan;
`docs/superpowers/specs/2026-08-22-spicesee-design.md` is the design spec it argues from.

## Building

Two build systems, and `swift build` does **not** compile the app.

```bash
swift build                 # engine libraries only: SpiceWire, SpiceCore, SpiceCanvas, SpiceKit
swift test

xcodegen generate           # re-run after adding or removing files under Sources/SpiceSee
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug \
           -destination 'platform=macOS' build
```

`SpiceSee.xcodeproj` is generated from `project.yml` and gitignored — edit the YAML, never the
project.

## Running without a SPICE server

All mock flags are gated behind `--mock`:

```bash
open -n /path/to/SpiceSee.app --args --mock --scenario desktop --autoconnect
```

`--scenario desktop | noAgent | refused | badPassword | certMismatch | migrate` drives connect
progress, the failure and migration sheets, agent states, and a synthetic framebuffer.
`--autoconnect` connects the selected host on launch.

## Architecture

The dependency rule is strictly downward. `SpiceCanvas` knows nothing about sockets; `SpiceCore`
knows nothing about pixels. Everything below `SpiceKit` runs headless from recorded bytes, which is
what makes replay golden tests possible.

| Target | Role |
| --- | --- |
| `SpiceWire` | wire types, bounds-checked reader/writer — the security boundary |
| `SpiceCore` | transport, TLS, link handshake, channel actors |
| `SpiceCanvas` | surfaces, draw commands, image cache, codec routing |
| `SpiceKit` | facade: `SpiceSession`, the only type the app sees |
| `SpiceSee` | the SwiftUI + AppKit app |

Every `SpiceWire` accessor throws. A hostile or malformed server message must produce a caught
error, never a trap.

The app talks to the `SessionBackend` protocol rather than `SpiceKit` directly, so the mock and the
real engine are interchangeable. `docs/design/design-text.txt` is the authoritative UI spec, carrying
every dimension in points.

## Distribution

The SPICE image codecs (`quic.c`, `lz.c`, the GLZ decoder) are LGPL-2.1+ and unavoidable — the
server defaults to `auto_glz` with no client opt-out. They build as a dynamic framework embedded in
the bundle with library validation disabled, so a user can substitute their own build per LGPL
§6(b). That rules out the Mac App Store: distribution is Developer ID, a notarized DMG, and a
Homebrew cask. The acknowledgements window carries the written offer.

---

© 2026 SCT
