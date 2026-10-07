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

   It listens on `127.0.0.1:8787` until you set `WATCHREMOTE_OUTBOUND_BIND` and `WATCHREMOTE_OUTBOUND_PORT`. Put TLS in front of it (Caddy, nginx, or any other proxy), or set `WATCHREMOTE_OUTBOUND_TLS_CERT` and `WATCHREMOTE_OUTBOUND_TLS_KEY` to a certificate for that hostname. Do not log WebSocket bodies, the pairing token, or `X-Forwarded-For`. `GET /health` returns `{"ok":true}` and nothing else.

   If the proxy runs on the same machine, every socket looks like `127.0.0.1`. Turn on trust-proxy, below, or one client can use up the rate limit for everyone.

   A container build is in [relay/outbound/README.md](../relay/outbound/README.md). The image has no URL baked in.

3. On the computer that runs Grok, pass that address when you pair. The token and the end-to-end key are generated there. They go into the QR and into `~/.config/watch-remote/outbound.json` (mode `0600`). They are not printed on their own line.

   ```bash
   watch-remote-pair --relay-url wss://relay.example/v1/room
   ```

   `WATCHREMOTE_RELAY_URL` is the same flag as an environment variable. If you omit both, the QR is SSH-only and the Watch still needs the iPhone.

4. Install the outbound client next to the other host scripts and start it:

   ```bash
   install -m 755 host/watch-remote-outbound host/watch-remote-stt host/outbound.py host/relaybox.py host/miniws.py ~/.local/bin/
   cp host/watch-remote-outbound.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now watch-remote-outbound.service
   ```

   The unit file does not contain the relay address. The process reads `outbound.json`. Restart it after you pair again, because a new QR rotates the token. `watch-remote-agent` still has to be running on `127.0.0.1:2419`. That is what the outbound client talks to. SSH is still how the iPhone gets in.

5. On the iPhone, open **Computer**, tap **Scan QR code**, confirm the fingerprint, copy the authorize command, run it on the computer, and tap **Test connection**. The iPhone sends the direct pairing to the Watch over WatchConnectivity. The Watch stores it in its own Keychain. It does not stay only on the iPhone.

6. Leave the iPhone. Open Watch Remote on the Watch, on Wi-Fi or cellular. The header says **direct**. Sessions, New task, Allow, Deny, and Stop use that path. When the iPhone is in reach again, the header says **via iPhone** and the Watch uses the phone.

## What the Watch can and cannot do alone

Lowering the wrist does not end a listen and does not mean the pairing was rejected. While the Watch is listening it starts an extended runtime session so recording can continue. If watchOS suspends the app anyway, the samples already captured stay in memory and the direct pairing stays in the Watch Keychain. Raising the wrist resumes that listen. A dropped socket retries with backoff and the screen says **Reconnecting…** only when the display is on. That is not a new pairing. The sentence **This relay did not accept this pairing** appears only when the relay's auth reply is explicitly not ok. Then the Watch asks the iPhone to open the pairing screen.

A task you already started keeps running on the computer. Allow and Deny work while the header says **direct**. If the relay or the computer is down, the screen says so in plain words and keeps the last list. The host outbound client is unchanged.

Demo mode never opens the relay. A pairing QR without a relay URL never opens it either.

## Relay behavior

| | |
| --- | --- |
| Room | one pairing token, one host, one Watch |
| Auth | first text frame is the token; it is not logged |
| After auth | binary frames only, forwarded as-is |
| Rate limits | new sockets, bad tokens, and frames per connection |
| Client address | the socket peer, unless trust-proxy is on |
| Disk | nothing is stored; a restart drops every room |

## Trust proxy

`WATCHREMOTE_OUTBOUND_TRUST_PROXY` is off by default. Leave it off when clients connect straight to this process. A client must not be able to pick its own rate-limit address by sending `X-Forwarded-For`.

Turn it on only when a reverse proxy you run is the thing that opens the socket. `on` (or `1` / `true`) trusts `127.0.0.1` and `::1`, which is the usual case for Caddy or nginx on the same host. To trust different proxies, set the variable to those addresses, separated by commas. Only that list is trusted. A peer that is not on the list is rated by its socket address, and its `X-Forwarded-For` header is ignored.

