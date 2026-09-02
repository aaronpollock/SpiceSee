# Dev SPICE server

The plan (task 12, step 1) assumed a SPICE server had to be stood up on this Mac, via Homebrew
QEMU or a Lima VM. That is not needed here: there is a real one on the LAN.

| | |
|---|---|
| Host | `192.168.50.6` (Ubuntu server) |
| Port | `5930` |
| Ticket | none — connect with an empty password |
| Guest | Windows — installed, with guest tools: `agent=1`, `mouse=2` (was the installer dialog at M0) |
| Hypervisor | quickemu |

Homebrew's QEMU is built without `--enable-spice`, so there is no local fallback; if the Ubuntu box
is down, the plan's Lima recipe is the way back.

## Checking it is up

```sh
scripts/dev-server.sh          # or: nc -vz 192.168.50.6 5930
```

TCP reachability is all that proves. A SPICE server sends nothing until the client has sent its
link message, so the first real evidence is `spicesee-cli connect`.

## M0 exit criterion

```sh
swift run spicesee-cli connect 192.168.50.6 5930
```

**Met, 2026-08-23:**

```
MAIN_INIT session=241582735 mouse=1 agent=0 tokens=10 mmtime=227448441
channels: record/0 playback/0 smartcard/0 usbredir/2 usbredir/1 usbredir/0 display/0 cursor/0 webdav/0 inputs/0
```

`agent=0` because the Windows installer has no vdagent.

### The bug this first flushed out

The first attempt failed with `link(permissionDenied)`, and stayed failing after the server was
reconfigured with `disable-ticketing=on`. Recorded through `spicerec` and decoded by hand:

| Direction | Bytes | Meaning |
|---|---|---|
| c2s | `52454451 02 02 size=22` | link header, protocol 2.2 |
| c2s | `type=01 id=00`, caps_offset 18, common caps `0x0a` | main channel, AUTH_SPICE + MINI_HEADER |
| c2s | `01000000` | auth mechanism = AUTH_SPICE (server advertised PROTOCOL_AUTH_SELECTION) |
| c2s | 128 bytes | RSA-OAEP-SHA1 ticket |
| s2c | `52454451 02 02 size=186` | link header |
| s2c | `00000000` | **link reply error = OK** |
| s2c | 162 bytes `30 81 9f 30 0d ...` | SPKI public key, exactly the layout `unwrapSPKI` expects |
| s2c | common caps `0x0b`, channel caps `0x0f` | AUTH_SELECTION + AUTH_SPICE + MINI_HEADER |
| s2c | `07000000` | **link result = permissionDenied**, after the ticket |

The server accepted the link message, returned its key, and rejected only the ticket — and kept doing
so with ticketing disabled. That was the clue: in `reds_handle_ticket` the RSA decrypt happens
*before* the `ticketing_enabled` check, so `disable-ticketing=on` cannot rescue a ticket the server
fails to decrypt.

The ticket was fine (see `ticketDecryptsWithOpenSSL`); the *framing* was not. In
`reds_handle_read_link_done`:

```c
auth_selection = test_capability(caps, num_caps, SPICE_COMMON_CAP_PROTOCOL_AUTH_SELECTION);
// `caps` is from link_mess — the CLIENT's capabilities, not the server's
if (auth_selection) { read 4-byte auth_mechanism, then the ticket }
else                { read the 128-byte ticket directly }
```

We sent the 4-byte auth mechanism because the *server* advertised the capability (`0x0b`), but
advertised only `AUTH_SPICE | MINI_HEADER` ourselves (`0x0a`). The server therefore read our
mechanism word as the first four bytes of the ticket and the decrypt failed. Fix:
`LinkHandshake.clientCommonCaps()` now advertises `PROTOCOL_AUTH_SELECTION` as spice-gtk does.
Not advertising it would also break against SASL-enabled servers, which reject clients that skip
auth selection.

## Recorded fixtures

`Tests/SpiceKitTests/Fixtures/win-*.bin`, captured 2026-08-23. The Ubuntu box is headless, so the
reference client ran under a virtual framebuffer:

```sh
# here
swift run spicerec 5901 192.168.50.6 5930 recordings/win-installer
# on the Ubuntu box
timeout 25 xvfb-run -a -s "-screen 0 1280x1024x24" remote-viewer spice://192.168.50.38:5901
```

Nine channels were opened. `conn-7` is `display/0`, `conn-1` is `main/0`; the raw capture is
gitignored and only these three files are kept.

