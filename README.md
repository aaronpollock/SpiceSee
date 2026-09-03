# SpiceSee

A native macOS SPICE client — a remote console for Proxmox VE virtual machines and plain
QEMU/libvirt guests.

SPICE clients on the Mac have meant `remote-viewer` under XQuartz, or a browser tab. SpiceSee is a
Cocoa app: SwiftUI chrome, a Metal viewport, Swift 6 strict concurrency, and a protocol stack
written from scratch rather than wrapped around spice-gtk.

## Features

- **Displays** — the full tier-1–3 draw set, QUIC / LZ / GLZ / JPEG / zlib image codecs, multiple
  monitors as separate windows, HiDPI, fit-to-window or 1:1 pixel scaling.
- **Video streams** — MJPEG and H.264 decoded through VideoToolbox and composited over the
  framebuffer, paced against the guest's multimedia clock.
- **Audio** — the playback channel, Opus decoded through AudioToolbox, with guest and local volume.
- **Input** — positional keyboard mapping with raw scancodes, both mouse modes, and pointer capture
  when the guest has no agent. ⌘ and ⌥ map to guest modifiers per connection.
- **Guest agent** — clipboard sharing in both directions for text and images, and
  resize-follows-window.
- **Proxmox** — open a `.vv` console file and it connects, including through pveproxy's HTTP CONNECT
  proxy, over TLS pinned to the certificate authority the file carries.
- **Security** — passwords in the Keychain, one-shot tickets never written to disk, and every field
  read off the wire bounds-checked.

Not implemented: file transfer, microphone (the record channel), USB redirection, and smartcards.

## Requirements

macOS 14 Sonoma or later, Apple silicon.

## Installing

Download the notarized DMG from <https://somecoolthings.com/spicesee> and drag SpiceSee to
Applications. The app updates itself through Sparkle.

## Connecting

**Proxmox VE** — in the web UI, choose *Console → SPICE*; the browser downloads a `.vv` file. Open
it. SpiceSee reads the host, one-shot ticket, proxy and certificate authority out of the file and
connects. Nothing to configure.

**Anything else** — add a connection with the host and port. `libvirt` and bare `qemu` guests
listen on 5900 and up; use the TLS port field if the server has one. A password is asked for when
the server wants a ticket, and stored in the Keychain if you let it.

For clipboard and automatic resize the guest needs the SPICE agent — `spice-vdagent` on Linux, the
guest tools on Windows. It is not the same thing as `qemu-guest-agent`.

## Building from source

Two build systems, and **`swift build` does not compile the app**:

```bash
swift build                 # engine libraries and CLI tools only
swift test

xcodegen generate           # re-run after adding or removing files under Sources/SpiceSee
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug \
           -destination 'platform=macOS' build
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSeeTests \
           -destination 'platform=macOS' test
```

`SpiceSee.xcodeproj` is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is gitignored — edit the YAML, never the
project. `scripts/release.sh` produces the signed, notarized DMG and the Sparkle appcast; it needs a
Developer ID certificate and a notarization profile.

There is no server to test against in CI. `MockSessionBackend` drives every screen without one:

```bash
SPICESEE_MOCK=1 /path/to/SpiceSee.app/Contents/MacOS/SpiceSee --scenario desktop --autoconnect
```

`--scenario desktop | noAgent | refused | badPassword | certMismatch | migrate` covers connect
progress, the failure and migration sheets, agent states, and a synthetic framebuffer.

## Command-line tools

Built by `swift build`, useful for probing a server or capturing fixtures:

```bash
swift run spicesee-cli connect <host> <port>                 # handshake, then print the channel list
swift run spicesee-cli dump <host> <port> <secs> out.png     # capture the guest to a PNG
swift run spicesee-cli audio <host> <port> <secs> out.wav    # record the playback channel
swift run spicerec <listen-port> <host> <port> <out-dir>     # recording proxy, one file per channel
```

`spicerec` sits between a reference client and the server and keeps the bytes. Those recordings are
the test fixtures: `ReplayTests` renders one headless and compares it pixel-for-pixel against a
committed golden image, so a regression anywhere in the stack fails there first.

## Architecture

The dependency rule is strictly downward. `SpiceCanvas` knows nothing about sockets; `SpiceCore`
knows nothing about pixels. Everything below `SpiceKit` runs headless from recorded bytes, which is
what makes the replay tests possible.

| Target | Role |
| --- | --- |
| `CSpiceCodec` | vendored QUIC / LZ / GLZ decoders, built as a replaceable dynamic framework |
| `SpiceWire` | wire types, bounds-checked reader and writer — the security boundary |
| `SpiceCore` | transport, TLS, link handshake, channel actors |
| `SpiceCanvas` | surfaces, draw commands, image cache, codec routing |
| `SpiceMedia` | video and audio decode, multimedia-clock pacing |
| `SpiceKit` | facade: `SpiceSession`, all the app sees |
| `SpiceSee` | the SwiftUI and AppKit app |

Every `SpiceWire` accessor throws. A hostile or malformed server message must produce a caught
error, never a trap — there are no force-unwraps or unchecked subscripts on data read off a socket.

The app talks to a `SessionBackend` protocol rather than to SPICE, so the mock and the real engine
are interchangeable and every screen stays reviewable without a server.

## Licensing

SpiceSee is MIT licensed — see [`LICENSE`](LICENSE). The exception is the image codecs, which are
vendored from
[spice-common](https://gitlab.freedesktop.org/spice/spice-common) and
[spice-gtk](https://gitlab.freedesktop.org/spice/spice-gtk) — `quic.c`, `lz.c` and the GLZ decoder,
LGPL-2.1-or-later. There is no way around them: the server defaults to `auto_glz` and the client
cannot opt out.

Those files build as `CSpiceCodec.framework`, embedded in the bundle and signed with library
validation disabled, so anyone can rebuild the codecs and substitute their own copy. That is the
LGPL §6(b) offer, and `docs/replacing-the-codec.md` explains how. It also rules out the Mac App
Store, which is why SpiceSee ships as a Developer ID–signed DMG.

`Packages/CSpiceCodec/Sources/CSpiceCodec/VENDORED.md` records every vendored file with its
upstream revision and licence; `scripts/check-vendored-notices.sh` enforces that the record is
complete. The acknowledgements window in the app carries the same notice, alongside spice-protocol's
BSD-3-Clause terms and Sparkle's MIT licence.