When the peer is trusted, the client address is the right-most `X-Forwarded-For` entry that is not itself on the trusted list. Entries further left are ignored, so a client cannot hide behind an address it wrote itself. The proxy has to append the address it actually accepted. That address is used for new-socket limits and for bad-token lockouts. It is not written to the log.

```bash
export WATCHREMOTE_OUTBOUND_TRUST_PROXY=on
node relay/outbound/server.mjs
```

Details and the other environment variables are in [relay/outbound/README.md](../relay/outbound/README.md).

The older HTTP relay in [relay-api.md](relay-api.md) is a different program. It runs on the computer and is reached over the overlay by the iPhone. Leave it off unless you want that path. The outbound relay is the one the Watch uses when the iPhone is away.

## Watch transcription

When the iPhone app is closed, the Watch still records and sends one utterance as a `transcribe` frame (base64 PCM, 16 kHz, mono, 16-bit). `watch-remote-outbound` answers with `transcript`. `watch-remote-agent` does not see the audio. It only speaks ACP to grok on `127.0.0.1:2419`.

Use whisper.cpp, not the Python `whisper` package and not faster-whisper. The CPU binary is `whisper-cli`. For short Watch commands the model is `ggml-base.en-q5_1` (English, about 57 MB). On a typical 4-core CPU a few seconds of speech comes back in well under two seconds. `ggml-tiny.en-q5_1` is faster and less reliable on one-word replies such as yes and no. `small` and larger models are too slow for this turn on CPU.

The outbound unit sets `WATCHREMOTE_STT_COMMAND` to `~/.local/bin/watch-remote-stt`. That program is invoked as `[watch-remote-stt, wavpath]` with no shell, and the transcript is its only standard output. It runs `whisper-cli -m <model> -f <wav> -nt -l en -t 4`. The binary and the model file come from `WATCHREMOTE_WHISPER_CPP` and `WATCHREMOTE_WHISPER_CPP_MODEL`. When those are unset, the script uses `~/.local/bin/whisper-cli` and `~/.cache/watch-remote/ggml-base.en-q5_1.bin`.

`~/.config/watch-remote/stt.env` is optional. The unit loads it with `EnvironmentFile=-` so a missing file is not an error, and values in that file replace the unit defaults. Do not point `WATCHREMOTE_WHISPER` at `whisper-cli`. That variable is only the fallback Python `whisper` command used when `WATCHREMOTE_STT_COMMAND` is unset. `WATCHREMOTE_WHISPER_MODEL` is that fallback's model name (`tiny` by default), not a ggml path.

On the paired Linux computer:

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git curl
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
cmake -S whisper.cpp -B whisper.cpp/build -DGGML_NATIVE=ON
cmake --build whisper.cpp/build -j --config Release
install -m 755 whisper.cpp/build/bin/whisper-cli ~/.local/bin/whisper-cli
install -d -m 700 ~/.cache/watch-remote ~/.config/watch-remote
curl -L -o ~/.cache/watch-remote/ggml-base.en-q5_1.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin
install -m 755 /path/to/watch-remote/host/watch-remote-stt ~/.local/bin/watch-remote-stt
```

Leave `stt.env` absent when those two files are in the default paths. To put them somewhere else, write the absolute paths. `%h` is not expanded in this file:

```bash
printf '%s\n' \
  "WATCHREMOTE_WHISPER_CPP=${HOME}/.local/bin/whisper-cli" \
  "WATCHREMOTE_WHISPER_CPP_MODEL=${HOME}/.cache/watch-remote/ggml-base.en-q5_1.bin" \
  > ~/.config/watch-remote/stt.env
```

Copy the unit again so the `WATCHREMOTE_STT_COMMAND` line is installed, then restart the outbound service. Restarting `watch-remote-agent` does not pick this up.

```bash
cp /path/to/watch-remote/host/watch-remote-outbound.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart watch-remote-outbound.service
systemctl --user show watch-remote-outbound.service -p Environment
```

`Environment` should include `WATCHREMOTE_STT_COMMAND` ending in `watch-remote-stt`. A missing binary or model makes that command exit non-zero, and the Watch shows the error. If `WATCHREMOTE_STT_COMMAND` is unset and no `whisper` program is on `PATH`, the Watch says "No transcriber is configured on this computer." and offers Dictate. Empty audio is rejected with "Nothing was recorded."