| Fixture | From | Contents |
|---|---|---|
| `win-display.s2c.bin` | conn-7 s2c, 18.6 KB | `SURFACE_CREATE`, `DRAW_COPY`, `MONITORS_CONFIG`, `MARK`, `INVAL_ALL_PALETTES`, `SET_ACK`, 4×`PING` |
| `win-display.c2s.bin` | conn-7 c2s, 276 B | the reference client's link mess, so its negotiated caps stay checkable |
| `win-main.s2c.bin` | conn-1 s2c, 250 KB | `MAIN_INIT`, `NAME`, `UUID`, `CHANNELS_LIST`, `MOUSE_MODE`, `NOTIFY`, pings |
| `win-inputs.c2s.bin` | conn-8 c2s, 348 B | `KEY_MODIFIERS`, `PONG`×2, `MOUSE_POSITION`×2, `MOUSE_PRESS`/`MOUSE_RELEASE` (left×2, right, wheel-up), `KEY_SCANCODE`×3 |
| `win-inputs.s2c.bin` | conn-8 s2c, 266 B | `INPUTS_INIT`, `PING`×2, `KEY_MODIFIERS`×2 |
| `win-cursor.s2c.bin` | conn-9 s2c, 269 B | `SET_ACK`, `CURSOR_INIT` (flags NONE — VGA guest, no cursor commands), `PING`×2 |
| `win-desktop.s2c.bin` | 2026-08-30, conn-7 s2c, 7.8 MB | the *installed* Win11 desktop driven through a right-click menu, the start menu and a window drag: `DRAW_COPY`×126 on two surfaces, `MONITORS_CONFIG`×2, `MARK`×2, `SURFACE_DESTROY`, `INVAL_ALL_PALETTES`. Renders clean; **zero** unsupported commands, and zero tier-2/3 commands — see "Where tier-2/3 draw commands actually come from" |

Two things task 15 needs from this:

- **Mini headers are in use.** `remote-viewer` advertised common caps `0xd` — AUTH_SELECTION,
  AUTH_SASL, MINI_HEADER — so the replay must pass `miniHeader: true`. Display channel caps `0x2fbf`.
- **No `STREAM_CREATE` anywhere.** The installer screen came over as a single `DRAW_COPY` on a
  freshly created surface, which is exactly the tier-1 path M1 implements.

`win-main.s2c.bin` is large because 250 KB of it is one `PING`: spice-server's bandwidth net test
(`NET_TEST_BYTES`, 250 KB + a 12-byte ping header = 256012). Our `ChannelReader` already handles it —
`Ping` reads only the leading id and timestamp, and the `PONG` echoes 12 bytes.

### Recording input: the xdotool recipe

`recordings/win-input`, captured 2026-08-24. The guest was in **client mouse mode** (`mouse=2`, a
USB tablet) for this recording, so `remote-viewer` never grabs the pointer and sends absolute
`MOUSE_POSITION` rather than relative `MOUSE_MOTION`:

```sh
# here
swift run spicerec 5901 192.168.50.6 5930 recordings/win-input
# on the Ubuntu box — MACIP is this Mac's address as seen from the box, and it FLIPS between
# the LAN address (ipconfig getifaddr en0) and the VPN address 192.168.4.3 depending on which
# network the Mac is on that day: 2026-08-30 the VPN was stale (a recording against it captured
# zero bytes) and the LAN 192.168.50.38 worked; 2026-08-31 the Mac was on a different subnet and
# only 192.168.4.3 worked. Always test first: ssh in and `nc -vz <candidate> 5901`.
ssh aaron@192.168.50.6 'cat > /tmp/drive.sh' <<'EOF'
#!/bin/sh
remote-viewer spice://MACIP:5901 &
sleep 8
W=$(xdotool search --sync --classname remote-viewer | tail -1)
xdotool windowactivate --sync $W
xdotool mousemove --window $W 400 300; sleep 0.5
xdotool click 1;                 sleep 0.5
xdotool mousemove --window $W 410 305; sleep 0.3
xdotool click 1;                 sleep 0.3
xdotool click 3;                 sleep 0.3
xdotool key a;                   sleep 0.3
xdotool key Delete;              sleep 0.3
xdotool key Left;                sleep 0.3
xdotool click 4;                 sleep 0.3
sleep 2
kill %1
EOF
ssh aaron@192.168.50.6 "timeout 40 xvfb-run -a -s '-screen 0 1280x1024x24' sh /tmp/drive.sh"
```

`xdotool windowactivate --sync` fails under bare Xvfb (`no _NET_ACTIVE_WINDOW`, no window manager
running) and the trailing `kill %1` then misses its target — neither matters, since `mousemove`,
`click`, and `key` deliver synthetic X events directly and don't need window focus with only one
window open.

**The reference client sends keys as `SPICE_MSGC_INPUTS_KEY_SCANCODE` (message 104), not
`KEY_DOWN`/`KEY_UP` (101/102).** This dev server advertises `SPICE_INPUTS_CAP_KEY_SCANCODE` in the
inputs channel's link reply (channel caps bit 0), and spice-gtk (`channel-inputs.c`) gates on the
*server's* advertised capability, not its own: a quick tap goes out as one 104 frame carrying the
raw press-then-release scancode bytes back to back (`e0 53 e0 d3` for Delete, E0 leading each half
— the same byte order `XTScancode.wireCode`/`rawBytes` already use). `InputsChannel` now mirrors
this: it picks 104 vs. 101/102 once, from the server's link-reply caps, and falls back to 101/102
when the server doesn't advertise the capability.

## Where tier-2/3 draw commands actually come from

Recorded 2026-08-30, while scoping M4 (canvas tiers 2-3). **Neither guest on this box emits a
single tier-2 or tier-3 draw command.** Message histograms of whole captures, taken by replaying
each recording through `DisplayChannel` and tallying `DisplayMessage` cases:

