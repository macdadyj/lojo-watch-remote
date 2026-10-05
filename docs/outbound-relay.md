# Watch without the iPhone

The iPhone path is unchanged. The iPhone holds SSH to the computer over the private overlay, and the Watch can keep using that path. It shows **via iPhone** while the iPhone app is reachable.

That path stops when the iPhone is left behind. The Watch cannot join the private overlay, and SSH on the computer stays off the public internet. The way across that gap is an outbound relay you host yourself.

```text
Watch  --wss-->  relay  <--wss--  watch-remote-outbound  -->  127.0.0.1:2419
```

The computer dials out. The Watch dials out. Neither one accepts a public SSH connection. After a short hello that only carries the pairing token, every frame is ciphertext. The relay copies those frames from one socket to the other. It does not have the pairing key, so it cannot read commands, approvals, or session text.

This repository does not deploy a relay and does not create any cloud resources. The relay address is whatever you pass to `watch-remote-pair`. It is not written in the app.

## What you do to host the relay

1. Pick a machine you control and a hostname with a certificate the Watch will trust. `relay.example` in these docs is only a placeholder.
2. From a checkout of this repo, on that machine:

   ```bash
   node relay/outbound/server.mjs
   ```

   It listens on `127.0.0.1:8787` until you set `WATCHREMOTE_OUTBOUND_BIND` and `WATCHREMOTE_OUTBOUND_PORT`. Put TLS in front of it (Caddy, nginx, or any other proxy), or set `WATCHREMOTE_OUTBOUND_TLS_CERT` and `WATCHREMOTE_OUTBOUND_TLS_KEY` to a certificate for that hostname. Do not log WebSocket bodies or the pairing token. `GET /health` returns `{"ok":true}` and nothing else.

   A container build is in [relay/outbound/README.md](../relay/outbound/README.md). The image has no URL baked in.

3. On the computer that runs Grok, pass that address when you pair. The token and the end-to-end key are generated there. They go into the QR and into `~/.config/watch-remote/outbound.json` (mode `0600`). They are not printed on their own line.

   ```bash
   watch-remote-pair --relay-url wss://relay.example/v1/room
   ```

   `WATCHREMOTE_RELAY_URL` is the same flag as an environment variable. If you omit both, the QR is SSH-only and the Watch still needs the iPhone.

4. Install the outbound client next to the other host scripts and start it:

   ```bash
   install -m 755 host/watch-remote-outbound host/outbound.py host/relaybox.py host/miniws.py ~/.local/bin/
   cp host/watch-remote-outbound.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now watch-remote-outbound.service
   ```

   The unit file does not contain the relay address. The process reads `outbound.json`. Restart it after you pair again, because a new QR rotates the token. `watch-remote-agent` still has to be running on `127.0.0.1:2419`. That is what the outbound client talks to. SSH is still how the iPhone gets in.

5. On the iPhone, open **Computer**, tap **Scan QR code**, confirm the fingerprint, copy the authorize command, run it on the computer, and tap **Test connection**. The iPhone sends the direct pairing to the Watch over WatchConnectivity. The Watch stores it in its own Keychain. It does not stay only on the iPhone.

6. Leave the iPhone. Open Watch Remote on the Watch, on Wi-Fi or cellular. The header says **direct**. Sessions, New task, Allow, Deny, and Stop use that path. When the iPhone is in reach again, the header says **via iPhone** and the Watch uses the phone.

## What the Watch can and cannot do alone

watchOS will keep a WebSocket only while Watch Remote is in the foreground. When the app is suspended, the socket is gone. There is no background connection.

Opening the app connects again and shows the last sessions it had. A task you already started keeps running on the computer. Allow and Deny work after the app is open and the header says **direct**. If the relay or the computer is down, the screen says so in plain words and keeps the last list.

Demo mode never opens the relay. A pairing QR without a relay URL never opens it either.

## Relay behavior

| | |
| --- | --- |
| Room | one pairing token, one host, one Watch |
| Auth | first text frame is the token; it is not logged |
| After auth | binary frames only, forwarded as-is |
| Rate limits | new sockets, bad tokens, and frames per connection |
| Disk | nothing is stored; a restart drops every room |

Details and the environment variables are in [relay/outbound/README.md](../relay/outbound/README.md).

The older HTTP relay in [relay-api.md](relay-api.md) is a different program. It runs on the computer and is reached over the overlay by the iPhone. Leave it off unless you want that path. The outbound relay is the one the Watch uses when the iPhone is away.
