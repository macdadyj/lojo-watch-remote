#!/usr/bin/env python3
"""Loopback door in front of the Grok agent.

The phone key can only forward to 127.0.0.1:2419. This process is what listens
there. It checks the agent secret from the Authorization header, then either
proxies to ``grok agent serve`` or runs headless ``grok -p`` on this computer.
It never asks SSH to execute a command, and it never puts the secret in a URL.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import queue
import select
import socket
import subprocess
import threading
from pathlib import Path

AGENT_DOWN = "The agent server on this computer is not answering."
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
HANDSHAKE_LIMIT = 8192


class DoorError(Exception):
    pass


def resolve_cwd(cwd: str, home: Path | None = None) -> str:
    root = home or Path.home()
    text = cwd.strip()
    if not text or text == "~":
        return str(root)
    if text.startswith("~/"):
        return str(root / text[2:])
    if text.startswith("/"):
        return text
    return str(root / text)


def grok_binary() -> str:
    override = os.environ.get("GROK_BIN", "").strip()
    if override:
        return override
    home = Path.home() / ".grok" / "bin" / "grok"
    if home.is_file() and os.access(home, os.X_OK):
        return str(home)
    return "grok"


def headless_argv(binary: str, prompt: str, cwd: str, resume: str | None) -> list[str]:
    argv = [
        binary,
        "-p",
        prompt,
        "--output-format",
        "streaming-json",
        "--no-auto-update",
        "--permission-mode",
        "dontAsk",
    ]
    if cwd:
        argv.extend(["--cwd", cwd])
    if resume:
        argv.extend(["-r", resume])
    return argv


def child_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("GROK_AGENT_SECRET", None)
    return env


def _bearer(header: str) -> str | None:
    try:
        text = header.strip()
        if len(text) < 7 or text[:7].lower() != "bearer ":
            return None
        token = text[7:].strip()
        if not token or not token.isascii():
            return None
        if any(ord(char) < 0x21 or ord(char) > 0x7E for char in token):
            return None
        return token
    except (UnicodeError, ValueError, AttributeError):
        return None


def authorized(headers: dict[str, str], secret: str) -> bool:
    try:
        presented = _bearer(headers.get("authorization", ""))
        if presented is None or not secret.isascii():
            return False
        return hmac.compare_digest(presented, secret)
    except (TypeError, ValueError, UnicodeError):
        return False


def serve(
    secret: str,
    host: str,
    port: int,
    upstream: tuple[str, int] | None,
    ready: threading.Event,
    stop: threading.Event,
    binary: str | None = None,
) -> None:
    if host not in {"127.0.0.1", "localhost"}:
        raise DoorError("The agent door only listens on loopback.")
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, port))
    listener.listen(8)
    listener.settimeout(0.5)
    program = binary or grok_binary()
    ready.set()
    try:
        while not stop.is_set():
            try:
                client, _address = listener.accept()
            except TimeoutError:
                continue
            threading.Thread(
                target=_client,
                args=(client, secret, upstream, program),
                daemon=True,
            ).start()
    finally:
        listener.close()


def _client(client: socket.socket, secret: str, upstream: tuple[str, int] | None, binary: str) -> None:
    try:
        client.settimeout(10)
        header = _read_header(client)
        if header is None:
            _reject(client)
            return
        request, headers = header
        parts = request.split(" ")
        if len(parts) < 2 or parts[0] != "GET":
            _reject(client)
            return
        target = parts[1]
        path, _sep, _query = target.partition("?")
        # A query can land in a proxy log. Refuse it instead of reading a secret from it.
        if path != "/ws" or _sep:
            _reject(client)
            return
        if not authorized(headers, secret):
            _reject(client)
            return
        key = headers.get("sec-websocket-key", "")
        if not key:
            _reject(client)
            return
        _accept(client, key)
        client.settimeout(None)
        if upstream is not None and _proxy(client, upstream, secret):
            return
        _fallback(client, binary)
    except (OSError, DoorError, UnicodeError, ValueError):
        return
    finally:
        try:
            client.close()
        except OSError:
            return


def _read_header(client: socket.socket) -> tuple[str, dict[str, str]] | None:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = client.recv(1)
        if not chunk:
            return None
        data += chunk
        if len(data) > HANDSHAKE_LIMIT:
            return None
    try:
        text = data.split(b"\r\n\r\n", 1)[0].decode("iso-8859-1")
    except UnicodeError:
        return None
    lines = text.split("\r\n")
    if not lines or not lines[0]:
        return None
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, sep, value = line.partition(":")
        if not sep:
            continue
        headers[name.strip().lower()] = value.strip()
    return lines[0], headers


def _reject(client: socket.socket) -> None:
    body = b"Refused\n"
    raw = (
        b"HTTP/1.1 401 Unauthorized\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n"
        b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n"
        b"Connection: close\r\n\r\n" + body
    )
    try:
        client.sendall(raw)
    except OSError:
        return


def _accept(client: socket.socket, key: str) -> None:
    digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
    accept = base64.b64encode(digest).decode("ascii")
    raw = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    client.sendall(raw.encode("ascii"))


def _proxy(client: socket.socket, upstream: tuple[str, int], secret: str) -> bool:
    try:
        remote = socket.create_connection(upstream, timeout=2)
    except OSError:
        return False
    try:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            "GET /ws HTTP/1.1\r\n"
            f"Host: {upstream[0]}:{upstream[1]}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Authorization: Bearer {secret}\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        if any(ord(char) < 0x21 or ord(char) > 0x7E for char in secret):
            return False
        remote.sendall(request.encode("ascii"))
        header = b""
        remote.settimeout(4)
        while b"\r\n\r\n" not in header:
            chunk = remote.recv(1)
            if not chunk:
                return False
            header += chunk
            if len(header) > HANDSHAKE_LIMIT:
                return False
        status = header.split(b"\r\n", 1)[0]
        if b" 101 " not in status and not status.endswith(b" 101"):
            return False
        leftover = header.split(b"\r\n\r\n", 1)[1]
        if leftover:
            client.sendall(leftover)
        remote.settimeout(None)
        client.setblocking(False)
        remote.setblocking(False)
        pending = b""
        while True:
            readable, _, _ = select.select([client, remote], [], [], 30)
            if not readable:
                return True
            if client in readable:
                chunk = client.recv(65536)
                if not chunk:
                    return True
                pending += chunk
                while True:
                    parsed = _parse(pending)
                    if parsed is None:
                        break
                    opcode, payload, size = parsed
                    original = pending[:size]
                    pending = pending[size:]
                    rewritten = _rewrite_cwd(opcode, payload)
                    if rewritten is None:
                        remote.sendall(original)
                    else:
                        remote.sendall(_client_frame(opcode, rewritten))
            if remote in readable:
                chunk = remote.recv(65536)
                if not chunk:
                    return True
                client.sendall(chunk)
    except (OSError, UnicodeError, ValueError):
        return True
    finally:
        try:
            remote.close()
        except OSError:
            pass


def _rewrite_cwd(opcode: int, payload: bytes) -> bytes | None:
    if opcode != 1:
        return None
    try:
        obj = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(obj, dict) or obj.get("method") not in {"session/new", "session/load"}:
        return None
    params = obj.get("params")
    if not isinstance(params, dict) or "cwd" not in params:
        return None
    params["cwd"] = resolve_cwd(str(params.get("cwd") or ""))
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")


class _Session:
    def __init__(self, cwd: str, resume: str | None) -> None:
        self.cwd = cwd
        self.resume = resume
        self.title = "Task"
        self.summary = ""
        self.status = "idle"
        self.usage: dict | None = None
        self.stop_reason = "end_turn"


def _fallback(client: socket.socket, binary: str) -> None:
    sessions: dict[str, _Session] = {}
    running: dict[str, subprocess.Popen[str]] = {}
    buffer = b""
    lines: queue.Queue[str | None] = queue.Queue()
    proc: subprocess.Popen[str] | None = None
    prompt_id: object = None
    prompt_session = ""
    client.setblocking(False)
    while True:
        while True:
            try:
                item = lines.get_nowait()
            except queue.Empty:
                break
            if proc is None:
                continue
            if item is None:
                code = proc.wait()
                _finish_prompt(client, prompt_id, prompt_session, sessions, code)
                proc = None
                prompt_id = None
                continue
            _emit_line(client, prompt_session, sessions, item)
        readable, _, _ = select.select([client], [], [], 0.1)
        if not readable:
            continue
        try:
            chunk = client.recv(65536)
        except BlockingIOError:
            continue
        if not chunk:
            _close_proc(proc)
            return
        buffer += chunk
        while True:
            parsed = _parse(buffer)
            if parsed is None:
                break
            opcode, payload, size = parsed
            buffer = buffer[size:]
            if opcode == 8:
                _close_proc(proc)
                return
            if opcode == 9:
                client.sendall(_server_frame(10, payload))
                continue
            if opcode != 1:
                continue
            try:
                obj = json.loads(payload)
            except (UnicodeError, json.JSONDecodeError):
                continue
            if not isinstance(obj, dict):
                continue
            started = _handle(client, binary, sessions, running, obj)
            if started is None:
                continue
            proc, prompt_id, prompt_session = started
            threading.Thread(target=_read_stdout, args=(proc, lines), daemon=True).start()


def _handle(
    client: socket.socket,
    binary: str,
    sessions: dict[str, _Session],
    running: dict[str, subprocess.Popen[str]],
    obj: dict,
) -> tuple[subprocess.Popen[str], object, str] | None:
    method = obj.get("method")
    ident = obj.get("id")
    params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
    if method == "initialize":
        _send_json(client, {
            "jsonrpc": "2.0",
            "id": ident,
            "result": {"protocolVersion": 1, "_meta": {"approvals": False}},
        })
        return None
    if method == "session/new":
        session_id = os.urandom(8).hex()
        sessions[session_id] = _Session(resolve_cwd(str(params.get("cwd") or "")), None)
        _send_json(client, {"jsonrpc": "2.0", "id": ident, "result": {"sessionId": session_id}})
        return None
    if method == "session/load":
        session_id = str(params.get("sessionId") or "")
        if not session_id:
            _error(client, ident, "That session is not open.")
            return None
        sessions[session_id] = _Session(resolve_cwd(str(params.get("cwd") or "")), session_id)
        _send_json(client, {"jsonrpc": "2.0", "id": ident, "result": {"sessionId": session_id}})
        return None
    if method == "session/cancel":
        session_id = str(params.get("sessionId") or "")
        current = running.get(session_id)
        if current is not None and current.poll() is None:
            current.kill()
        session = sessions.get(session_id)
        if session is not None:
            session.status = "stopped"
            session.stop_reason = "cancelled"
        return None
    if method == "x.ai/session/list":
        rows = []
        for session_id, session in sessions.items():
            rows.append({
                "sessionId": session_id,
                "title": session.title,
                "summary": session.summary,
                "status": session.status,
                "cwd": session.cwd,
            })
        _send_json(client, {"jsonrpc": "2.0", "id": ident, "result": {"sessions": rows}})
        return None
    if method == "x.ai/session/usage":
        session_id = str(params.get("sessionId") or "")
        _send_json(client, {"jsonrpc": "2.0", "id": ident, "result": _usage(binary, session_id)})
        return None
    if method == "session/prompt":
        session_id = str(params.get("sessionId") or "")
        session = sessions.get(session_id)
        prompt = _prompt_text(params.get("prompt"))
        if session is None or not prompt:
            _error(client, ident, "Say what the task should do.")
            return None
        session.status = "running"
        session.title = " ".join(prompt.split()[:6]) or "Task"
        argv = headless_argv(binary, prompt, session.cwd, session.resume)
        try:
            proc = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=child_env(),
            )
        except OSError:
            _error(client, ident, AGENT_DOWN)
            return None
        running[session_id] = proc
        return proc, ident, session_id
    if ident is not None:
        _error(client, ident, "That command is not supported.")
    return None


def _prompt_text(value: object) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
            elif isinstance(item, str):
                parts.append(item)
        return "".join(parts).strip()
    return ""


def _usage(binary: str, session_id: str) -> dict:
    if not session_id or any(char in session_id for char in "\n\r"):
        return {}
    try:
        completed = subprocess.run(
            [binary, "usage", session_id],
            capture_output=True,
            text=True,
            timeout=8,
            env=child_env(),
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    try:
        parsed = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _read_stdout(proc: subprocess.Popen[str], lines: queue.Queue[str | None]) -> None:
    stream = proc.stdout
    try:
        if stream is None:
            lines.put(None)
            return
        for line in stream:
            lines.put(line)
        lines.put(None)
    finally:
        if stream is not None:
            stream.close()


def _close_proc(proc: subprocess.Popen[str] | None) -> None:
    if proc is None:
        return
    if proc.poll() is None:
        proc.kill()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        return


def _emit_line(client: socket.socket, session_id: str, sessions: dict[str, _Session], line: str) -> None:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return
    if not isinstance(event, dict):
        return
    kind = event.get("type")
    session = sessions.get(session_id)
    if kind == "text":
        text = str(event.get("data") or "")
        if session is not None:
            session.summary = (session.summary + text)[:280]
        _send_json(client, {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}},
            },
        })
        return
    if kind == "end":
        if session is not None:
            usage = event.get("usage")
            if isinstance(usage, dict):
                session.usage = usage
            reason = event.get("stopReason")
            if isinstance(reason, str) and reason:
                session.stop_reason = reason
        return
    if kind == "tool_call":
        title = str(event.get("title") or event.get("toolName") or "a tool")
        if session is not None:
            session.summary = f"Using {title}."
        _send_json(client, {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {"sessionUpdate": "tool_call", "title": title},
            },
        })


def _finish_prompt(
    client: socket.socket,
    ident: object,
    session_id: str,
    sessions: dict[str, _Session],
    code: int,
) -> None:
    session = sessions.get(session_id)
    if session is not None:
        session.status = "stopped" if session.stop_reason == "cancelled" else ("idle" if code == 0 else "failed")
    if code != 0 and (session is None or session.stop_reason != "cancelled"):
        _error(client, ident, f"The task ended with status {code}.")
        return
    result: dict[str, object] = {"stopReason": session.stop_reason if session is not None else "end_turn"}
    if session is not None and session.usage:
        result["usage"] = session.usage
    _send_json(client, {"jsonrpc": "2.0", "id": ident, "result": result})


def _error(client: socket.socket, ident: object, message: str) -> None:
    _send_json(client, {"jsonrpc": "2.0", "id": ident, "error": {"message": message}})


def _send_json(client: socket.socket, obj: dict) -> None:
    try:
        client.sendall(_server_frame(1, json.dumps(obj, separators=(",", ":")).encode("utf-8")))
    except OSError:
        return


def _server_frame(opcode: int, payload: bytes) -> bytes:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length <= 0xFFFF:
        header.append(126)
        header += length.to_bytes(2, "big")
    else:
        header.append(127)
        header += length.to_bytes(8, "big")
    return bytes(header) + payload


def _client_frame(opcode: int, payload: bytes) -> bytes:
    mask = os.urandom(4)
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length <= 0xFFFF:
        header.append(0x80 | 126)
        header += length.to_bytes(2, "big")
    else:
        header.append(0x80 | 127)
        header += length.to_bytes(8, "big")
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return bytes(header) + mask + masked


def _parse(buffer: bytes) -> tuple[int, bytes, int] | None:
    if len(buffer) < 2:
        return None
    length = buffer[1] & 0x7F
    offset = 2
    if length == 126:
        if len(buffer) < 4:
            return None
        length = int.from_bytes(buffer[2:4], "big")
        offset = 4
    elif length == 127:
        if len(buffer) < 10:
            return None
        length = int.from_bytes(buffer[2:10], "big")
        offset = 10
    masked = buffer[1] & 0x80
    mask_len = 4 if masked else 0
    total = offset + mask_len + length
    if len(buffer) < total:
        return None
    payload = buffer[offset + mask_len : total]
    if masked:
        mask = buffer[offset : offset + 4]
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return buffer[0] & 0x0F, payload, total


def main() -> int:
    secret = os.environ.get("GROK_AGENT_SECRET", "").strip()
    if not secret:
        print(AGENT_DOWN, flush=True)
        return 1
    bind = os.environ.get("WATCHREMOTE_AGENT_BIND", "127.0.0.1:2419")
    internal = os.environ.get("WATCHREMOTE_AGENT_INTERNAL", "127.0.0.1:2420")
    host, _sep, port_text = bind.rpartition(":")
    upstream_host, _mark, upstream_port = internal.rpartition(":")
    if not host or not port_text.isdigit() or not upstream_host or not upstream_port.isdigit():
        print("The agent bind address is not usable.", flush=True)
        return 1
    ready = threading.Event()
    stop = threading.Event()
    try:
        serve(secret, host, int(port_text), (upstream_host, int(upstream_port)), ready, stop)
    except DoorError as exc:
        print(str(exc), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
