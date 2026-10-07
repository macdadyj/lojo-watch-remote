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
- `App/Watch/` — SwiftUI watch app. WatchConnectivity, a direct `wss` path when a relay was paired, hands-free voice, and the Ask Grok shortcut.
- `relay/` — optional Python HTTP relay for the iPhone (`watchremote_relay`). `relay/outbound/` is the separate ciphertext forwarder for the Watch.
- `docs/outbound-relay.md` — how to host that forwarder. This repo does not deploy it.
- `host/` — user systemd units, the agent wrapper, and `watch-remote-pair` / `watch-remote-authorize`.
- `Config/` — xcconfig placeholders. `Local.xcconfig` is gitignored.
- `docs/SETUP.md` — Apple Developer, App Store Connect, and GitHub secrets.
- `docs/HOST-SETUP.md` — sshd, the agent server, and why loopback is the bind address.
- `docs/relay-api.md` — optional relay.

## Phone

**Sessions** lists recent tasks, with status as a shape and a word. **Computer**, when nothing is paired, shows **Pair your first computer**: on the computer, run your pair command (see host setup), scan the QR from the button at the top, and confirm the computer. The script in this repository is `watch-remote-pair`. An alias on that computer runs the same script. The computer authorizes the iPhone while that window stays open. The banner says Not paired, Waiting for authorization, or Connected. Name, address, user, port, remove, paste, and the manual authorize command sit under **Advanced**. **Settings** chooses SSH, Relay, or Demo, the working directory, and the agent secret for the active computer.

Approvals (Allow, Deny, Stop) go through the agent server inside the SSH tunnel. The phone key can only forward to `127.0.0.1:2419`. It cannot run a command. If `grok agent serve` is down, the computer runs headless `grok -p` itself and tasks cannot ask for approval. Interactive TUIs already open on the computer stay untouched.

The design follows LOJO Networks: system fonts, grouped backgrounds, 18pt cards, a 0.06 hairline, and the teal `#0F8C94` / indigo `#262E78` gradient on icon tiles and primary buttons.

## Watch voice

Tap **Speak** once. It is a short control under the session list, so history stays on screen. The Watch listens with its microphone and sends the utterance when you pause (about 1.5 seconds of silence), and never listens longer than 12 seconds. There is no Done button on that path. The conversation keeps that history, **I'm done**, and **New task** on screen. **I'm done** stops the microphone, sends what you already said, and leaves the chat open. The Watch speaks the reply, then listens again, so a follow-up, an approval, or the next command stays in the same conversation.

Say allow. The Watch reads the action back and asks you to say yes. Say yes or confirm to approve. Deny and stop send on the first word. List sessions, status, stop session, and switch computer work in the same conversation. Allow, Deny, and Stop stay on the task screen if you would rather tap. Yes stays on screen during the confirm step for the same reason.

The Watch does not transcribe on watchOS. `SFSpeechRecognizer` and `SpeechAnalyzer` / `SpeechTranscriber` are not available there (WWDC25: every platform except watchOS). When the iPhone app is reachable, it turns the audio into text. On-device recognition is used when the iPhone supports it. When the iPhone is away and the Watch is paired, the recording goes to the computer over the direct relay. Set `WATCHREMOTE_STT_COMMAND` to a program that reads a wav path and prints text, or install `whisper` (model `WATCHREMOTE_WHISPER_MODEL`, default `tiny`). The first time, the Watch asks for the microphone and the iPhone asks for speech recognition. Those system prompts do not repeat after you allow them. Dictation is the last resort: no pairing, or the microphone cannot be used. That sheet still needs Done. A reachable iPhone does not open that sheet. A missing microphone, or a computer with no transcriber configured, shows **Dictate** on the conversation screen instead of covering history.

A new approval, while the Watch app is open, is read aloud and the microphone opens for the spoken answer. **Read results aloud** stays off until you turn it on, and then it also speaks results outside a conversation. **New task** still uses the dictation sheet and sends when you tap Start. Siri on the Watch takes “Ask Grok”, then asks what to do. A free-form task cannot sit inside the shortcut phrase.

How to test this without tapping through every prompt is in [docs/VOICE.md](docs/VOICE.md).

## Generate and test

```bash
brew install xcodegen
xcodegen generate
```

Pull requests on the **iOS** workflow build and test without signing, and upload the full simulator screenshot set. The **watch-ui** job taps through the Watch app on a 41/42 mm simulator and a 45/49 mm simulator. Pushes to `main` and manual runs upload to TestFlight only after that job passes. The steps you do by hand are in [docs/SETUP.md](docs/SETUP.md). The simulator chain is described in [docs/WATCH-UI-TESTS.md](docs/WATCH-UI-TESTS.md).

```bash
PYTHONPATH=relay python3 relay/tests/test_relay.py
python3 host/test_relaybox.py
python3 host/test_outbound.py
node --test relay/outbound/test.mjs
scripts/privacy-scan.sh
python3 scripts/patch-watch-embed.py --self-test
```
