# Watch Remote

iPhone and Apple Watch remote for Grok Build on a computer you control. The iPhone holds an SSH connection over the private overlay and drives `grok` on that computer. The Watch uses the iPhone when it is nearby. After a pairing that includes a relay address, the Watch can also connect on its own. See [docs/outbound-relay.md](docs/outbound-relay.md).

SSH is the primary path, in the same shape as the Terminal feature in [lojo-private-networks-ios](https://github.com/macdadyj/lojo-private-networks-ios) (host list, key in the Keychain, authorize command, first-use host key). That terminal lives on branch `cursor/lojo-ssh-terminal-a06d`, not on `main`. An HTTP relay on the overlay is optional. Demo mode needs neither.

| | |
| --- | --- |
| iOS | `com.lojo.WatchRemote` |
| watchOS | `com.lojo.WatchRemote.watchkitapp` |
| Team | `DEVELOPMENT_TEAM` GitHub secret, injected when archiving |
| SSH | scan a pairing QR, or save the address, user, and port on **Computer** |
| Placeholder | `user@100.64.0.2` port `22` (not a real computer) |
| Agent server | `127.0.0.1:2419` on the computer, through an SSH local forward |

## Security

Watch Remote is a client for your own computer. The iPhone stores the SSH key and the agent secret in the Keychain, and it opens SSH only to an address in `100.64.0.0/10`. The Watch does not open SSH. If the pairing QR includes a relay address, the Watch stores that pairing in its own Keychain and opens `wss` to that address when the iPhone is away. The relay forwards ciphertext. The address is entered at pairing time. It is not in this repository. Nothing secret lives here: no SSH keys, no agent secret, no relay token, no App Store Connect key, and no personal host. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) if you want build-time placeholders. Enter the real computer in the app. The TestFlight team id comes from the `DEVELOPMENT_TEAM` secret at archive time.

## Layout

- `Core/` — shared models, overlay policy, ACP and streaming-json codecs, demo data, LOJO theme. No networking.
- `App/iOS/` — SwiftUI phone app, SSH (swift-nio-ssh), Keychain keys, WatchConnectivity.
- `App/Watch/` — SwiftUI watch app. WatchConnectivity, a direct `wss` path when a relay was paired, dictation, and the Ask Grok shortcut.
- `relay/` — optional Python HTTP relay for the iPhone (`watchremote_relay`). `relay/outbound/` is the separate ciphertext forwarder for the Watch.
- `docs/outbound-relay.md` — how to host that forwarder. This repo does not deploy it.
- `host/` — user systemd units, the agent wrapper, and `watch-remote-pair` / `watch-remote-authorize`.
- `Config/` — xcconfig placeholders. `Local.xcconfig` is gitignored.
- `docs/SETUP.md` — Apple Developer, App Store Connect, and GitHub secrets.
- `docs/HOST-SETUP.md` — sshd, the agent server, and why loopback is the bind address.
- `docs/relay-api.md` — optional relay.

## Phone

**Sessions** lists recent tasks, with status as a shape and a word. **Computer**, when nothing is paired, shows **Pair your first computer**: run `watch-remote-pair`, scan the QR from the button at the top, confirm the fingerprint, copy the authorize command, and test the connection. The banner says Not paired, Waiting for authorization, or Connected. Name, address, user, port, remove, and paste sit under **Advanced**. **Settings** chooses SSH, Relay, or Demo, the working directory, and the agent secret for the active computer.

Approvals (Allow, Deny, Stop) go through `grok agent serve` inside the SSH tunnel. If that server is not running, the phone runs headless `grok -p … --output-format streaming-json` and cannot approve a tool. Interactive TUIs already open on the computer stay untouched.

The design follows LOJO Networks: system fonts, grouped backgrounds, 18pt cards, a 0.06 hairline, and the teal `#0F8C94` / indigo `#262E78` gradient on icon tiles and primary buttons.

## Watch voice

The Watch home keeps a microphone button on screen. Tapping it starts dictation. The text is a new task for the active computer. Send and Cancel come up first. **Auto-send** skips that step. **Read results aloud** speaks the latest finished summary. Both stay off until you turn them on.

On an approval, say allow, deny, or stop. Deny and stop send immediately. Allow waits for a tap.

Siri on the Watch takes “Ask Grok to” plus the task. The task goes through the iPhone when it is nearby, and through the direct relay when it is not.

## Generate and test

```bash
brew install xcodegen
xcodegen generate
```

Pull requests on the **iOS** workflow build and test without signing, and upload the full simulator screenshot set. Pushes to `main` and manual runs upload to TestFlight in a separate job, with a short screenshot set on the other job. The steps you do by hand are in [docs/SETUP.md](docs/SETUP.md).

```bash
PYTHONPATH=relay python3 relay/tests/test_relay.py
python3 host/test_relaybox.py
python3 host/test_outbound.py
node --test relay/outbound/test.mjs
scripts/privacy-scan.sh
python3 scripts/patch-watch-embed.py --self-test
```
