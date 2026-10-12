# Outbound relay

This is a small ciphertext forwarder. The computer opens an outbound `wss` connection to `/v1/room`. The Apple Watch long-polls `POST /v1/watch` over plain HTTPS, because a real Apple Watch refuses WebSockets to ordinary apps (Apple TN3135; the simulator does not enforce this). After each side presents its pairing token, the process copies binary frames from one side to the other.

It does not decrypt those frames. Commands, approvals, and session text stay inside the end-to-end seal between the Watch and `watch-remote-outbound` on the computer. Do not log request bodies, WebSocket frames, or tokens in the proxy you put in front of this process.

Nothing in this directory is deployed by the repository. Host it yourself when you want the Watch to work without the iPhone nearby.

## Run

Node 22 or newer. No packages to install.

```bash
node relay/outbound/server.mjs
```

By default it listens on `127.0.0.1:8787`. That is only useful on the same machine. To publish it, set a bind address and put TLS in front, or give the process a certificate:

```bash
export WATCHREMOTE_OUTBOUND_BIND=0.0.0.0
export WATCHREMOTE_OUTBOUND_PORT=8787
export WATCHREMOTE_OUTBOUND_TLS_CERT=/path/to/fullchain.pem
export WATCHREMOTE_OUTBOUND_TLS_KEY=/path/to/privkey.pem
node relay/outbound/server.mjs
```

Use a hostname you control and a certificate the Watch will trust. The pairing URL is `wss://` plus that hostname and `/v1/room`. There is no built-in URL. Pass it to `watch-remote-pair --relay-url` on the computer. Do not put the URL in this repository.

`GET /health` returns `{"ok":true,"watchPoll":true}` and lists nothing. A relay without `watchPoll` predates the Watch HTTP path; redeploy it, or the Watch shows "Relay needs an update".

### Watch poll

`POST /v1/watch` with `Authorization: Bearer <room token>` and a JSON body:

```json
{"send": ["<base64 ciphertext>"], "after": 12, "epoch": "<from the last reply>", "wait": 25000}
```

The reply is `{"ok":true,"epoch":"...","host":true,"frames":[{"seq":13,"data":"<base64>"}]}`. `host` says whether the computer is connected. Frames for the Watch stay queued (up to 64) until a later poll acks them with `after`, so a reply is not lost when a poll dies in flight. A poll with nothing to send waits up to `wait` milliseconds (at most 25 seconds) for the next frame. A new `epoch` means the room was recreated; start again from `after: 0`.

## Limits

| Environment | Default | Meaning |
| --- | --- | --- |
| `WATCHREMOTE_OUTBOUND_RATE` | 120 | Frames per 10 seconds on one socket, or from one room's Watch polls |
| `WATCHREMOTE_OUTBOUND_POLLS` | 60 | Watch polls per 10 seconds from one address |
| `WATCHREMOTE_OUTBOUND_WATCH_QUEUE` | 64 | Frames held for a Watch that is between polls |
| `WATCHREMOTE_OUTBOUND_UPGRADES` | 30 | New sockets per minute from one address |
| `WATCHREMOTE_OUTBOUND_AUTH_FAILURES` | 8 | Bad tokens per minute from one address |
| `WATCHREMOTE_OUTBOUND_MAX` | 200 | Open sockets |
| `WATCHREMOTE_OUTBOUND_TRUST_PROXY` | off | See below |

`WATCHREMOTE_OUTBOUND_TRUST_PROXY` stays off until you set it. `on` trusts only `127.0.0.1` and `::1`. A comma-separated list trusts those proxy addresses instead. The client address is then the right-most untrusted `X-Forwarded-For` entry, and that address is what the per-address limits use. Any other peer is limited by its socket address. Do not log the forwarded header.

A room is one pairing token. It holds one host and one Watch. A new connection with the same role replaces the old one. A room with nobody connected is forgotten after 30 idle minutes. Frames are not written to disk. Restarting the process drops every room. Both sides connect again.

## Docker

```bash
docker build -t watch-remote-outbound -f relay/outbound/Dockerfile relay/outbound
docker run --rm -p 8787:8787 watch-remote-outbound
```

The image listens in the container without TLS. Terminate TLS at your proxy, and do not enable access logs that record request or WebSocket bodies, the `Authorization` header, or `X-Forwarded-For`. If that proxy is the only path in, set `WATCHREMOTE_OUTBOUND_TRUST_PROXY` to `on` when it connects from localhost, or to the address this process sees for the proxy.

## Tests

```bash
node --test relay/outbound/test.mjs
```
