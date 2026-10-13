#!/usr/bin/env python3
"""Loopback door in front of the Grok agent.

The phone key can only forward to 127.0.0.1:2419. This process is what listens
there. It checks the agent secret from the Authorization header, then either
proxies to ``grok agent serve`` or runs headless ``grok -p`` on this computer.
It never asks SSH to execute a command, and it never puts the secret in a URL.

Every client shares one connection to Grok, because Grok sends session
notifications only to its newest connection (see ``Hub``). A client that sends
``X-WatchRemote-Link`` gets a parked link: while the phone is away (iOS drops
the SSH socket of a suspended app) the door keeps the frames for its chats, and
when the same link comes back it resends every frame the phone missed and every
approval still waiting. Grok never re-sends an approval request, so without this
a turn that asked for approval while the phone slept waited forever.
"""

from __future__ import annotations

import base64
import collections
import hashlib
import hmac
import json
import os
import queue
import re
import select
import socket
import subprocess
import threading
import time
from pathlib import Path

AGENT_DOWN = "The agent server on this computer is not answering."
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
HANDSHAKE_LIMIT = 8192
DOOR_VERSION = 3
LINK_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,80}$")
RING_FRAMES = 4000
RING_BYTES = 16 * 1024 * 1024
LINK_LIMIT = 16
IDLE_PING_SECONDS = 30
CLIENT_SEND_SECONDS = 15


def park_seconds() -> float:
    text = os.environ.get("WATCHREMOTE_DOOR_PARK_SECONDS", "").strip()
    try:
        value = float(text) if text else 6 * 3600
    except ValueError:
        value = 6 * 3600
    return max(5.0, value)


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
    links = LinkRegistry(park_seconds(), upstream, secret)
    ready.set()
    last_sweep = time.monotonic()
    try:
        while not stop.is_set():
            if time.monotonic() - last_sweep > 15:
                last_sweep = time.monotonic()
                links.sweep()
            try:
                client, _address = listener.accept()
            except TimeoutError:
                continue
            threading.Thread(
                target=_client,
                args=(client, secret, upstream, program, links),
                daemon=True,
            ).start()
    finally:
        listener.close()
        links.close_all()


def _client(
    client: socket.socket,
    secret: str,
    upstream: tuple[str, int] | None,
    binary: str,
    links: LinkRegistry | None = None,
) -> None:
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
        header_link = headers.get("x-watchremote-link", "").strip()
        link_id = header_link if LINK_PATTERN.match(header_link) else None
        if upstream is not None:
            registry = links if links is not None else LinkRegistry(park_seconds(), upstream, secret)
            link, resumed = registry.open(link_id)
            if link is not None:
                _accept(client, key, resumed=resumed if link_id is not None else None)
                client.settimeout(None)
                seen = _seen(headers.get("x-watchremote-seen", ""))
                link.serve_client(client, seen if resumed else 0)
                return
        _accept(client, key)
        client.settimeout(None)
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


def _seen(text: str) -> int:
    try:
        return max(0, int(text.strip()))
    except ValueError:
        return 0


def _accept(client: socket.socket, key: str, resumed: bool | None = None) -> None:
    digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
    accept = base64.b64encode(digest).decode("ascii")
    extra = f"X-WatchRemote-Door: {DOOR_VERSION}\r\n"
    if resumed is not None:
        extra += f"X-WatchRemote-Resumed: {'yes' if resumed else 'no'}\r\n"
    raw = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"{extra}"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    client.sendall(raw.encode("ascii"))


def _open_upstream(upstream: tuple[str, int], secret: str) -> tuple[socket.socket, bytes] | None:
    """Opens a WebSocket to ``grok agent serve``. Returns the socket and any bytes past the handshake."""
    if any(ord(char) < 0x21 or ord(char) > 0x7E for char in secret):
        return None
    try:
        remote = socket.create_connection(upstream, timeout=2)
    except OSError:
        return None
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
        remote.sendall(request.encode("ascii"))
        header = b""
        remote.settimeout(4)
        while b"\r\n\r\n" not in header:
            chunk = remote.recv(1)
            if not chunk:
                remote.close()
                return None
            header += chunk
            if len(header) > HANDSHAKE_LIMIT:
                remote.close()
                return None
        status = header.split(b"\r\n", 1)[0]
        if b" 101 " not in status and not status.endswith(b" 101"):
            remote.close()
            return None
        remote.settimeout(None)
        return remote, header.split(b"\r\n\r\n", 1)[1]
    except OSError:
        try:
            remote.close()
        except OSError:
            pass
        return None


