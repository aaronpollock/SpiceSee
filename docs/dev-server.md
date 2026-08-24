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

**Not yet met — the server denies the ticket.** 2026-08-23:

```
error: SpiceError(kind: link(permissionDenied), channel: main/0)
```

The handshake itself is correct on our side. Recorded through `spicerec` and decoded by hand:

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

So the server accepted the link message, returned its key, and rejected only the ticket. That is the
signature of `spice-server` with ticketing *enabled* and no password set — it refuses every client
with permission denied rather than allowing an empty ticket. The fix is on the server: quickemu must
pass `disable-ticketing=on`, or set a password to hand to `spicesee-cli connect <host> <port> <pw>`.

Check the running guest with:

```sh
ps aux | grep -o '[-]spice [^ ]*' | tr ',' '\n'
```

## Why this guest is a good fixture

The Windows installer runs on basic VGA with no QXL driver loaded, and nothing on screen animates.
The server therefore emits tier-1 draw commands rather than switching regions to MJPEG streams,
which are M4 work. Check for `STREAM_CREATE` in a recording before promoting it to a fixture — a
stream-heavy capture would not exercise the M1 canvas at all.
