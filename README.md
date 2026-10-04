# Watch Remote

iPhone and Apple Watch remote for Grok Build on a computer you control. The Watch talks to the iPhone. The iPhone holds an SSH connection over the private overlay and drives `grok` on that computer.

SSH is the primary path, in the same shape as the Terminal feature in [lojo-private-networks-ios](https://github.com/macdadyj/lojo-private-networks-ios) (host list, key in the Keychain, authorize command, first-use host key). That terminal lives on branch `cursor/lojo-ssh-terminal-a06d`, not on `main`. An HTTP relay on the overlay is optional. Demo mode needs neither.

| | |
| --- | --- |
| iOS | `com.lojo.WatchRemote` |
| watchOS | `com.lojo.WatchRemote.watchkitapp` |
| Team | `DEVELOPMENT_TEAM` GitHub secret, injected when archiving |
| SSH | the address, user, and port you save on **Computer** |
| Placeholder | `user@100.64.0.2` port `22` (not a real computer) |
| Agent server | `127.0.0.1:2419` on the computer, through an SSH local forward |

## Security

Watch Remote is a client for your own computer. The iPhone stores the SSH key and the agent secret in the Keychain, and it opens sockets only to an address in `100.64.0.0/10`. The Watch never opens that socket. Nothing secret lives in this repository: no SSH keys, no agent secret, no App Store Connect key, and no personal host. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) if you want build-time placeholders. Enter the real computer in the app. The TestFlight team id comes from the `DEVELOPMENT_TEAM` secret at archive time.

## Layout

- `Core/` — shared models, overlay policy, ACP and streaming-json codecs, demo data, LOJO theme. No networking.
- `App/iOS/` — SwiftUI phone app, SSH (swift-nio-ssh), Keychain keys, WatchConnectivity.
- `App/Watch/` — SwiftUI watch app. WatchConnectivity only.
- `relay/` — optional Python relay. Adapters: `acp`, `cli`, `mock`.
- `host/` — user systemd units and the agent wrapper.
- `Config/` — xcconfig placeholders. `Local.xcconfig` is gitignored.
- `docs/SETUP.md` — Apple Developer, App Store Connect, and GitHub secrets.
- `docs/HOST-SETUP.md` — sshd, the agent server, and why loopback is the bind address.
- `docs/relay-api.md` — optional relay.

## Phone

**Sessions** lists recent tasks, with status as a shape and a word. **Computer** is where you enter the overlay address and the iPhone key. **Settings** chooses SSH, Relay, or Demo, the working directory, and the agent secret.

Approvals (Allow, Deny, Stop) go through `grok agent serve` inside the SSH tunnel. If that server is not running, the phone runs headless `grok -p … --output-format streaming-json` and cannot approve a tool. Interactive TUIs already open on the computer stay untouched.

The design follows LOJO Networks: system fonts, grouped backgrounds, 18pt cards, a 0.06 hairline, and the teal `#0F8C94` / indigo `#262E78` gradient on icon tiles and primary buttons.

## Generate and test

```bash
brew install xcodegen
xcodegen generate
```

Pull requests on the **iOS** workflow build and test without signing, and upload the full simulator screenshot set. Pushes to `main` and manual runs upload to TestFlight in a separate job, with a short screenshot set on the other job. The steps you do by hand are in [docs/SETUP.md](docs/SETUP.md).

```bash
PYTHONPATH=relay python3 relay/tests/test_relay.py
python3 scripts/patch-watch-embed.py --self-test
```