# Grok's ACP dispatcher requires the leading underscore. The bare name is "Method not found".
_GROK_METHOD = {
    "x.ai/session/list": "_x.ai/session/list",
    "x.ai/session/usage": "_x.ai/session/usage",
}

# A client that prompts, loads, or stops a chat gets that chat's stream and approvals.
_FOLLOW_METHODS = {"session/prompt", "session/load", "session/cancel"}
# What session/load replays the history as. It goes only to the client that asked for it.
_REPLAY_METHODS = {"session/update", "_x.ai/session/update"}


def _rewrite_object(obj: dict) -> bool:
    """Rename extension methods and resolve cwd. True when something changed."""
    changed = False
    method = obj.get("method")
    if isinstance(method, str) and method in _GROK_METHOD:
        obj["method"] = _GROK_METHOD[method]
        method = obj["method"]
        changed = True
    if method in {"session/new", "session/load"}:
        params = obj.get("params")
        if isinstance(params, dict) and "cwd" in params:
            resolved = resolve_cwd(str(params.get("cwd") or ""))
            if params.get("cwd") != resolved:
                params["cwd"] = resolved
                changed = True
    return changed


def _rewrite_outbound(opcode: int, payload: bytes) -> bytes | None:
    """The frame with extension methods renamed and cwd resolved, or None when nothing changes."""
    if opcode != 1:
        return None
    obj = _loads(payload)
    if obj is None or not _rewrite_object(obj):
        return None
    return _dumps(obj)


def _id_key(value: object) -> str:
    return json.dumps(value, separators=(",", ":"))


def _loads(payload: bytes) -> dict | None:
    try:
        obj = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


def _dumps(obj: dict) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")


def _session_of(obj: dict) -> str:
    params = obj.get("params")
    if not isinstance(params, dict):
        return ""
    return str(params.get("sessionId") or "")


def _tool_call_of(obj: dict) -> str:
    params = obj.get("params")
    tool = params.get("toolCall") if isinstance(params, dict) else None
    return str(tool.get("toolCallId") or "") if isinstance(tool, dict) else ""


def _resolved_tool_call(obj: dict) -> str | None:
    """The tool call of an `interaction_resolved` notification, else None."""
    if obj.get("method") != "_x.ai/session_notification":
        return None
    params = obj.get("params")
    update = params.get("update") if isinstance(params, dict) else None
    if not isinstance(update, dict) or update.get("sessionUpdate") != "interaction_resolved":
        return None
    return str(update.get("tool_call_id") or "")


class _Pending:
    """A request Grok sent the clients (an approval) that nobody has answered yet."""

    def __init__(self, ident: object, payload: bytes, session_id: str, tool_call_id: str) -> None:
        self.ident = ident
        self.payload = payload
        self.session_id = session_id
        self.tool_call_id = tool_call_id
        self.since = time.monotonic()


