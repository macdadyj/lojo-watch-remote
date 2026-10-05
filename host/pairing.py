#!/usr/bin/env python3
"""Pairing payload and authorized_keys helper for Watch Remote.

The QR and the URL can contain an agent secret. Print the warning, scan once,
and do not share the code. This file uses placeholders in its self-test only.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

import qrcodegen  # noqa: E402

VERSION = 1
URL_PREFIX = "watchremote://pair?d="
OVERLAY_NETWORK = (100 << 24) | (64 << 16)
OVERLAY_PREFIX = 10
AGENT_PORT = "127.0.0.1:2419"
# restrict drops PTY, agent forwarding, and user rc. port-forwarding turns the
# forward back on, and permitopen keeps it on the agent port. command and no-pty
# refuse ssh host '<cmd>' so this key can only open that forward.
AUTHORIZE_OPTIONS = f'restrict,port-forwarding,permitopen="{AGENT_PORT}",command="/bin/false",no-pty'
KEY_RE = re.compile(
    r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|"
    r"sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)"
    r"[ \t]+([A-Za-z0-9+/=]+)"
    r"(?:[ \t]+([A-Za-z0-9@._+-]+))?"
)
USER_RE = re.compile(r"[A-Za-z0-9._-]{1,32}$")
FINGERPRINT_BODY = re.compile(r"[A-Za-z0-9+/]{43}$")
TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{16,128}$")


class PairingError(ValueError):
    pass


def in_overlay(address: str) -> bool:
    return canonical_address(address) is not None


def canonical_address(address: str) -> str | None:
    text = address.strip()
    parts = text.split(".")
    if len(parts) != 4:
        return None
    numbers: list[int] = []
    for part in parts:
        if not part.isdigit() or not 1 <= len(part) <= 3:
            return None
        if len(part) > 1 and part.startswith("0"):
            return None
        number = int(part)
        if number > 255:
            return None
        numbers.append(number)
    value = (numbers[0] << 24) | (numbers[1] << 16) | (numbers[2] << 8) | numbers[3]
    mask = (0xFFFFFFFF << (32 - OVERLAY_PREFIX)) & 0xFFFFFFFF
    if (value & mask) != (OVERLAY_NETWORK & mask):
        return None
    return ".".join(str(number) for number in numbers)


def normalize_fingerprint(text: str) -> str | None:
    trimmed = text.strip()
    if not trimmed.lower().startswith("sha256:"):
        return None
    body = trimmed[7:].replace("=", "")
    if FINGERPRINT_BODY.fullmatch(body) is None:
        return None
    return "SHA256:" + body


def normalize_secret(secret: str | None) -> str | None:
    if secret is None:
        return None
    trimmed = secret.strip()
    if not trimmed:
        return None
    if not 8 <= len(trimmed) <= 128:
        raise PairingError("The agent secret in the pairing code is not usable.")
    if any(ord(char) < 0x21 or ord(char) > 0x7E for char in trimmed):
        raise PairingError("The agent secret in the pairing code is not usable.")
    return trimmed


def normalize_relay_url(text: str) -> str | None:
    trimmed = text.strip()
    if not 12 <= len(trimmed) <= 300 or any(char.isspace() for char in trimmed):
        return None
    parts = urlsplit(trimmed)
    if parts.scheme.lower() != "wss" or not parts.hostname:
        return None
    if parts.username or parts.password or parts.query or parts.fragment:
        return None
    if len(parts.hostname) > 253:
        return None
    return trimmed


def normalize_token(text: str) -> str | None:
    trimmed = text.strip()
    if TOKEN_RE.fullmatch(trimmed) is None:
        return None
    return trimmed


def normalize_e2e(text: str) -> str | None:
    trimmed = text.strip().replace("=", "")
    if not trimmed or any(char.isspace() for char in trimmed):
        return None
    padding = "=" * ((4 - len(trimmed) % 4) % 4)
    try:
        data = base64.urlsafe_b64decode(trimmed + padding)
    except Exception:
        return None
    if len(data) != 32:
        return None
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def normalize_label(label: str) -> str:
    trimmed = label.strip()
    if not trimmed:
        return "example-host"
    if len(trimmed) > 64 or any(ord(char) < 0x20 or ord(char) == 0x7F for char in trimmed):
        raise PairingError("The pairing code has a label Watch Remote cannot use.")
    return trimmed


def direct_fields(relay: str | None, token: str | None, e2e: str | None) -> dict:
    relay_text = (relay or "").strip()
    token_text = (token or "").strip()
    key_text = (e2e or "").strip()
    if not relay_text and not token_text and not key_text:
        return {}
    url = normalize_relay_url(relay_text)
    if url is None:
        raise PairingError("The direct relay address in the pairing code is not a wss address.")
    room = normalize_token(token_text)
    if room is None:
        raise PairingError("The direct relay token in the pairing code is not usable.")
    key = normalize_e2e(key_text)
    if key is None:
        raise PairingError("The direct connection key in the pairing code is not usable.")
    return {"e2e": key, "relay": url, "token": room}


def build_payload(
    label: str,
    address: str,
    user: str,
    port: int,
    secret: str | None = None,
    fingerprint: str | None = None,
    relay: str | None = None,
    token: str | None = None,
    e2e: str | None = None,
    ticket: str | None = None,
    enroll: int | None = None,
) -> dict:
    if not USER_RE.fullmatch(user.strip() if isinstance(user, str) else ""):
        raise PairingError("The pairing code has an SSH user Watch Remote cannot use.")
    canonical = canonical_address(address)
    if canonical is None:
        raise PairingError("That address is outside the private overlay.")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise PairingError("The pairing code has a port Watch Remote cannot use.")
    resolved_fingerprint = None
    if fingerprint is not None and fingerprint.strip():
        resolved_fingerprint = normalize_fingerprint(fingerprint)
        if resolved_fingerprint is None:
            raise PairingError("The host key fingerprint in the pairing code is not a SHA256 fingerprint.")
    payload = {
        "v": VERSION,
        "label": normalize_label(label),
        "address": canonical,
        "user": user.strip(),
        "port": port,
    }
    resolved_secret = normalize_secret(secret)
    if resolved_secret is not None:
        payload["secret"] = resolved_secret
    if resolved_fingerprint is not None:
        payload["fingerprint"] = resolved_fingerprint
    payload.update(direct_fields(relay, token, e2e))
    attach_enroll(payload, ticket, enroll)
    return payload


def attach_enroll(payload: dict, ticket: str | None, enroll: int | None) -> None:
    ticket_text = ticket.strip() if isinstance(ticket, str) else ""
    if not ticket_text and enroll is None:
        return
    room = normalize_token(ticket_text)
    if room is None:
        raise PairingError("The one-time pairing ticket is not usable.")
    if isinstance(enroll, bool):
        raise PairingError("The pairing channel port is not usable.")
    port = 2478 if enroll is None else enroll
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise PairingError("The pairing channel port is not usable.")
    payload["ticket"] = room
    payload["enroll"] = port


def dumps_payload(payload: dict) -> str:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)


def token_for(payload: dict) -> str:
    raw = dumps_payload(payload).encode("utf-8")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def url_for(payload: dict) -> str:
    return URL_PREFIX + token_for(payload)


def decode_text(text: str) -> dict:
    trimmed = text.strip()
    if len(trimmed) >= 2 and trimmed[0] == trimmed[-1] and trimmed[0] in {"'", '"'}:
        trimmed = trimmed[1:-1].strip()
    if not trimmed:
        raise PairingError("Paste the pairing text from the computer.")
    if len(trimmed) > 8192:
        raise PairingError("That pairing code is too large.")
    if trimmed.startswith("{"):
        data = trimmed.encode("utf-8")
    else:
        token = token_text(trimmed)
        padding = "=" * ((4 - len(token) % 4) % 4)
        try:
            data = base64.urlsafe_b64decode(token + padding)
        except Exception as error:
            raise PairingError("That pairing code could not be read.") from error
    try:
        raw = json.loads(data)
    except json.JSONDecodeError as error:
        raise PairingError("That pairing code could not be read.") from error
    if not isinstance(raw, dict):
        raise PairingError("That pairing code could not be read.")
    version = raw.get("v")
    if version != VERSION:
        raise PairingError("This pairing code is from a newer Watch Remote. Update the app.")
    try:
        port = raw["port"]
        if isinstance(port, str) and port.isdigit():
            port = int(port)
        return build_payload(
            str(raw.get("label", "")),
            str(raw.get("address", "")),
            str(raw.get("user", "")),
            port,
            raw.get("secret") if isinstance(raw.get("secret"), str) else None,
            raw.get("fingerprint") if isinstance(raw.get("fingerprint"), str) else None,
            raw.get("relay") if isinstance(raw.get("relay"), str) else None,
            raw.get("token") if isinstance(raw.get("token"), str) else None,
            raw.get("e2e") if isinstance(raw.get("e2e"), str) else None,
            raw.get("ticket") if isinstance(raw.get("ticket"), str) else None,
            enroll_port(raw.get("enroll")),
        )
    except KeyError as error:
        raise PairingError("That pairing code could not be read.") from error
    except TypeError as error:
        raise PairingError("That pairing code could not be read.") from error


def token_text(text: str) -> str:
    if not text.lower().startswith("watchremote://"):
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,8192}", text):
            raise PairingError("That pairing code could not be read.")
        return text
    marker = "d="
    index = text.find(marker)
    if index < 0:
        raise PairingError("That pairing code could not be read.")
    token = text[index + len(marker):]
    cut = len(token)
    for separator in ("&", " ", "\n", "#"):
        found = token.find(separator)
        if found >= 0:
            cut = min(cut, found)
    token = token[:cut]
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,8192}", token):
        raise PairingError("That pairing code could not be read.")
    return token


def enroll_port(value: object) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise PairingError("The pairing channel port is not usable.")
    return value


def summary_lines(payload: dict) -> list[str]:
    lines = [
        f"{payload['label']} · {payload['user']}@{payload['address']}:{payload['port']}",
    ]
    fingerprint = payload.get("fingerprint")
    if fingerprint:
        lines.append(f"Host key {fingerprint}")
    if "secret" in payload:
        lines.append("Agent secret included.")
    else:
        lines.append("No agent secret in this code.")
    if "relay" in payload:
        lines.append("Direct connection included.")
    else:
        lines.append("No direct connection in this code.")
    if "ticket" in payload:
        lines.append("This iPhone can authorize itself.")
    return lines


def warning_text(has_secret: bool, has_direct: bool = False, has_ticket: bool = False) -> str:
    pieces = []
    if has_secret:
        pieces.append("the agent secret")
    if has_direct:
        pieces.append("the direct-connection key")
    if has_ticket:
        pieces.append("a one-time pairing ticket that expires in 10 minutes")
    if pieces:
        if len(pieces) == 1:
            what = pieces[0]
        elif len(pieces) == 2:
            what = f"{pieces[0]} and {pieces[1]}"
        else:
            what = f"{pieces[0]}, {pieces[1]}, and {pieces[2]}"
        return (
            f"WARNING: This QR contains {what}. "
            "Scan it once with Watch Remote on the iPhone. "
            "Do not share it, copy it into chat, or take a screenshot."
        )
    return (
        "This QR does not include an agent secret. "
        "Save the secret from the computer in iPhone Settings after pairing, "
        "or create ~/.config/watch-remote/agent-secret and run this again."
    )


def write_outbound_file(relay: str, token: str, e2e: str, directory: Path | None = None) -> Path:
    root = directory or (Path.home() / ".config" / "watch-remote")
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    path = root / "outbound.json"
    body = json.dumps({"e2e": e2e, "relay": relay, "token": token}, separators=(",", ":"), sort_keys=True)
    temporary = path.with_name("outbound.json.tmp")
    temporary.write_text(body, encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, path)
    path.chmod(0o600)
    counters = root / "outbound-counters.json"
    counters.write_text('{"recv":0,"send":0}', encoding="utf-8")
    counters.chmod(0o600)
    return path


def new_direct_material(relay_url: str) -> tuple[str, str, str]:
    relay = normalize_relay_url(relay_url)
    if relay is None:
        raise PairingError("Pass a wss relay URL with no token in the URL. The token is generated here.")
    token = secrets.token_urlsafe(32)
    e2e = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
    return relay, token, e2e


def authorize_hint() -> str:
    return (
        "Leave this window open. On the iPhone, open Computer and scan the QR.\n"
        "Confirm the computer. This window adds the iPhone key and then exits.\n"
        "The ticket works once and expires in 10 minutes.\n"
        "If it expires, use Advanced on the iPhone and run watch-remote-authorize with the public key."
    )


def render_qr(text: str) -> str:
    qr = qrcodegen.QrCode.encode_text(text, qrcodegen.QrCode.Ecc.MEDIUM)
    border = 4
    size = qr.get_size()

    def dark(x: int, y: int) -> bool:
        return 0 <= x < size and 0 <= y < size and qr.get_module(x, y)

    lines = []
    for y in range(-border, size + border, 2):
        row = []
        for x in range(-border, size + border):
            top = dark(x, y)
            bottom = dark(x, y + 1)
            if top and bottom:
                row.append("█")
            elif top:
                row.append("▀")
            elif bottom:
                row.append("▄")
            else:
                row.append(" ")
        lines.append("".join(row))
    body = "\n".join(lines)
    return "\033[30;47m" + body + "\033[0m"


def emit_qr(text: str) -> None:
    qrencode = shutil.which("qrencode")
    if qrencode:
        result = subprocess.run(
            [qrencode, "-t", "ANSIUTF8", "-m", "4", "-l", "M", "-o", "-"],
            input=text.encode("utf-8"),
            check=False,
        )
        if result.returncode == 0:
            return
    print(render_qr(text))


def parse_public_key(text: str) -> str:
    if "PRIVATE KEY" in text or "-----BEGIN" in text:
        raise PairingError("Pass the public key, not a private key.")
    match = KEY_RE.search(text)
    if match is None:
        raise PairingError("Pass an OpenSSH public key.")
    key_type, blob, comment = match.group(1), match.group(2), match.group(3)
    if comment is None:
        comment = "watch-remote@iphone"
    return f"{key_type} {blob} {comment}"


def exec_is_refused(line: str) -> bool:
    """True when this authorized_keys line cannot run a command supplied by the client."""
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return False
    options = stripped.split(None, 1)[0]
    parts = options.split(",")
    required = (
        "restrict",
        "port-forwarding",
        'permitopen="127.0.0.1:2419"',
        'command="/bin/false"',
        "no-pty",
    )
    return all(part in parts for part in required)


def authorize_key(text: str, path: Path) -> str:
    key = parse_public_key(text)
    blob = key.split()[1]
    line = f"{AUTHORIZE_OPTIONS} {key}"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    rows = existing.splitlines()
    wrote = False
    updated: list[str] = []
    for row in rows:
        tokens = row.split()
        if blob in tokens:
            if not wrote:
                updated.append(line)
                wrote = True
            continue
        updated.append(row)
    if not wrote:
        updated.append(line)
    body = "\n".join(updated).rstrip() + "\n"
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(body, encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, path)
    path.chmod(0o600)
    return "Authorized the Watch Remote key for local forwarding to 127.0.0.1:2419."


def addresses_in(text: str) -> list[str]:
    found: list[str] = []
    for match in re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", text):
        canonical = canonical_address(match)
        if canonical and canonical not in found:
            found.append(canonical)
    return found


def port_from_config(text: str) -> int | None:
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.lower().startswith("match "):
            break
        parts = stripped.split()
        if len(parts) == 2 and parts[0].lower() == "port" and parts[1].isdigit():
            port = int(parts[1])
            if 1 <= port <= 65535:
                return port
    return None


def fingerprint_from_ssh_keygen(text: str) -> str | None:
    parts = text.split()
    if len(parts) < 2:
        return None
    return normalize_fingerprint(parts[1])


def read_secret_file(path: Path) -> tuple[str | None, str | None]:
    if not path.is_file():
        return None, None
    mode = path.stat().st_mode
    warning = None
    if mode & 0o077:
        warning = f"{path} is readable by other users. Run chmod 600 on it."
    secret = path.read_text(encoding="utf-8").strip()
    if not secret:
        return None, "Agent secret file is empty."
    return secret, warning


def local_overlay_addresses() -> list[str]:
    chunks: list[str] = []
    for command in (["ip", "-4", "-o", "addr", "show"], ["hostname", "-I"], ["ifconfig"]):
        try:
            chunks.append(subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL))
        except (OSError, subprocess.CalledProcessError):
            continue
    return addresses_in("\n".join(chunks))


def sshd_port() -> int:
    override = os.environ.get("WATCHREMOTE_PORT", "").strip()
    if override.isdigit() and 1 <= int(override) <= 65535:
        return int(override)
    try:
        output = subprocess.check_output(["sshd", "-T"], text=True, stderr=subprocess.DEVNULL)
        for line in output.splitlines():
            if line.lower().startswith("port "):
                port = int(line.split()[1])
                if 1 <= port <= 65535:
                    return port
    except (OSError, subprocess.CalledProcessError, IndexError, ValueError):
        pass
    config = Path("/etc/ssh/sshd_config")
    if config.is_file():
        try:
            found = port_from_config(config.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            found = None
        if found is not None:
            return found
    return 22


def host_fingerprint() -> str | None:
    override = os.environ.get("WATCHREMOTE_HOSTKEY_FINGERPRINT", "").strip()
    if override:
        return normalize_fingerprint(override)
    candidates: list[str] = []
    try:
        output = subprocess.check_output(["sshd", "-T"], text=True, stderr=subprocess.DEVNULL)
        for line in output.splitlines():
            if line.lower().startswith("hostkey "):
                candidates.append(line.split()[1])
    except (OSError, subprocess.CalledProcessError, IndexError):
        pass
    candidates.extend(
        [
            "/etc/ssh/ssh_host_ed25519_key",
            "/etc/ssh/ssh_host_ecdsa_key",
            "/etc/ssh/ssh_host_rsa_key",
        ]
    )
    for key in candidates:
        pub = key if key.endswith(".pub") else key + ".pub"
        target = pub if os.path.exists(pub) else key
        if not os.path.exists(target):
            continue
        try:
            output = subprocess.check_output(["ssh-keygen", "-lf", target], text=True, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            continue
        fingerprint = fingerprint_from_ssh_keygen(output)
        if fingerprint:
            return fingerprint
    return None


def resolve_address(explicit: str | None) -> str:
    if explicit:
        canonical = canonical_address(explicit)
        if canonical is None:
            raise PairingError("That address is outside the private overlay.")
        return canonical
    env = os.environ.get("WATCHREMOTE_ADDRESS", "").strip()
    if env:
        canonical = canonical_address(env)
        if canonical is None:
            raise PairingError("WATCHREMOTE_ADDRESS is outside the private overlay.")
        return canonical
    config = Path.home() / ".config" / "watch-remote" / "address"
    if config.is_file():
        canonical = canonical_address(config.read_text(encoding="utf-8"))
        if canonical is None:
            raise PairingError(f"{config} is not an address in 100.64.0.0/10.")
        return canonical
    found = local_overlay_addresses()
    if len(found) == 1:
        return found[0]
    if len(found) > 1:
        raise PairingError("More than one overlay address is on this computer. Pass --address.")
    raise PairingError("No overlay address found. Pass --address 100.64.0.2")


def sanitized_label(explicit: str | None) -> str:
    raw = explicit or os.environ.get("WATCHREMOTE_LABEL", "").strip()
    if not raw:
        raw = os.uname().nodename.split(".")[0]
    cleaned = "".join(char if char.isascii() and (char.isalnum() or char in " ._-") else "-" for char in raw)
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip(" -")
    if not cleaned:
        cleaned = "example-host"
    return normalize_label(cleaned[:64])


def command_pair(args: argparse.Namespace) -> int:
    address = resolve_address(args.address)
    user = (args.user or os.environ.get("WATCHREMOTE_USER") or os.environ.get("USER") or "user").strip()
    port = args.port if args.port is not None else sshd_port()
    secret_path = Path(args.secret_file).expanduser() if args.secret_file else Path.home() / ".config" / "watch-remote" / "agent-secret"
    secret, secret_warning = read_secret_file(secret_path)
    if secret_warning and secret is None and secret_path.is_file():
        print(secret_warning, file=sys.stderr)
        return 1
    relay_arg = (args.relay_url or os.environ.get("WATCHREMOTE_RELAY_URL") or "").strip()
    relay = token = e2e = None
    if relay_arg:
        relay, token, e2e = new_direct_material(relay_arg)
        write_outbound_file(relay, token, e2e)
    # enroll imports this module, so it is loaded here to avoid a cycle at import time.
    import enroll

    ticket = secrets.token_urlsafe(32)
    payload = build_payload(
        label=sanitized_label(args.label),
        address=address,
        user=user,
        port=port,
        secret=secret,
        fingerprint=host_fingerprint(),
        relay=relay,
        token=token,
        e2e=e2e,
        ticket=ticket,
        enroll=enroll.DEFAULT_PORT,
    )
    url = url_for(payload)
    print(warning_text("secret" in payload, "relay" in payload, "ticket" in payload))
    print()
    if secret_warning:
        print(secret_warning)
        print()
    emit_qr(url)
    print()
    print(url)
    print()
    for line in summary_lines(payload):
        print(line)
    print()
    print(authorize_hint())
    if "relay" in payload:
        print()
        print("Direct connection included. Restart watch-remote-outbound so the Watch can connect without the iPhone.")
    print()
    keys = Path(args.authorized_keys).expanduser() if getattr(args, "authorized_keys", None) else Path.home() / ".ssh" / "authorized_keys"
    try:
        result = enroll.serve_enroll(address, enroll.DEFAULT_PORT, ticket, keys)
    except OSError:
        print("The pairing channel could not listen. Use Advanced on the iPhone and watch-remote-authorize.", file=sys.stderr)
        return 0
    except enroll.EnrollError as error:
        print(str(error), file=sys.stderr)
        return 1
    if result == "enrolled":
        print("This iPhone is authorized. You can close this window.")
        return 0
    print("The iPhone did not finish. Use Advanced on the iPhone and watch-remote-authorize.")
    return 0


def command_authorize(args: argparse.Namespace) -> int:
    text = " ".join(args.pubkey).strip()
    if not text:
        print("usage: watch-remote-authorize <public-key>", file=sys.stderr)
        return 2
    path = Path(args.authorized_keys).expanduser() if args.authorized_keys else Path.home() / ".ssh" / "authorized_keys"
    try:
        print(authorize_key(text, path))
    except PairingError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="watch-remote-pair")
    sub = parser.add_subparsers(dest="command")

    pair = sub.add_parser("pair")
    pair.add_argument("--address")
    pair.add_argument("--user")
    pair.add_argument("--port", type=int)
    pair.add_argument("--label")
    pair.add_argument("--secret-file")
    pair.add_argument("--relay-url", help="wss address of your outbound relay. There is no default.")
    pair.add_argument("--authorized-keys")
    pair.set_defaults(func=command_pair)

    authorize = sub.add_parser("authorize")
    authorize.add_argument("pubkey", nargs="*")
    authorize.add_argument("--authorized-keys")
    authorize.set_defaults(func=command_authorize)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        parser.print_help(sys.stderr)
        return 2
    try:
        return args.func(args)
    except PairingError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
