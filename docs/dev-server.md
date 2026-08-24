# Dev SPICE server

The plan (task 12, step 1) assumed a SPICE server had to be stood up on this Mac, via Homebrew
QEMU or a Lima VM. That is not needed here: there is a real one on the LAN.

| | |
|---|---|
| Host | `192.168.50.6` (Ubuntu server) |
| Port | `5930` |
| Ticket | none — connect with an empty password |
| Guest | Windows, sitting at the installer dialog |
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

## Why this guest is a good fixture

The Windows installer runs on basic VGA with no QXL driver loaded, and nothing on screen animates.
The server therefore emits tier-1 draw commands rather than switching regions to MJPEG streams,
which are M4 work. Check for `STREAM_CREATE` in a recording before promoting it to a fixture — a
stream-heavy capture would not exercise the M1 canvas at all.