class Hub:
    """The door's one connection to Grok, shared by every client.

    Grok 1.0.52 sends every session notification (stream chunks, approvals, prompt_complete)
    only to its newest connection. A second connection silently took the first one's replies:
    the phone and the Watch host starved each other, and a parked phone link swallowed the
    stream of a chat the phone had just prompted again. The hub renumbers each client's
    requests, routes answers back to the asker, and routes Grok's frames by chat.
    """

    def __init__(self, registry: LinkRegistry, remote: socket.socket, leftover: bytes) -> None:
        self.registry = registry
        self.remote = remote
        self.remote_lock = threading.Lock()
        self.lock = threading.Lock()
        self.next_id = 0
        self.links: list[Link] = []
        # hub request id -> (link, the client's id, kind, session)
        self.routes: dict[str, tuple[Link | None, object, str, str]] = {}
        self.pending: dict[str, _Pending] = {}
        self.loading: dict[str, Link] = {}
        self.queued_loads: dict[str, list[tuple[Link, dict]]] = {}
        self.init_result: object | None = None
        self.ready = threading.Event()
        self.closed = False
        threading.Thread(target=self._read, args=(leftover,), daemon=True).start()

    def initialize(self) -> bool:
        self._forward(None, {
            "jsonrpc": "2.0",
            "id": "door-init",
            "method": "initialize",
            "params": {
                "protocolVersion": 1,
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
                "clientInfo": {"name": "Watch Remote door", "version": str(DOOR_VERSION)},
            },
        })
        return self.ready.wait(10) and self.init_result is not None

    # Links

    def add(self, link: Link) -> None:
        with self.lock:
            self.links.append(link)

    def drop(self, link: Link) -> None:
        with self.lock:
            if link in self.links:
                self.links.remove(link)
            for session, loader in list(self.loading.items()):
                if loader is link:
                    del self.loading[session]
            for key, route in list(self.routes.items()):
                if route[0] is link:
                    self.routes[key] = (None, route[1], route[2], route[3])
            for session in list(self.queued_loads):
                self.queued_loads[session] = [item for item in self.queued_loads[session] if item[0] is not link]
                if not self.queued_loads[session]:
                    del self.queued_loads[session]

    def follow(self, link: Link, session_id: str) -> None:
        if not session_id:
            return
        with self.lock:
            link.sessions.add(session_id)

    def _targets_locked(self, session_id: str) -> list[Link]:
        if session_id:
            following = [link for link in self.links if session_id in link.sessions]
            if following:
                return following
        return list(self.links)

    def pending_for(self, link: Link) -> list[_Pending]:
        with self.lock:
            return [item for item in self.pending.values() if item.session_id in link.sessions]

    # Grok to clients

    def _read(self, leftover: bytes) -> None:
        buffer = leftover
        fragments = b""
        fragment_opcode = 0
        try:
            while not self.closed:
                parsed = _parse_full(buffer)
                if parsed is None:
                    chunk = self.remote.recv(65536)
                    if not chunk:
                        break
                    buffer += chunk
                    continue
                fin, opcode, payload, size = parsed
                buffer = buffer[size:]
                if opcode == 9:
                    self._send_frame(_client_frame(10, payload))
                    continue
                if opcode == 10:
                    continue
                if opcode == 8:
                    break
                if opcode == 0:
                    fragments += payload
                    if not fin:
                        continue
                    opcode, payload, fragments = fragment_opcode, fragments, b""
                elif not fin:
                    fragment_opcode, fragments = opcode, payload
                    continue
                if opcode == 1:
                    self._from_grok(payload)
        except OSError:
            pass
        self.close()

    def _from_grok(self, payload: bytes) -> None:
        obj = _loads(payload)
        if obj is None:
            with self.lock:
                targets = list(self.links)
            for link in targets:
                link.emit(payload)
            return
        ident = obj.get("id")
        method = obj.get("method")
        if method is None:
            if ident is not None:
                self._answered(obj)
            return
        session_id = _session_of(obj)
        if ident is not None:
            item = _Pending(ident, payload, session_id, _tool_call_of(obj))
            with self.lock:
                self.pending[_id_key(ident)] = item
                targets = self._targets_locked(session_id)
            for link in targets:
                link.offer(_id_key(ident), payload)
            return
        resolved = _resolved_tool_call(obj)
        with self.lock:
            if resolved is not None or method == "_x.ai/session/prompt_complete":
                # Grok settled it (answered elsewhere, cancelled, or the turn ended): never resend it.
                for key, item in list(self.pending.items()):
                    if item.session_id == session_id and (resolved is None or item.tool_call_id == resolved):
                        del self.pending[key]
            loader = self.loading.get(session_id) if method in _REPLAY_METHODS else None
            targets = [loader] if loader is not None else self._targets_locked(session_id)
        for link in targets:
            link.emit(payload)

    def _answered(self, obj: dict) -> None:
        with self.lock:
            route = self.routes.pop(_id_key(obj.get("id")), None)
        if route is None:
            return
        link, original, kind, session_id = route
        if kind == "init":
            if "result" in obj:
                self.init_result = obj["result"]
            self.ready.set()
            return
        result = obj.get("result")
        if kind == "new" and link is not None and isinstance(result, dict):
            self.follow(link, str(result.get("sessionId") or ""))
        offers: list[_Pending] = []
        queued: tuple[Link, dict] | None = None
        if kind == "load":
            with self.lock:
                if self.loading.get(session_id) is link:
                    del self.loading[session_id]
                waiting = self.queued_loads.get(session_id)
                if waiting:
                    queued = waiting.pop(0)
                    if not waiting:
                        del self.queued_loads[session_id]
                offers = [item for item in self.pending.values() if item.session_id == session_id]
        if link is not None:
            reply = dict(obj)
            reply["id"] = original
            link.emit(_dumps(reply))
            # Grok never sends an approval again. A client that loads the chat later still gets it.
            for item in offers:
                link.offer(_id_key(item.ident), item.payload)
        if queued is not None:
            self._forward(*queued)

    # Clients to Grok

    def from_client(self, link: Link, payload: bytes) -> None:
        obj = _loads(payload)
        if obj is None:
            self._send_frame(_client_frame(1, payload))
            return
        ident = obj.get("id")
        method = obj.get("method")
        if method is None:
            if ident is None:
                return
            with self.lock:
                item = self.pending.pop(_id_key(ident), None)
            # An answer to a request already answered (it reached two clients) is dropped.
            if item is not None:
                self._send_frame(_client_frame(1, payload))
            return
        if method == "initialize" and ident is not None:
            link.emit(_dumps({"jsonrpc": "2.0", "id": ident, "result": self.init_result}))
            return
        if method in _FOLLOW_METHODS:
            self.follow(link, _session_of(obj))
        if ident is None:
            _rewrite_object(obj)
            self._send_frame(_client_frame(1, _dumps(obj)))
            return
        self._forward(link, obj)

    def _forward(self, link: Link | None, obj: dict) -> None:
        method = obj.get("method")
        session_id = _session_of(obj)
        kind = {"initialize": "init", "session/new": "new", "session/load": "load"}.get(str(method), "call")
        with self.lock:
            if kind == "load" and link is not None:
                if session_id in self.loading:
                    # Two replays of one chat would interleave on the shared connection.
                    self.queued_loads.setdefault(session_id, []).append((link, obj))
                    return
                self.loading[session_id] = link
            self.next_id += 1
            hub_id = self.next_id
            self.routes[_id_key(hub_id)] = (link, obj.get("id"), kind, session_id)
        sent = dict(obj)
        sent["id"] = hub_id
        if isinstance(obj.get("params"), dict):
            sent["params"] = dict(obj["params"])
        _rewrite_object(sent)
        self._send_frame(_client_frame(1, _dumps(sent)))

    def _send_frame(self, frame: bytes) -> None:
        with self.remote_lock:
            try:
                self.remote.sendall(frame)
            except OSError:
                pass

    def cancel_orphans(self, older_than: float) -> None:
        """An approval nobody has followed for a whole park period is cancelled, so Grok's turn ends."""
        now = time.monotonic()
        with self.lock:
            followed = set().union(*(link.sessions for link in self.links)) if self.links else set()
            stale = [
                key for key, item in self.pending.items()
                if item.session_id not in followed and now - item.since > older_than
            ]
            items = [self.pending.pop(key) for key in stale]
        for item in items:
            reply = {"jsonrpc": "2.0", "id": item.ident, "result": {"outcome": {"outcome": "cancelled"}}}
            self._send_frame(_client_frame(1, _dumps(reply)))

    def shutdown(self) -> bool:
        if self.closed:
            return False
        self.closed = True
        self.ready.set()
        try:
            self.remote.close()
        except OSError:
            pass
        return True

    def close(self) -> None:
        if self.shutdown():
            self.registry.hub_lost(self)