| Capture | Guest / driver | Histogram |
|---|---|---|
| `win-display.s2c.bin` | Win11 installer, QXL WDDM | `copy=1` |
| `win-glz-bottomup.s2c.bin` | Win11, QXL WDDM | `copy=10` |
| `win-desktop.s2c.bin` | Win11 desktop, QXL WDDM | `copy=126`, `surfaceCreate=2`, `mark=2`, `monitorsConfig=2`, `surfaceDestroy=1`, `invalAllPalettes=1` |
| Linux Mint 22 Cinnamon, port 5931 | X11 + **modesetting** | `copy=6377`, `surfaceCreate=1`, `mark=1`, `monitorsConfig=1`, `invalAllPalettes=1` |

No `FILL`, `OPAQUE`, `BLEND`, `ROP3`, `TRANSPARENT`, `STROKE` or `TEXT` in any of them, and the
`win-desktop` capture was driven hard on purpose (right-click menu, start menu, an eight-step
window drag). The emptiness is structural, not a weak drive script:

- **Windows 11's QXL driver is WDDM.** It composites inside the guest and hands QXL finished
  dirty-rect bitmaps. The classic QXL 2D command set is implemented by the *XDDM* driver
  (Windows 7 and earlier), which maps the Windows DDI — `BitBlt` ROP3, `LineTo`, `TextOut` —
  onto `ROP3`/`STROKE`/`TEXT`.
- **The Mint guest is X11** (`XDG_SESSION_TYPE=x11`, confirmed in-guest) **but X loaded
  `modesetting`, not `qxl`.** `/var/log/Xorg.0.log` probes only `modesetting`, `FBDEV` and
  `VESA`, even though `xserver-xorg-video-qxl` is installed. Under modesetting, X renders in
  software into a dumb KMS buffer and the qxl *kernel* driver pushes damage as `DRAW_COPY`.
  Only the userspace `xf86-video-qxl` EXA driver emits `FILL`/`OPAQUE`/`BLEND`.

So a fixture that exercises tiers 2-3 needs one of: an X session forced onto `Driver "qxl"` via
`/etc/X11/xorg.conf.d` (needs root in the guest, and a non-compositing WM — Cinnamon's compositor
would blit whole frames anyway), or a Windows 7-era XDDM guest, or a synthetic capture. Until one
exists, **tier-2/3 code is covered by unit tests only**, and a "zero unsupported events on a real
desktop recording" gate proves nothing — it is already green with no tier-2/3 code at all.

### The Linux Mint guest (port 5931)

A second guest on the same box for exactly this comparison: Linux Mint, Cinnamon, X11, SPICE on
**5931** (the Windows guest keeps 5930). No `spice-vdagent` installed, so it is in **server mouse
mode** — `remote-viewer` grabs the pointer, and scripted input is far more reliable through the
keyboard (`xdotool key super`, `ctrl+alt+t`, `alt+F7` to move a window) than through the mouse.

```sh
swift run spicesee-cli dump 192.168.50.6 5931 6 /tmp/mint.png   # 1280x800
```

## Why this guest is a good fixture

The Windows installer runs on basic VGA with no QXL driver loaded, and nothing on screen animates.
The server therefore emits tier-1 draw commands rather than switching regions to MJPEG streams,
which are M4 work. Check for `STREAM_CREATE` in a recording before promoting it to a fixture — a
stream-heavy capture would not exercise the M1 canvas at all.

## M2 exit check (manual)

M2 (input, capture, cursor) cannot be verified by an agent: synthetic mouse/keyboard events are
ignored on this machine, and the app's saved-connection selection isn't persisted, so nothing here
can drive the installer itself. This is the checklist for a human, in one sitting.

### (a) Launch / connect

```sh
xcodegen generate && xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -destination 'platform=macOS' build
open SpiceSee.app          # select the dev guest (192.168.50.6:5930) in the sidebar, then Connect
```

### (b) Keyboard

- [x] **Tab** / **Shift-Tab**: the installer's focus ring moves within a frame. If this doesn't move,
      nothing else below will either.
- [x] **⌥N** activates "Next", **⌥B** goes back (Option maps to Alt by default).
- [x] **Ctrl-Alt-Del wire check.** Proxy the connection and hit the toolbar's Ctrl-Alt-Del button:
      ```sh
      swift run spicerec 5901 192.168.50.6 5930 recordings/live   # then connect to 127.0.0.1:5901
      ```
      Expect six consecutive `INPUTS_KEY_SCANCODE` (104) frames, raw scancode bytes: makes `1d`
      (ctrl), `38` (alt), `e0 53` (delete), then breaks `e0 d3`, `b8`, `9d`. (A single letter is the
      same shape — "a" = `1e` then `9e`.) `log stream --predicate 'subsystem == "com.spicesee"'
      --level debug` should stay error-free throughout.
- [x] **Focus loss releases held keys.** Hold **Shift** and **Cmd-Tab** away — the recording must
      show Shift's `KEY_UP` (`aa`) at that moment, not a stuck modifier. Same check for clicking
      another app's window, and for the app losing active state entirely. Come back and confirm
      typing is normal again.
