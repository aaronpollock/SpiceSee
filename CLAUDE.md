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

# regenerate app + document icons into Assets.xcassets (idempotent)
swift Tools/make-icons.swift
```

Swift 6 language mode with strict concurrency, macOS 14 deployment target, universal (arm64 + x86_64). No locks, no `@unchecked Sendable`.

## Running against a real SPICE server

The dev server is a quickemu Windows guest on the LAN, not a local process — endpoint, ticket state
and the bug it flushed out are in `docs/dev-server.md`. `scripts/dev-server.sh` reports reachability.

```bash
swift run spicesee-cli connect 192.168.50.6 5930            # prints MAIN_INIT and the channel list
swift run spicesee-cli dump 192.168.50.6 5930 5 /tmp/f.png  # captures the guest for 5s, writes a PNG
swift run spicerec 5901 192.168.50.6 5930 recordings/x      # recording TCP proxy, one file per channel
```

`spicerec` is how fixtures are made: proxy a *reference* client (`remote-viewer` under `xvfb-run`,
since the guest host is headless) and keep the per-channel captures. `Tests/SpiceKitTests/Fixtures/`
holds the display and main recordings plus `win-display.golden.png`; `ReplayTests` renders the
recording headless and compares pixel-for-pixel, so a regression anywhere in the stack fails there
first. **Only commit a golden you have actually looked at.**

`scripts/check-vendored-notices.sh` must exit 0 before any release — it enforces the LGPL record in
`Sources/CSpiceCodec/VENDORED.md`. Re-run it after touching anything under `vendor/`.

## Running the app without a SPICE server

`MockSessionBackend` still drives every screen for design review. All flags are gated behind `--mock`:

```bash
open -n /path/to/SpiceSee.app --args --mock --scenario desktop --autoconnect
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
SpiceKit     facade: SpiceSession, the only type the app sees
SpiceSee     SwiftUI + AppKit app
```

**M0–M1 are done: a real guest renders in the app.** `docs/superpowers/plans/2026-08-22-spicesee-m0-m1-pixels.md` (tasks 1–16b, all ticked) built the stack; `docs/superpowers/specs/2026-08-22-spicesee-design.md` is the design spec it argues from. What exists now: the link handshake with ticket auth, main and display channels, the vendored QUIC/LZ/GLZ codecs, tier-1 draws, and `SpiceSession`. What does not: **input (M2)** — no mouse, no keyboard, no Ctrl-Alt-Del; TLS and `.vv` (M3); streams/video, tiers 2–3 (M4); agent and clipboard (M5); audio (M6). Later plans are written one at a time, after the previous milestone ships.

Because input is M2, the session window shows the guest but cannot drive it. The captured-pointer HUD appears whenever the agent is absent (`SessionModel` sets `pointerCaptured` on `.agent(.absent)`) even though nothing is actually captured yet — M2 makes that honest by implementing capture.

**`SessionBackend` is the seam.** The UI talks to a protocol (`Sources/SpiceSee/SessionBackend.swift`), never to SPICE. `SpiceKitBackend` is the real implementation and `MockSessionBackend` still backs `--mock` for design review, so every screen stays reviewable without a server. Landing the real engine required **no view changes** — keep it that way: **if a view needs editing to accommodate the engine, the seam is wrong — fix the adapter, not the view.** Error classification lives in `SpiceKit.ConnectFailureKind` (tested); the failure wording stays in the app, and the raw `SpiceError` goes to the log, never to the sheet.

**`SpiceWire` is the security boundary.** Every reader accessor throws; a hostile or malformed server message must produce a caught error, never a trap. No `!` unwraps or unchecked subscripts on wire data.

## UI conventions

`docs/design/design-text.txt` (a plain-text extraction of `docs/design/SpiceSee UI.dc.html`) is the authoritative UI spec — it carries every dimension in points, SF Symbol name, and semantic color. When the text is ambiguous, grep the `.dc.html` for the label and read the surrounding inline styles.

- `Sources/SpiceSee/Theme.swift` owns all dimensions (`Metric.*`) and the single tint token `Color.chiliRed`. Add constants there rather than scattering literals; everything not accent is a macOS semantic color.
- Chili red is the *accent* only. Status uses system colors — green connected / amber no-agent / neutral negotiating, green completed step. Do not tint status affordances red.
- **Do not draw custom backgrounds behind toolbar controls.** macOS draws its own item chrome, which is taller than the design's 22pt control, and the two cannot be kept in register — this caused repeated misalignment and overhanging hover highlights. Toolbar state is carried by color alone.
- `Sources/SpiceSee/SessionPresentation.swift` is the glue deciding which window presents what (failure sheet, migration sheet, opening viewport windows). Screens themselves are self-contained views.
- Licences in `Sources/SpiceSee/Licenses/` are a resources build phase and land **flat** in `Contents/Resources/`, not in a `Licenses/` subdirectory — look them up accordingly.

## Verifying UI work on this machine

`osascript`/System Events has no assistive access and synthetic `CGEvent` mouse events are ignored, so **you cannot hover, click, or open menus**. Static layout is still verifiable:

- Get a window id from `CGWindowListCopyWindowInfo`, then `screencapture -l<id> out.png`. **Never take a full-screen screenshot** — it captures the user's unrelated private screen content.
- To compare against the design, strip the `<x-dc>`/`<helmet>` wrapper off the `.dc.html`, serve it over `http://127.0.0.1`, and open it in Chrome (the browser tools refuse `file://`).
- Measuring pixel rows/columns of a captured window beats eyeballing — it is how the "window is too tall" bug was traced to SwiftUI sizing the window to the screen's visible height rather than to content.
- Hover states and anything full-screen must be handed to the user to verify; say so rather than claiming it works.

## Licensing constraint (affects distribution)

The SPICE image codecs (`quic.c`, `lz.c`, GLZ decoder) are LGPL-2.1+ and unavoidable — the server defaults to `auto_glz` with no client opt-out. Plan task 13 vendors them into `CSpiceCodec`, which **must** build as a dynamic framework embedded in the bundle, with `com.apple.security.cs.disable-library-validation` so a user can substitute their own build (LGPL §6(b)). This rules out the Mac App Store; distribution is Developer ID + notarized DMG + Homebrew cask. The acknowledgements window carries the written offer and must keep doing so.

## Conventions

Conventional-commit prefixes (`feat:`, `fix:`, `build:`, `docs:`, `chore:`). Library code logs via `os.Logger(subsystem: "com.spicesee", category:)` — no `print` outside executables. Tests use Swift Testing (`import Testing`), with fixtures under `Tests/<Target>Tests/Fixtures/`.
