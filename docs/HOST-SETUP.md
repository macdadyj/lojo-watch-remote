# Computer setup

Watch Remote’s primary path is SSH to a computer you control, in the same shape as the Terminal feature in [lojo-private-networks-ios](https://github.com/macdadyj/lojo-private-networks-ios) (branch `cursor/lojo-ssh-terminal-a06d`). The iPhone holds the SSH connection. The Watch talks only to the iPhone.

The repo does not contain a real host. On the iPhone, open **Computer** and save the label, overlay address, SSH user, and port. You can also set those placeholders at build time in `Config/Local.xcconfig` (gitignored; start from `Config/Local.xcconfig.example`).

| | |
| --- | --- |
| Host | an address in `100.64.0.0/10`, for example `100.64.0.2` |
| SSH | `user@100.64.0.2` on your sshd port, key authentication |
| Agent server | `127.0.0.1:2419` on the computer, reached through an SSH direct-tcpip channel |
| Grok binary | `${GROK_BIN:-$HOME/.grok/bin/grok}` |

The phone refuses any address outside `100.64.0.0/10` before it opens a socket. `127.0.0.1` is not an SSH target. It is only the forward destination of the agent port, as seen from the computer.

## SSH

sshd should listen on the overlay only, with password authentication off. Authorize the iPhone key by running the command the app shows (or scanning its QR). Confirm the fingerprint the phone displays:

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

Paste that same secret into the iPhone’s Settings. It is stored in the Keychain. The phone sends it only as the WebSocket query inside the SSH tunnel (`/ws?server-key=…`).

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