- [ ] **A ⌘ chord breaks its letter.** Type **⌘V** into a guest text field: exactly one character,
      no runaway repeat. AppKit never routes `keyUp` to the responder chain while ⌘ is held, so
      `GuestInputView` picks those up from a local event monitor — the recording must show `2f`
      followed by `af`. (⌘ maps to Super by default, so the guest sees Win+V, not paste.)

### (c) Mouse, client mode (dev guest — USB tablet, `mouse=2`)

```sh
swift run spicerec 5901 192.168.50.6 5930 recordings/m2-mouse   # optional, for the PRESS 2/3 checks
```

- [x] Moving the mouse over the viewport moves the installer's own arrow; **no capture ever happens**
      and the HUD never appears.
- [x] The host pointer stays visible the whole time.
- [x] Clicking "Next" / "Back" works — the press lands where the pointer is.
- [x] Right-click: nothing visible in the installer, but the capture shows `PRESS 3`.
- [x] Middle-click (physical mouse button 2, not a trackpad): the capture shows `PRESS 2`.
- [x] Scrolling over the language list scrolls it in the same direction a Mac list would.
- [x] Dragging past the window edge clamps the guest pointer at the guest's edge, no jump or wrap.
- [x] Both Fit and 1:1: a click lands where the pointer is drawn.

### (d) Mouse capture, server mode (`--mock --scenario noAgent` — the dev guest is client-mode only)

```sh
BUILT_PRODUCTS_DIR=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Debug -showBuildSettings | grep BUILT_PRODUCTS_DIR | awk '{print $3}')
SPICESEE_MOCK=1 "$BUILT_PRODUCTS_DIR/SpiceSee.app/Contents/MacOS/SpiceSee" --scenario noAgent --autoconnect
```

- [x] Window opens with no HUD, no cue.
- [x] The grabbing click's button-down is swallowed (doesn't reach the guest); host pointer
      disappears and the HUD flashes. The matching release does reach the guest.
- [x] The first small movement after capture does not make the guest pointer jump.
- [x] The cue stays in the top-trailing corner while captured.
- [x] While captured, the pointer cannot leave the window and produces no host cursor movement
      anywhere on screen.
- [x] **⌃⌥ releases**: host pointer reappears where it was parked, cue and HUD go.
- [x] **Cmd-Tab while captured also releases** the pointer (a lone Super tap may open the Start menu
      on a real Windows guest — expected, not a bug).
- [x] **⌃⌥ while *not* captured does nothing** — no stray release, typing still works after.
- [x] Caps lock: turn it on while backgrounded, Cmd-Tab back — the guest's caps state should follow
      (mock only logs this; the real check is against the dev guest).

### (e) Cursor

- [x] `--mock --scenario desktop --autoconnect`, hover the viewport: host pointer becomes the mock's
      black-and-white arrow (12×20, tip at the pointer), back to normal outside the viewport.
- [x] Against a **QXL + vdagent guest** (client mode): the host cursor takes the guest's shapes — an
      I-beam over a text field, a resize cursor over a window edge — and disappears where the guest
      hides its pointer (e.g. a full-screen video player).
- [x] Against the **VGA installer guest** (no agent, server mode): the guest draws its own arrow into
      the framebuffer; the Metal overlay stays empty — nothing to see there is correct, not a
      regression.

## TLS dev endpoint

There is no Proxmox cluster to point at, so M3's TLS path is proved against a real *foreign* TLS
implementation instead: OpenSSL, via `socat`, in front of the same SPICE server. This proves the
verify block interoperates and — the part that matters — rejects what it must.

`scripts/dev-tls.sh` makes the material in `.dev-tls/` (gitignored, idempotent, nothing secret):

| File | What it is |
|---|---|
| `ca.pem` / `ca.key` | throwaway CA, subject `O=PVE Cluster Manager CA, CN=Proxmox Virtual Environment Cluster Manager CA` |
| `server.pem` / `server.key` | leaf issued by that CA, subject `OU=PVE Cluster Node, O=Proxmox Virtual Environment, CN=pve1.example.com` — the RDN order Proxmox emits |
| `server-bundle.pem` | key + leaf concatenated, which is what `socat`'s `cert=` wants |
| `other-ca.pem` | a second CA the server never uses, for the wrong-CA case |

Stand it up:

```sh
./scripts/dev-tls.sh
scp .dev-tls/server-bundle.pem aaron@192.168.50.6:/tmp/spicesee-server.pem
ssh -n aaron@192.168.50.6 'setsid socat OPENSSL-LISTEN:5931,cert=/tmp/spicesee-server.pem,verify=0,reuseaddr,fork TCP:127.0.0.1:5930 </dev/null >/tmp/socat.log 2>&1 & sleep 1; ss -lnt | grep 5931'
```

`setsid` and the explicit `</dev/null` matter: a plain `nohup … &` over `ssh` exits with the session
and leaves no listener.

Then write a `.vv` naming that port and that CA, and run the three cases:

```sh
python3 - <<'EOF'
import pathlib
ca = pathlib.Path('.dev-tls/ca.pem').read_text().replace('\n', '\\n')
pathlib.Path('/tmp/dev.vv').write_text(
    "[virt-viewer]\ntype=spice\nhost=192.168.50.6\nport=0\ntls-port=5931\n"
    "host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com\n"
    f"ca={ca}\n")
EOF
sed 's/CN=pve1.example.com/CN=pve3.example.com/' /tmp/dev.vv > /tmp/wrong-subject.vv
# /tmp/wrong-ca.vv: the same file with other-ca.pem in the ca= line

swift run spicesee-cli vv /tmp/dev.vv              # MAIN_INIT + the ten channels
swift run spicesee-cli vv /tmp/dev.vv 5 /tmp/tls.png   # and a PNG, to prove the whole stack
swift run spicesee-cli vv /tmp/wrong-subject.vv    # subject mismatch, both subjects named
swift run spicesee-cli vv /tmp/wrong-ca.vv         # untrusted — NOT a subject mismatch
```

**Verified 2026-08-24.** The positive case printed the same `MAIN_INIT` and channel list as plain
TCP, and the 5-second capture wrote a 1280×800 PNG of the Windows 11 Setup partition dialog. The two
rejections came back as they should:

```
error: TLS: the server's certificate subject is not the one host-subject asks for
  expected:  OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve3.example.com
  presented: OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com

error: TLS: the server's certificate is not trusted by the file's CA — “pve1.example.com” certificate is not trusted
```

A wrong-CA file reported as a *subject* mismatch would mean the trust evaluation is being skipped —
that is the check worth re-running whenever `TLSPolicy` changes. Both arrived as `SpiceError.tls`,
not as a generic `.connect`, which is the only live proof that `NWTransport` carries the verify
block's reason out past the connection failure.

Tear down when done. **Do not use the pattern verbatim** — `pkill -f "OPENSSL-LISTEN:5931"` matches
the very shell `ssh` started to run it, so it kills itself, prints nothing, and hangs the session:

```sh
ssh -n aaron@192.168.50.6 'pkill -f "OPENSSL-LIST[E]N:5931"; rm -f /tmp/spicesee-server.pem /tmp/socat.log'
```

### What this does *not* prove

- **No Proxmox cluster.** The CA, the leaf and the RDN order are modelled on Proxmox's, not captured
  from one. A real cluster CA chain (Proxmox issues through a cluster manager CA with its own
  extensions) has never been through this code.
- **No ticket flow.** The dev server is ticketless, so the `password=` line of a real `.vv` — a
  one-shot ticket that expires in about 30 seconds — is exercised only by unit tests.
- **`socat` is not spice-server's TLS.** It terminates TLS and proxies plaintext; a real Proxmox
  console has the SPICE server itself doing the handshake.

## M3 exit criterion

Unlike M2, this one *was* driven from this machine, end to end, cold:

```sh
open -a SpiceSee.app /tmp/dev.vv
```

**Met, 2026-08-24.** A cold launch (app not already running) opened `/tmp/dev.vv`, the connection
manager listed it, and a session window rendered the Windows 11 installer — over TLS, not the plain
port: the dev box's connection table showed four established connections to the TLS port (5931) and
none to the plain SPICE port (5930) for the duration. The file's `delete-this-file=1` took effect —
`/tmp/dev.vv` was gone after connecting. Opening a deliberately malformed `.vv` (truncated INI) raised
the failure sheet with no crash and no hang.

What this does *not* prove, same as the TLS dev endpoint above: no real Proxmox cluster, so a genuine
`.vv`, a cluster CA chain, the one-shot ticket flow, and live migration are still unexercised here —
see the manual checklist below.

## M3 exit check (manual)

Two things need a real Proxmox cluster, which does not exist here — this is the user's checklist.

- [ ] **A genuine `.vv`.** From a Proxmox web UI, download the console file for a running VM and
      double-click it (or `open` it) while SpiceSee is *not* already running. Expect a console window,
      the same as the synthetic-CA check above. If it fails, the likely culprit is something about the
      real cluster CA chain or RDN order that `scripts/dev-tls.sh`'s throwaway CA doesn't reproduce.
- [ ] **Live migration.** With a console open, migrate that VM to another node in the cluster. Expect
      the reconnect sheet to appear with the new host prefilled, driven by a real
      `MAIN_MIGRATE_BEGIN`/`MAIN_MIGRATE_SWITCH_HOST` pair. This is the one piece of M3 with **no local
      header confirming the wire layout** — `Packages/CSpiceCodec/Sources/CSpiceCodec/vendor/spice/` carries `enums.h` only,
      so the message shapes are transcribed from `spice.proto` and parsed defensively. If migration
      fails to reconnect, capture it with `spicerec` first (as in the Ctrl-Alt-Del check above) before
      changing any parsing code.

Neither has been exercised here: there is no Proxmox cluster on this network, only the standalone
quickemu guest this whole document is otherwise about.

## M4 exit check (manual)

M4's engine work is unit-tested but **has never been seen against a real server** — see CLAUDE.md's
M4 caveat. These checks are the user's, like M2's, and each one is the first real-traffic evidence
for the thing it names.

