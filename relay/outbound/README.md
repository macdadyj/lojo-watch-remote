# Outbound relay

This is a small WebSocket forwarder. The computer opens an outbound `wss` connection to it. The Apple Watch opens another. After each side presents its pairing token, the process copies binary frames from one socket to the other.

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

`GET /health` returns `{"ok":true}` and lists nothing.

## Limits

| Environment | Default | Meaning |
| --- | --- | --- |
| `WATCHREMOTE_OUTBOUND_RATE` | 40 | Frames per 10 seconds on one socket |
| `WATCHREMOTE_OUTBOUND_UPGRADES` | 30 | New sockets per minute from one address |
| `WATCHREMOTE_OUTBOUND_AUTH_FAILURES` | 8 | Bad tokens per minute from one address |
| `WATCHREMOTE_OUTBOUND_MAX` | 200 | Open sockets |

A room is one pairing token. It holds one host and one Watch. A new connection with the same role replaces the old one. Frames are not written to disk. Restarting the process drops every room. Both sides connect again.

## Docker

```bash
docker build -t watch-remote-outbound -f relay/outbound/Dockerfile relay/outbound
docker run --rm -p 8787:8787 watch-remote-outbound
```

The image listens in the container without TLS. Terminate TLS at your proxy, and do not enable access logs that record WebSocket bodies.

## Tests

```bash
node --test relay/outbound/test.mjs
```
