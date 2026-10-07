# Relay API

The relay is optional. Watch Remote’s primary path is SSH from the iPhone to your computer, described in [HOST-SETUP.md](HOST-SETUP.md). Use the relay when you want the phone to speak HTTP on the overlay instead of holding an SSH session.

The relay runs on that computer. `WATCHREMOTE_RELAY_BIND` has no default. It must be an address in `100.64.0.0/10`, or `127.0.0.1` for a local process. It refuses `0.0.0.0`, public addresses, and other private ranges. The Grok login stays on the computer. The agent secret stays in the relay process environment (`GROK_AGENT_SECRET`). Device tokens are stored as SHA-256 hashes in `~/.config/watch-remote/device-tokens.json` (mode `0600`).

## Adapters

`WATCHREMOTE_RELAY_ADAPTER` selects one implementation behind the same routes:

| Adapter | Behavior |
| --- | --- |
| `acp` (default) | Persistent WebSocket to `grok agent serve`. Approvals work. Secret is an `Authorization` header, not a URL and not an argv. |
| `cli` | `grok -p … --output-format streaming-json --permission-mode dontAsk`. Stopping kills the process. `decide` returns an error. |
| `mock` | In-memory sessions for tests. No Grok process. |

The phone also has a Demo mode that never contacts the relay.

## TLS

TLS is on unless `WATCHREMOTE_RELAY_TLS=0`. The first launch writes a self-signed certificate with a SAN for the bind address and prints the SHA-256 fingerprint. Put that fingerprint in the iPhone Settings as the relay pin. The app pins the leaf certificate and will not send the bearer token to a different certificate. There is no ATS exception and no trust-all setting.

## Auth

`POST /v1/pair` requires `Authorization: Bearer <WATCHREMOTE_RELAY_ADMIN>`. The admin token is not stored in git. The response is a device token. Save it in the iPhone Keychain. Every other route except `GET /health` requires that device token as a bearer.

`GET /health` returns `{"ok": true, "adapter": "acp"}` with no auth, so you can check the process without a token. It does not list sessions.

## Routes

Dates in JSON are Unix seconds.

`GET /v1/sessions`

```json
{"sessions": [{"id": "…", "title": "…", "summary": "…", "status": "running", "updatedAt": 0}]}
```

`POST /v1/sessions`

```json
{"prompt": "Summarize the open changes", "cwd": "/home/user/src"}
```

`POST /v1/permissions/<id>`

```json
{"allow": true}
```

`POST /v1/sessions/<id>/cancel`

Empty object. Stops that session. This is an explicit stop. The relay does not expire a session on its own.

`POST /v1/sessions/<id>/resume`

Returns `{"lines": ["…"], "session": {…}}`. Opening a chat loads those lines. A missing id returns 404.

`POST /v1/sessions/<id>/prompt`

```json
{"prompt": "add a note", "cwd": "/home/user/src"}
```

Continues that session. A missing id returns 404 so the phone can open a new backend session with the earlier lines.

## Run

```bash
install -d -m 700 ~/.config/watch-remote
umask 077
printf 'WATCHREMOTE_RELAY_BIND=%s\n' "100.64.0.2" > ~/.config/watch-remote/relay.env
printf 'WATCHREMOTE_RELAY_ADMIN=%s\n' "$(openssl rand -hex 32)" >> ~/.config/watch-remote/relay.env
printf 'GROK_AGENT_SECRET=%s\n' "$(cat ~/.config/watch-remote/agent-secret)" >> ~/.config/watch-remote/relay.env
chmod 600 ~/.config/watch-remote/relay.env
# Replace 100.64.0.2 with your overlay address. There is no default.
# From a checkout of this repo, on the computer:
cp host/watch-remote-relay.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now watch-remote-relay.service
```

The unit expects this repo at `~/watch-remote` (`WorkingDirectory` and `PYTHONPATH`). It reads `relay.env` and runs `python3 -m watchremote_relay`. It does not put the admin token or the agent secret in the unit file.

On the iPhone, set the mode to Relay, the URL to `https://` plus your overlay address and port `2479`, the device token, and the certificate fingerprint.