Prerequisite for 1 and 2: the guest's spice-server needs streaming enabled. Capture the running
qemu command line first (`ps -ww -eo args | grep qemu-system`) so the change is reversible, append
`,streaming-video=all` to its `-spice` argument, stop the VM cleanly (quickemu's own stop or an ACPI
shutdown — **never `kill -9` a guest with a mounted filesystem**), and relaunch the edited command
under `tmux`/`nohup`. `all` rather than `filter` makes stream creation deterministic: any animating
region streams, with no rate heuristic to satisfy. The Windows guest's original argument, recorded
2026-08-30, was:

    -spice disable-ticketing=on,port=5930,addr=

**Build Release for the smoothness checks, not Debug.** The tier-2/3 kernels are per-pixel Swift
scanline loops (`Tier2.draw` calls `ropCombine` per channel, pattern tiling does two modulos per
pixel, stroke and glyph masks are per-pixel); at `-Onone` none of it inlines or vectorizes. The
pre-M4 path is mostly memcpy/vImage and barely cares, so a Debug build penalises the new code far
more than the old and biases the very comparison these checks are making. The corruption check
below is about pixels rather than timing, so Debug is fine there — and `assert()` survives in
Debug, which Release strips.

```sh
xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Release -destination 'platform=macOS' build
BUILT_PRODUCTS_DIR=$(xcodebuild -project SpiceSee.xcodeproj -scheme SpiceSee -configuration Release -showBuildSettings | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')
"$BUILT_PRODUCTS_DIR/SpiceSee.app/Contents/MacOS/SpiceSee"
```

- [ ] **Video plays as well as it did before M4.** Play a full-screen YouTube HD video in the guest
      through SpiceSee. Bar: **indistinguishable from the pre-M4 draw path — zero lag, zero
      choppiness, no tearing at the stream's edges**, and a window resize mid-video stays clean.
      This is the performance gate the whole stream path is judged on.
- [ ] **The draw path did not regress.** Restore the original command line (streaming off) and play
      the same video. It should look exactly as it did before M4 — this is what proves the tier-2/3
      routing changes left tier-1 traffic alone.
- [ ] **No corruption anywhere, by eye.** Right-click menus, window drags, text selection across the
      desktop. Tiers 2-3 have no real-traffic coverage at all, so this check is the only thing
      standing between them and a corruption bug.
- [ ] **`STREAM_REPORT` actually goes out.** With streaming on, watch
      `log stream --predicate 'subsystem == "com.spicesee"' --level info` and confirm reports are
      sent and no canvas `unsupported` lines appear.

**Done 2026-08-31: the fixture exists.** `Tests/SpiceKitTests/Fixtures/mint-video.s2c.bin` is the
Mint guest's display channel recorded with `streaming-video=all` while a maximized terminal ran
`yes` — 2 `STREAM_CREATE`, 260 `STREAM_DATA`, every frame MJPEG-decoded by
`mintVideoReplayDecodesStreams` (`ReplayTests.swift`), which pins one decoded frame against
`mint-video-frame.golden.png`. That is the stream wire layouts' first confirmation against real
server bytes. Two findings from making it: spice-server tiles a scrolling terminal into small
per-text-row streams (the golden frame is a text fragment on purpose — a single large stream needs
a real video player, which is what the live check above exercises), and the Mac's reachable
address had flipped back to the VPN one (see the recording recipe note) — check before recording.

**The Mint guest was left running with `streaming-video=all` on 2026-08-31** so the exit-check
items above can be run without re-doing the setup. Its pre-change command line is saved on the box
at `/tmp/mint-original-cmdline.txt` (streaming variant: `/tmp/mint-streaming-cmdline.txt`). To
restore after the exit check:

```sh
ssh aaron@192.168.50.6 'cd /home/aaron/vms/mint && echo system_powerdown | socat - UNIX-CONNECT:linuxmint-22-cinnamon/linuxmint-22-cinnamon-monitor.socket'
# wait for the qemu process to exit (the guest ACPI-shutdowns cleanly; allow ~60s), then:
ssh aaron@192.168.50.6 'cd /home/aaron/vms/mint && setsid nohup bash /tmp/mint-original-cmdline.txt </dev/null >/tmp/mint-qemu.log 2>&1 &'
```

## Known issues (not fixed, out of M3's scope)

- **The app cannot be quit while a connection-failure sheet is up.**
  `osascript -e 'tell application "SpiceSee" to quit'` returns `-128` and the process survives; it
  quits normally once the sheet clears. Pre-existing behavior, not introduced by M3.
- **The failure sheet's Cancel button is not automatable.** It has no keyboard equivalent, and does
  not respond to synthetic `CGEvent` clicks (see "Verifying UI work on this machine" in `CLAUDE.md`),
  so its dismissal path must be click-verified by a human, not an agent.

## Clipboard (M5) — what the guest can and cannot prove

**The dev guest now runs a vdagent.** It did not at M0 (`agent=0`, Windows sitting at the installer);
Windows and the guest tools have since been installed, which is also why `mouse=2`:

```
MAIN_INIT session=1313870989 mouse=2 agent=1 tokens=10 mmtime=48996002
```

