# Computer setup

Watch Remote’s primary path is SSH to a computer you control, in the same shape as the Terminal feature in [lojo-private-networks-ios](https://github.com/macdadyj/lojo-private-networks-ios) (branch `cursor/lojo-ssh-terminal-a06d`). The iPhone holds the SSH connection. The Watch talks only to the iPhone.

The repo does not contain a real host. Pair a computer by scanning one QR from that computer. You can still type the fields on **Computer**, and you can keep several saved computers and switch the active one. The Watch shows the active computer and can switch when more than one is saved. Placeholders at build time live in `Config/Local.xcconfig` (gitignored; start from `Config/Local.xcconfig.example`).

| | |
| --- | --- |
| Host | an address in `100.64.0.0/10`, for example `100.64.0.2` |
| SSH | `user@100.64.0.2` on your sshd port, key authentication |
| Agent server | `127.0.0.1:2419` on the computer, reached through an SSH direct-tcpip channel |
| Grok binary | `${GROK_BIN:-$HOME/.grok/bin/grok}` |

The phone refuses any address outside `100.64.0.0/10` before it opens a socket, including an address inside a pairing code. `127.0.0.1` is not an SSH target. It is only the forward destination of the agent port, as seen from the computer.

## Pair in one scan

On the computer, install the scripts (python3 is required; `qrencode` is optional):

```bash
install -d -m 755 ~/.local/bin
install -m 755 /path/to/watch-remote/host/watch-remote-pair ~/.local/bin/watch-remote-pair
install -m 755 /path/to/watch-remote/host/watch-remote-authorize ~/.local/bin/watch-remote-authorize
install -m 644 /path/to/watch-remote/host/pairing.py /path/to/watch-remote/host/qrcodegen.py ~/.local/bin/
```

`watch-remote-pair` reads the overlay address (the first address in `100.64.0.0/10`, or `~/.config/watch-remote/address`, or `--address`), the SSH user, the sshd port, the SSH host key fingerprint, and the agent secret from `~/.config/watch-remote/agent-secret`. It prints a QR and the `watchremote://pair?d=…` text. The QR is drawn with `qrencode` when that program is installed, and with the built-in generator otherwise (`host/qrcodegen.py`, MIT, Project Nayuki).

```bash
watch-remote-pair --address 100.64.0.2
```

The QR contains the agent secret when that file exists. Scan it once with the iPhone’s **Computer** screen. Do not share it, copy it into chat, or take a screenshot. The phone fills the label, address, user, and port, stores the secret in the Keychain, and pins the host key fingerprint when the code includes one. It still shows that fingerprint for you to confirm, and the first SSH connection asks again before the key is trusted. A later key that does not match the pin is refused.

Then generate a key on the iPhone if you have not. The app shows the public key as a QR and as text. On the computer, as that SSH user:

```bash
watch-remote-authorize 'ssh-ed25519 AAAA… watch-remote@iphone'
```

That appends one line to `~/.ssh/authorized_keys`:

```text
restrict,port-forwarding,permitopen="127.0.0.1:2419" ssh-ed25519 AAAA… watch-remote@iphone
```

Running it again does not add a second line. It does not print or store a private key. `restrict` turns off forwarding, a PTY, and `~/.ssh/rc`. `port-forwarding` turns local and remote forwarding back on, and `permitopen` limits the local forward to the agent server. Shell exec still works, which is how the phone runs `grok` when the agent server is down.

You can save more than one computer. **Add computer**, **Scan pairing QR**, and **Paste pairing code** are on the iPhone. Rename with the name field and **Save computer**. **Remove this computer** drops that entry, its Keychain secret, and its saved host key. The Watch lists the computers when there are two or more.

## SSH

sshd should listen on the overlay only, with password authentication off. Use a drop-in so this user can forward only to the agent port. The `Match` block applies to the rest of the file, so name it to sort last and keep it last. Replace `user` with the SSH user:

```text
# /etc/ssh/sshd_config.d/zz-watch-remote.conf
Match User user
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:2419
    AllowAgentForwarding no
    X11Forwarding no
    AllowStreamLocalForwarding no
    GatewayPorts no
```

`AllowTcpForwarding local` allows the direct-tcpip channel the phone opens and refuses remote forwards. `PermitOpen` limits that channel to `127.0.0.1:2419`. Check the file, then reload sshd the way this host usually does:

```bash
sshd -t
```

Authorize the iPhone key with `watch-remote-authorize`, shown above. Confirm the fingerprint the phone displays:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Use whichever host key sshd actually presents.

## Agent server

`grok agent serve` is an ACP WebSocket on the computer’s loopback. Binding loopback is the recommendation: SSH is the only way in, and the agent secret never travels on the overlay by itself. Bind an overlay address only if you want a client to speak ACP without SSH. Do not bind `0.0.0.0`. Do not pass `--always-approve`. Do not pass `--secret` on the command line. When `--secret` is omitted, Grok reads `GROK_AGENT_SECRET` from the environment.

```bash
install -d -m 700 ~/.config/watch-remote ~/.local/bin
umask 077
# Write a long random secret. This file is not in git.
printf '%s' "$(openssl rand -hex 32)" > ~/.config/watch-remote/agent-secret
install -m 755 /path/to/watch-remote/host/watch-remote-agent ~/.local/bin/watch-remote-agent
mkdir -p ~/.config/systemd/user
cp /path/to/watch-remote/host/watch-remote-agent.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now watch-remote-agent.service
loginctl enable-linger "$USER"
```

`watch-remote-pair` reads this file into the QR. If you type the computer in by hand instead, paste the same secret into the iPhone’s Settings for that computer. It is stored in the Keychain. The phone sends it only as the WebSocket query inside the SSH tunnel (`/ws?server-key=…`).

Check that nothing is published on the overlay:

```bash
ss -ltnp | grep 2419
```

You want `127.0.0.1:2419`, not an overlay address and not `0.0.0.0:2419`.

## What the phone runs

When the agent server answers, the phone speaks ACP: `initialize`, `session/new`, `session/prompt`, `session/cancel`, and `x.ai/session/list`. Permission requests are answered on that same connection. `yoloMode` and `autoMode` are sent as false.

If the agent server is down, or the secret is not saved, the phone falls back to one-shot commands over SSH exec:

```bash
grok -p '<prompt>' --cwd '<dir>' --output-format streaming-json --no-auto-update --permission-mode dontAsk
grok sessions list
grok usage <session-id>
```

`--permission-mode dontAsk` is there so a missing TTY cannot hang and cannot auto-approve. This fallback cannot approve or deny a tool. Kill the exec channel to stop it. `grok sessions list` prints a human table for the current directory (the phone `cd`s first). If you have a sample of that table and the columns differ from what the phone parses, the parser in `GrokOutput` is the place to tighten.

Interactive `grok` TUIs already running on the computer are not remote-controllable. The Watch starts sessions through the agent server, or through the headless command above.

Your Grok login stays in `~/.grok` on the computer. The phone never reads it.

## Optional relay

The HTTP relay is a second path. Leave Settings on **SSH** unless you want it. Setup for the relay is in [relay-api.md](relay-api.md). Its unit is `host/watch-remote-relay.service`. `WATCHREMOTE_RELAY_BIND` has no default. Set it in `relay.env` to an address in `100.64.0.0/10`, or to `127.0.0.1` for a local process. Public addresses are refused.