class Link:
    """One client of the hub.

    A phone link (``X-WatchRemote-Link``) outlives the phone's socket: iOS drops the SSH socket
    of a suspended app, and the frames for the phone's chats keep arriving. Every frame is
    numbered and kept in a ring. The phone reports how many it has seen when it reattaches and
    gets the rest, then every approval still waiting in its chats. A client without a link id
    (the Watch host) is closed with its socket.
    """

    def __init__(self, key: str, parks: bool, registry: LinkRegistry, hub: Hub) -> None:
        self.key = key
        self.parks = parks
        self.registry = registry
        self.hub = hub
        # Held while numbering and sending a frame, so the client receives frames in ring order.
        self.send_lock = threading.Lock()
        self.seq = 0
        self.ring: collections.deque[tuple[int, bytes]] = collections.deque()
        self.ring_bytes = 0
        self.client: socket.socket | None = None
        self.sessions: set[str] = set()
        self.offered: set[str] = set()
        self.detached_at = time.monotonic()
        self.closed = False

    def emit(self, payload: bytes) -> None:
        with self.send_lock:
            self._emit_locked(payload)

    def _emit_locked(self, payload: bytes) -> None:
        self.seq += 1
        self.ring.append((self.seq, payload))
        self.ring_bytes += len(payload)
        while self.ring and (len(self.ring) > RING_FRAMES or self.ring_bytes > RING_BYTES):
            _seq, dropped = self.ring.popleft()
            self.ring_bytes -= len(dropped)
        client = self.client
        if client is None:
            return
        try:
            client.sendall(_server_frame(1, payload))
        except OSError:
            self._detach_locked(client)

    def offer(self, key: str, payload: bytes) -> None:
        with self.send_lock:
            if key in self.offered:
                return
            self.offered.add(key)
            self._emit_locked(payload)

    def serve_client(self, client: socket.socket, seen: int) -> None:
        self._attach(client, seen)
        buffer = b""
        fragments = b""
        fragment_opcode = 0
        try:
            client.settimeout(IDLE_PING_SECONDS)
            while not self.closed:
                parsed = _parse_full(buffer)
                if parsed is None:
                    try:
                        chunk = client.recv(65536)
                    except TimeoutError:
                        # A quiet turn (a long tool, a pending approval) is not a dead link. A ping finds dead ones.
                        with self.send_lock:
                            if self.client is not client:
                                return
                            client.sendall(_server_frame(9, b"door"))
                        continue
                    if not chunk:
                        break
                    buffer += chunk
                    continue
                fin, opcode, payload, size = parsed
                buffer = buffer[size:]
                if opcode == 8:
                    # An explicit close means the client is done with this link.
                    self.close()
                    return
                if opcode == 9:
                    with self.send_lock:
                        client.sendall(_server_frame(10, payload))
                    continue
                if opcode == 10:
                    continue
                if opcode == 0:
                    fragments += payload
                    if not fin:
                        continue
                    opcode, payload, fragments = fragment_opcode, fragments, b""
                elif not fin:
                    fragment_opcode, fragments = opcode, payload
                    continue
                if opcode == 1:
                    self.hub.from_client(self, payload)
        except OSError:
            pass
        if self.parks:
            self.detach(client)
        else:
            self.close()

    def _attach(self, client: socket.socket, seen: int) -> None:
        waiting = self.hub.pending_for(self)
        with self.send_lock:
            old = self.client
            self.client = client
            if old is not None and old is not client:
                try:
                    old.close()
                except OSError:
                    pass
            try:
                client.settimeout(CLIENT_SEND_SECONDS)
                for seq, payload in list(self.ring):
                    if seq > seen:
                        client.sendall(_server_frame(1, payload))
                for item in waiting:
                    self.offered.add(_id_key(item.ident))
                    if self._in_ring_after(item.payload, seen):
                        continue
                    self.seq += 1
                    self.ring.append((self.seq, item.payload))
                    self.ring_bytes += len(item.payload)
                    client.sendall(_server_frame(1, item.payload))
            except OSError:
                self._detach_locked(client)

    def _in_ring_after(self, payload: bytes, seen: int) -> bool:
        return any(seq > seen and item is payload for seq, item in self.ring)

    def detach(self, client: socket.socket) -> None:
        with self.send_lock:
            self._detach_locked(client)

    def _detach_locked(self, client: socket.socket) -> None:
        if self.client is client:
            self.client = None
            self.detached_at = time.monotonic()
        try:
            client.close()
        except OSError:
            pass

    def attached(self) -> bool:
        return self.client is not None

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        with self.send_lock:
            client = self.client
            self.client = None
        if client is not None:
            try:
                client.close()
            except OSError:
                pass
        self.hub.drop(self)
        self.registry.forget(self)