`spicesee-cli clipboard` is the probe — it prints the negotiation, fetches whatever the guest copies,
and answers the guest's paste requests:

```sh
swift run spicesee-cli clipboard 192.168.50.6 5930 --send "line one
line two" --seconds 20
```

**Verified against the real Windows vdagent, 2026-08-25:**

```
connected; watching the clipboard for 20.0s
clipboard sharing negotiated
offering 26 bytes of text
```

`clipboard sharing negotiated` is the load-bearing line. Reaching it means the agent accepted
`MSGC_MAIN_AGENT_START`, our `VD_AGENT_ANNOUNCE_CAPABILITIES` was framed well enough for a real agent
to parse, and its reply came back and decoded — the whole `MAIN_AGENT_DATA` path, header included.

### The bug the C header flushed out

`VDAgentMessage` is `SPICE_ATTR_PACKED`, so it is **20 bytes**, not the 24 that natural alignment of
its `uint64 opaque` implies. Transcribing the struct by eye gets this wrong and every field lands
four bytes out. `Tools/agentref.c` builds each message with the real structs and `VD_AGENT_SET_*`
macros and prints the bytes; `AgentMessagesTests` pins our encoder against that output:

```sh
cc -I$(brew --prefix spice-protocol)/include/spice-1 -o /tmp/agentref Tools/agentref.c && /tmp/agentref
```

### M5 clipboard exit check (manual)

Both remaining checks need someone at the guest's console — the guest only sends `CLIPBOARD_GRAB`
when a person copies in Windows and `CLIPBOARD_REQUEST` when a person pastes. The guest's display was
blanked when this was written, and waking it to type blind is not something to do to a running VM.

- [ ] **Guest → host.** Copy text in the guest (Notepad, a browser). The probe above should print
      `guest grabbed, offering: utf8Text` then the text, with `\r\n` shown as `\n` — the conversion
      is the point, since Windows copies CRLF and the Mac pasteboard wants LF.
- [ ] **Host → guest.** With `--send` set, paste in the guest. The probe prints
      `guest is pasting, wants utf8Text` and the guest receives both lines, with the line break
      intact rather than as a single run-on line.
- [x] **In the app.** ⌘C on the Mac, then paste in the guest; copy in the guest, then ⌘V on the Mac.
      The toolbar's clipboard toggle turns sharing off, and with it off neither direction moves.
- [ ] **Note the ⌘ mapping.** ⌘ maps to Super by default, so ⌘V inside the viewport sends **Win+V**
      (Windows clipboard history), not paste. Paste in the guest with **⌃V**, or set ⌘→Ctrl in the
      connection's Advanced settings.

## M5 exit check (manual)

Machine-driveable halves first — run them before handing the rest over.

**Resize, verified 2026-09-01.** `spicesee-cli resize 192.168.50.6 5930 1600 900`:

```
connected; requesting 1600x900, watching for 20.0s
display 0 primary now 1280x720
display 0 heads: 1280x720@0,0
sent VD_AGENT_MONITORS_CONFIG 1600x900 (dropped silently if the guest lacks the cap)
display 0 heads: 1600x900@0,0
display 0 heads: 1600x900@0,0
display 0 heads: 1600x900@0,0
disconnected
```

The Windows guest answered with the `monitorsConfig` heads line, not a bare "primary now" line.
Restored immediately after with
`spicesee-cli resize 192.168.50.6 5930 1920 1080`, which came back the same shape and settled on
`1920x1080@0,0`. This is the packed `VD_AGENT_MONITORS_CONFIG` encoder, the `monitorsConfig` cap
gate, and a real guest applying it, all in one round trip.

**Clipboard image, verified 2026-09-01 (wire half only).**
`spicesee-cli clipboard 192.168.50.6 5930 --send-image Tests/SpiceKitTests/Fixtures/win-display.golden.png --save-image /tmp/guest-copy.png --seconds 10`:

```
connected; watching the clipboard for 10.0s
clipboard sharing negotiated
disconnected
```

No one was at the guest console, so neither `guest is pasting, wants imagePNG` nor a write to
`/tmp/guest-copy.png` happened — expected, and `/tmp/guest-copy.png` was confirmed absent
afterward. What this run does prove: `--send-image`/`--save-image` parse and don't throw, and
negotiation still succeeds with the image capability announced alongside text. The guest-console
halves — actually copying/pasting an image — are the checklist below.

- [ ] `spicesee-cli clipboard --send-image <png> --save-image /tmp/g.png` moves an image each way
      (needs a person at the guest console to copy/paste, as with the text checks above).

In the app, needing a person on both ends:

(The in-app boxes below were verified by the user on 2026-09-01 against the Windows dev guest — "works great". The probe-only boxes above still want a run with someone at the guest console.)

- [x] Drag a viewport window: ~250 ms after the drag ends the guest desktop matches the new size.
      With the 2× toolbar toggle on, the guest resolution doubles the window's point size and 1:1
      shows one guest pixel per device pixel.
- [x] Copy an image in the guest, ⌘V on the Mac; copy an image on the Mac (⌘⇧4 to clipboard works),
      paste in the guest (⌃V — ⌘V is Win+V, see the M5 clipboard notes above). Clipboard toggle off
      stops both.
