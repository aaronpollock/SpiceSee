# Claude Design prompt — SpiceSee UI

Paste into Claude Design as-is.

---

Design the macOS UI for **SpiceSee**, a native SPICE remote-desktop client (think "Screen Sharing.app for Proxmox/QEMU VMs"). macOS 14+, SwiftUI chrome around AppKit/Metal viewport windows. Follow Apple HIG — this should feel like a first-party Mac utility, not a cross-platform port. Light and dark mode. Produce artboards for every screen below at 2x, plus a small component sheet.

## Product context
- Users: sysadmins and homelabbers opening VM consoles from the Proxmox web UI (double-clicking a `.vv` file) or connecting directly to a QEMU host:port.
- The viewport shows a VM's screen 1:1 or scaled to fit. Multi-monitor VMs open **one window per monitor**, each can go native fullscreen on a different Mac display.
- Guest agent (`spice-vdagent`) may or may not be present. Without it: no clipboard sync, no resize-follows-window, mouse is "server mode" (pointer captured, released with Ctrl+Option).

## Screens
1. **Connection manager** (main window at launch). Sidebar list of saved hosts (name, host:port, last connected), "+" to add, search. Detail pane: form with Host, Port, TLS port, Password (Keychain), "Connect" primary button, and a collapsible "Advanced" with HiDPI toggle, Cmd↔Super/Option↔Alt key mapping, release chord. Empty state for first launch with a hint about `.vv` files.
2. **Connecting / error states**: inline progress; failure sheet with plain-language message (refused, TLS mismatch with `host-subject` shown, bad password) and Retry.
3. **Session window** (the VM screen). Minimal unified toolbar, hidden in fullscreen, revealed on hover at the top edge. Items: Ctrl-Alt-Del, Fullscreen, Scaling (Fit / 1:1), HiDPI, Clipboard sync on/off, Mute, and an **agent status indicator** (connected / not connected — tooltip explains what's missing). Title = VM name or host.
4. **Mouse-captured overlay**: a brief, non-blocking HUD when the pointer is captured in server mode ("Press ⌃⌥ to release"), fading after 2 s; subtle persistent cue while captured.
5. **VM migrated dialog**: "This VM moved to another host — reconnect?" with new host prefilled, Reconnect / Cancel.
6. **Preferences** (⌘,): General (default scaling, HiDPI default), Keyboard (modifier mapping with a visual keycap picker, release chord), Updates (Sparkle: check automatically, check now), Acknowledgements link.
7. **Acknowledgements window**: lists LGPL components (QUIC/LZ/GLZ codecs from spice-common/spice-gtk, libopus BSD, Sparkle MIT) with license text and a note that the codec framework can be replaced by the user.
8. **App icon**: a chili pepper motif suggesting "spice" + a display/eye ("see"); must read at 16 px in the Dock and as a `.vv` document icon badge.

## Component sheet
Toolbar icons (SF Symbols where possible; custom glyphs for Ctrl-Alt-Del and agent status), agent status states (3), connection list row (normal/selected/connecting), the captured-mouse HUD, sidebar empty state illustration.

## Constraints
- Typography: system font only. Colors: system semantic colors; one accent (pick one that works with the pepper icon).
- No custom chrome around the VM framebuffer — the pixels are the content; nothing may overlay them except the transient HUD.
- Toolbar must stay usable at a 640 px wide window.
- Provide SF Symbol names and exact spacing/sizes so an engineer can build it in SwiftUI without guessing.