class LinkRegistry:
    def __init__(self, park: float, upstream: tuple[str, int] | None = None, secret: str = "") -> None:
        self.park = park
        self.upstream = upstream
        self.secret = secret
        self.lock = threading.Lock()
        self.hub_lock = threading.Lock()
        self.hub: Hub | None = None
        self.links: dict[str, Link] = {}
        self.unnamed = 0

    def ensure_hub(self) -> Hub | None:
        with self.hub_lock:
            hub = self.hub
            if hub is not None and not hub.closed:
                return hub
            if self.upstream is None:
                return None
            opened = _open_upstream(self.upstream, self.secret)
            if opened is None:
                return None
            remote, leftover = opened
            hub = Hub(self, remote, leftover)
            if not hub.initialize():
                hub.shutdown()
                return None
            self.hub = hub
            return hub

    def open(self, link_id: str | None) -> tuple[Link | None, bool]:
        if link_id is not None:
            with self.lock:
                existing = self.links.get(link_id)
            if existing is not None and not existing.closed and not existing.hub.closed:
                return existing, True
        hub = self.ensure_hub()
        if hub is None:
            return None, False
        self._make_room()
        with self.lock:
            if link_id is None:
                self.unnamed += 1
                # Not a valid link id, so a phone can never claim it.
                key = f"~client-{self.unnamed}"
            else:
                key = link_id
            link = Link(key, link_id is not None, self, hub)
            self.links[key] = link
        hub.add(link)
        return link, False

    def _make_room(self) -> None:
        with self.lock:
            parked = sorted((link for link in self.links.values() if not link.attached()), key=lambda link: link.detached_at)
            extra = len(self.links) - LINK_LIMIT + 1
        for link in parked[: max(0, extra)]:
            link.close()

    def forget(self, link: Link) -> None:
        with self.lock:
            if self.links.get(link.key) is link:
                del self.links[link.key]

    def hub_lost(self, hub: Hub) -> None:
        """Grok went away. Every client reconnects and reloads its chats from the new connection."""
        with self.hub_lock:
            if self.hub is hub:
                self.hub = None
        with self.lock:
            links = [link for link in self.links.values() if link.hub is hub]
        for link in links:
            link.close()

    def sweep(self) -> None:
        now = time.monotonic()
        with self.lock:
            expired = [link for link in self.links.values() if not link.attached() and now - link.detached_at > self.park]
        for link in expired:
            link.close()
        hub = self.hub
        if hub is not None:
            hub.cancel_orphans(self.park)

    def close_all(self) -> None:
        with self.lock:
            links = list(self.links.values())
        for link in links:
            link.close()
        hub = self.hub
        if hub is not None:
            hub.close()