- [ ] The outstanding text-clipboard boxes in "M5 clipboard exit check" above.
- [x] **First-report guard vs. window-open transient.** Open a viewport window and watch the guest:
      does SwiftUI's first `onChange(of: proxy.size)` after the window opens carry a transient or
      zero size that burns the debounce's "first report" guard, so the *real* content size then goes
      out as a resize request right at window-open time? Watch for an unwanted resolution change
      immediately after opening a window, not just after a drag.
- [x] **`onDisappear` vs. full screen.** `--mock --scenario desktop --autoconnect` opens two windows
      (the scenario's second display); enter and leave full screen on one of them. Confirm neither
      window's `onDisappear` fires during the transition — if it did, that head would wrongly
      report as disabled to the guest mid-transition.

**Multi-head is mock-proven, not server-proven** — the same honesty rule as M4's tier-2/3 gate.
Neither dev guest exposes a second head (Windows/WDDM single-QXL; the Proxmox guest runs
modesetting), so the viewport model's evidence is `ViewportMapperTests` + the two-window `--mock`
review. A future guest with `qxl.heads=2` (or two qxl devices) upgrades this to a live check: open
both windows, close one, and the guest should drop to one active monitor.

**Deviation from the spec: `DisplayLayout` carries no position.** The spec's layout type had a
`position` per head; the seam type ships size and enabled only, and `MonitorTiling` synthesises the
arrangement — enabled heads left to right at y=0. Host window positions do not map onto a guest
desktop in any meaningful way (different screen counts, scales and origins, and the guest arranges
its own monitors), so a position sent from here would be noise the guest has to reconcile. It
becomes a real field only if a multi-head guest is ever seen needing it.

## M6 exit check (manual)

Machine-driveable half (needs a sound playing in the guest — a YouTube tab, a Windows system sound):

- [x] `swift run spicesee-cli audio 192.168.50.6 5930 15 /tmp/guest-audio.wav` prints
      `START rate=48000 channels=2 mode=OPUS` and writes a WAV you can hear the guest in. `mode=RAW`
      means the Opus capability was not announced (the AudioToolbox probe failed on this Mac) or the
      server ignored it; either way sound still plays, but say which.

**Probed 2026-09-01, nobody at the guest console:**

```
connected; recording audio for 15.0s
VOLUME 0.85 0.85
MUTE false
no PLAYBACK_START arrived — is anything playing in the guest?
```

The playback channel opened and negotiated — PLAYBACK_VOLUME and PLAYBACK_MUTE both parsed from the
real server — and stayed silent for the full 15 s, which is expected with nothing playing in the
guest. `/tmp/guest-audio.wav` was confirmed absent afterward. The START/OPUS half of the checklist
item above still wants a run with sound actually playing.

(The probe box above and the mute box below were verified by the user on 2026-09-01 with sound playing in
the Windows guest — "that's good" / "mute button works fine". The probe's verbatim output from that run was not
captured here; the earlier no-START transcript above is the machine's own attempt.)

In the app:

- [x] Guest sound plays from the Mac's speakers with no audible stutter over about a minute.
      (User-verified 2026-09-01 against the live Windows guest: "audio worked fine". The volume-slider,
      mute and pause/resume boxes below were not separately reported — tick them when you try them.)
- [ ] Moving the guest's volume slider changes the level (PLAYBACK_VOLUME → the player node).
- [x] The toolbar mute silences it and un-mute restores it (the mixer; the guest's level is kept).
- [ ] Pausing the guest's player sends PLAYBACK_STOP and the app goes silent without clicks; resuming
      starts cleanly after the ~50 ms prebuffer.
- [ ] `--mock --scenario desktop --autoconnect` ticks a quiet 440 Hz tone once a second; the mute
      button stops it.

**Opus decode is Apple's, not libopus.** `OpusDecoder.isAvailable()` probes `AudioConverterNew`
with `kAudioFormatOpus` at connect time and the capability is announced only when that passes.
Verified on this Mac (macOS 26.x); **a macOS 14 machine has not been checked** — the deployment
floor is 14 and Opus landed in AudioToolbox in that release, but if it fails there the fallback
is raw PCM at ~1.5 Mbps, not silence. The fixture `Tests/SpiceMediaTests/Fixtures/tone-48k-stereo.opus.bin`
was encoded by libopus 1.6.1 via `Tools/opusref.c` so the decoder is never tested against itself.
The `opus` flag on the seam's `.started` event names the codec PLAYBACK_MODE **negotiated**, not
whether local decode is actually working — a probe that passed at connect but then throws per-frame
still reports `opus: true`.

**No lip-sync.** Audio and video streams are each paced to the mm clock independently; nothing
ties a frame to a sample. The record (microphone) channel is not opened.

**Audio never touches a realtime render thread.** `AudioOutput.scheduleBuffer`, called from the
main actor, is the whole output path; the ~50 ms prebuffer is the only jitter buffer in the system.
Two volume controls multiply rather than compose: guest volume/mute lands on the `AVAudioPlayerNode`,
toolbar mute on the mixer — muting one never substitutes for the other.