class _Session:
    def __init__(self, cwd: str, resume: str | None) -> None:
        self.cwd = cwd
        self.resume = resume
        self.title = "Task"
        self.summary = ""
        self.status = "idle"
        self.usage: dict | None = None
        self.stop_reason = "end_turn"
        self.lines: list[str] = []


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
        session = sessions.get(session_id)
        if session is None:
            _error(client, ident, "That chat is no longer on this computer.")
            return None
        cwd = resolve_cwd(str(params.get("cwd") or "")) or session.cwd
        session.cwd = cwd
        for line in session.lines[-80:]:
            _send_stored_line(client, session_id, line)
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
    if method in {"x.ai/session/list", "_x.ai/session/list"}:
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
    if method in {"x.ai/session/usage", "_x.ai/session/usage"}:
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
        _fold_speaker(session.lines, "You:", prompt)
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
            _fold_speaker(session.lines, "Grok:", text)
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
            body = " ".join(title.split())
            if body:
                session.lines.append(f"Tool: {body}")
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
        # A finished turn can show Idle. Nothing here expires the chat or the socket.
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


def _fold_speaker(lines: list[str], prefix: str, text: str) -> None:
    if lines and lines[-1].startswith(prefix):
        lines[-1] = (lines[-1] + text)[:8000]
        return
    body = " ".join(str(text).split())
    if body:
        lines.append(f"{prefix} {body}")


def _send_stored_line(client: socket.socket, session_id: str, line: str) -> None:
    if line.startswith("You:"):
        update = {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": line[len("You:"):].strip()}}
    elif line.startswith("Grok:"):
        update = {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": line[len("Grok:"):].strip()}}
    elif line.startswith("Tool:"):
        update = {"sessionUpdate": "tool_call", "title": line[len("Tool:"):].strip() or "Tool"}
    else:
        return
    _send_json(client, {
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {"sessionId": session_id, "update": update},
    })


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


def _parse_full(buffer: bytes) -> tuple[bool, int, bytes, int] | None:
    parsed = _parse(buffer)
    if parsed is None:
        return None
    opcode, payload, size = parsed
    return bool(buffer[0] & 0x80), opcode, payload, size


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
