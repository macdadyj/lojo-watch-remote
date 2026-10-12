#!/usr/bin/env python3
"""A stand-in for `grok agent serve` that speaks enough ACP for the Watch tests.

It listens on 127.0.0.1, wants the same Bearer secret as the real server, and
answers initialize, _x.ai/session/list, session/new, session/load,
session/prompt, and session/cancel. Replies stream as several
agent_message_chunk updates. A prompt that mentions a file or a tool asks for
permission first, the way Grok Build does before it reads a file.
Nothing here talks to a model.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
import time
from pathlib import Path

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

SEED = {
    "sessionId": "session-seed",
    "title": "Greeting and Current Weather Inquiry",
    "summary": "Ready.",
    "status": "idle",
    "cwd": "/tmp",
    "history": [("user", "earlier"), ("agent", "Ready.")],
}


def reply_text(prompt: str) -> str:
    """Canned answers. The Watch tests look for these exact sentences."""
    folded = " ".join(prompt.split()).lower().rstrip(".?!")
    if folded == "again":
        return "Heard again."
    if folded.startswith("reopen"):
        return "Reopened."
    if wants_tool(folded):
        return "I read notes.txt. It says hello."
    return "I can hear you."


def wants_tool(prompt: str) -> bool:
    folded = prompt.lower()
    return "file" in folded or "tool" in folded or "notes" in folded


class FakeGrok:
    def __init__(self, secret: str, chunk_delay: float = 0.05) -> None:
        self.secret = secret
        self.chunk_delay = chunk_delay
        self.lock = threading.Lock()
        self.sessions: dict[str, dict] = {}
        self.order: list[str] = []
        self.prompts: list[dict] = []
        self.decisions: list[dict] = []
        self.loads: list[str] = []
        self.connections = 0
        self.counter = 0
        self.server: socket.socket | None = None
        self.clients: list[socket.socket] = []
        self.reset()

    def reset(self) -> None:
        with self.lock:
            seed = json.loads(json.dumps(SEED))
            seed["history"] = [tuple(item) for item in seed["history"]]
            self.sessions = {seed["sessionId"]: seed}
            self.order = [seed["sessionId"]]
            self.prompts = []
            self.decisions = []
            self.loads = []
            self.counter = 0

    def state(self) -> dict:
        with self.lock:
            return {
                "sessions": [
                    {"id": key, "title": self.sessions[key]["title"], "history": [list(item) for item in self.sessions[key]["history"]]}
                    for key in self.order
                ],
                "prompts": list(self.prompts),
                "decisions": list(self.decisions),
                "loads": list(self.loads),
                "connections": self.connections,
            }

    def listen(self, port: int) -> int:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(16)
        self.server = server
        threading.Thread(target=self._accept, daemon=True).start()
        return server.getsockname()[1]

    def drop_clients(self) -> None:
        for client in list(self.clients):
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                client.close()
            except OSError:
                pass
        self.clients.clear()

    def close(self) -> None:
        if self.server is not None:
            try:
                self.server.close()
            except OSError:
                pass
        self.drop_clients()

    def _accept(self) -> None:
        assert self.server is not None
        while True:
            try:
                client, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(client,), daemon=True).start()

    def _serve(self, client: socket.socket) -> None:
        try:
            if not self._handshake(client):
                client.close()
                return
        except OSError:
            return
        self.clients.append(client)
        with self.lock:
            self.connections += 1
        peer = Peer(client)
        try:
            while True:
                opcode, payload = peer.recv()
                if opcode == 8:
                    return
                if opcode == 9:
                    peer.send(10, payload)
                    continue
                if opcode != 1:
                    continue
                try:
                    message = json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if isinstance(message, dict):
                    self._dispatch(peer, message)
        except (OSError, ConnectionError):
            return
        finally:
            try:
                client.close()
            except OSError:
                pass

    def _handshake(self, client: socket.socket) -> bool:
        client.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                return False
            data += chunk
            if len(data) > 16384:
                return False
        client.settimeout(None)
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1")
        lines = head.split("\r\n")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        if headers.get("authorization") != "Bearer " + self.secret:
            client.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return False
        key = headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        client.sendall(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("ascii")
        )
        return True

    def _dispatch(self, peer: "Peer", message: dict) -> None:
        method = message.get("method")
        ident = message.get("id")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if method is None and ident is not None:
            peer.answer(ident, message)
            return
        if method == "initialize":
            peer.result(ident, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}})
        elif method == "_x.ai/session/list":
            with self.lock:
                rows = [
                    {
                        "sessionId": key,
                        "title": self.sessions[key]["title"],
                        "summary": self.sessions[key]["summary"],
                        "status": self.sessions[key]["status"],
                        "cwd": self.sessions[key]["cwd"],
                    }
                    for key in self.order
                ]
            peer.result(ident, {"sessions": rows})
        elif method == "session/new":
            with self.lock:
                self.counter += 1
                session_id = f"fake-{self.counter}-{int(time.time() * 1000) % 100000}"
                self.sessions[session_id] = {
                    "sessionId": session_id,
                    "title": "New chat",
                    "summary": "",
                    "status": "idle",
                    "cwd": str(params.get("cwd") or "/tmp"),
                    "history": [],
                }
                self.order.insert(0, session_id)
            peer.result(ident, {"sessionId": session_id})
        elif method == "session/load":
            session_id = str(params.get("sessionId") or "")
            with self.lock:
                session = self.sessions.get(session_id)
                history = list(session["history"]) if session else []
                self.loads.append(session_id)
            if session is None:
                peer.error(ident, "Session not found")
                return
            for role, text in history:
                kind = "user_message_chunk" if role == "user" else "agent_message_chunk"
                peer.update(session_id, {"sessionUpdate": kind, "content": {"type": "text", "text": text}})
            peer.result(ident, {})
        elif method == "session/prompt":
            threading.Thread(target=self._prompt, args=(peer, ident, params), daemon=True).start()
        elif method == "session/cancel":
            peer.cancel(str(params.get("sessionId") or ""))
        elif ident is not None:
            peer.error(ident, "Method not found")

    def _prompt(self, peer: "Peer", ident: object, params: dict) -> None:
        session_id = str(params.get("sessionId") or "")
        parts = params.get("prompt") if isinstance(params.get("prompt"), list) else []
        text = " ".join(str(part.get("text") or "") for part in parts if isinstance(part, dict)).strip()
        with self.lock:
            session = self.sessions.get(session_id)
            if session is not None:
                session["history"].append(("user", text))
                session["status"] = "running"
                if session["title"] == "New chat":
                    session["title"] = " ".join(text.split()[:6]) or "Task"
            self.prompts.append({"sessionId": session_id, "text": text})
        if session is None:
            peer.error(ident, "Session not found")
            return
        if wants_tool(text):
            title = "Read notes.txt"
            peer.update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "call-1", "title": title, "status": "pending"})
            outcome = peer.ask(session_id, title)
            with self.lock:
                self.decisions.append({"sessionId": session_id, "outcome": outcome})
            if outcome != "allow-once":
                with self.lock:
                    session["status"] = "idle"
                peer.result(ident, {"stopReason": "cancelled"})
                return
        answer = reply_text(text)
        words = answer.split(" ")
        pieces = [" ".join(words[: max(1, len(words) // 2)]), " " + " ".join(words[max(1, len(words) // 2) :])]
        for piece in pieces:
            if not piece.strip():
                continue
            time.sleep(self.chunk_delay)
            peer.update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": piece}})
        with self.lock:
            session["history"].append(("agent", answer))
            session["status"] = "idle"
            session["summary"] = answer
        peer.result(ident, {"stopReason": "end_turn"})


class Peer:
    """One ACP client connection. Writes are serialized; permission answers wake the asking thread."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buffer = b""
        self.write_lock = threading.Lock()
        self.waiting: dict[str, dict] = {}
        self.next_rpc = 900

    def recv(self) -> tuple[int, bytes]:
        while True:
            parsed = _parse_masked(self.buffer)
            if parsed is not None:
                opcode, payload, used = parsed
                self.buffer = self.buffer[used:]
                return opcode, payload
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buffer += chunk

    def send(self, opcode: int, payload: bytes) -> None:
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", 0x80 | opcode, length)
        elif length < 65536:
            header = struct.pack("!BBH", 0x80 | opcode, 126, length)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 127, length)
        with self.write_lock:
            self.sock.sendall(header + payload)

    def json(self, body: dict) -> None:
        try:
            self.send(1, json.dumps(body, separators=(",", ":")).encode("utf-8"))
        except OSError:
            pass

    def result(self, ident: object, result: dict) -> None:
        self.json({"jsonrpc": "2.0", "id": ident, "result": result})

    def error(self, ident: object, message: str) -> None:
        self.json({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": message}})

    def update(self, session_id: str, update: dict) -> None:
        self.json({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": update}})

    def ask(self, session_id: str, title: str, timeout: float = 600) -> str:
        self.next_rpc += 1
        rpc = self.next_rpc
        slot = {"event": threading.Event(), "outcome": "cancelled", "session": session_id}
        self.waiting[str(rpc)] = slot
        self.json({
            "jsonrpc": "2.0",
            "id": rpc,
            "method": "session/request_permission",
            "params": {
                "sessionId": session_id,
                "toolCall": {"toolCallId": "call-1", "title": title},
                "options": [
                    {"optionId": "allow-once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"},
                ],
            },
        })
        slot["event"].wait(timeout)
        self.waiting.pop(str(rpc), None)
        return str(slot["outcome"])

    def answer(self, ident: object, message: dict) -> None:
        slot = self.waiting.get(str(ident))
        if slot is None:
            return
        result = message.get("result") if isinstance(message.get("result"), dict) else {}
        outcome = result.get("outcome") if isinstance(result.get("outcome"), dict) else {}
        if outcome.get("outcome") == "selected":
            slot["outcome"] = str(outcome.get("optionId") or "")
        slot["event"].set()

    def cancel(self, session_id: str) -> None:
        for slot in list(self.waiting.values()):
            if slot["session"] == session_id:
                slot["event"].set()


def _parse_masked(buffer: bytes) -> tuple[int, bytes, int] | None:
    if len(buffer) < 2:
        return None
    opcode = buffer[0] & 0x0F
    masked = bool(buffer[1] & 0x80)
    length = buffer[1] & 0x7F
    offset = 2
    if length == 126:
        if len(buffer) < 4:
            return None
        length = struct.unpack("!H", buffer[2:4])[0]
        offset = 4
    elif length == 127:
        if len(buffer) < 10:
            return None
        length = struct.unpack("!Q", buffer[2:10])[0]
        offset = 10
    mask = b""
    if masked:
        if len(buffer) < offset + 4:
            return None
        mask = buffer[offset : offset + 4]
        offset += 4
    if len(buffer) < offset + length:
        return None
    payload = buffer[offset : offset + length]
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return opcode, payload, offset + length


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--secret-file", required=True)
    args = parser.parse_args()
    secret = Path(args.secret_file).read_text(encoding="utf-8").strip()
    fake = FakeGrok(secret)
    port = fake.listen(args.port)
    print(json.dumps({"event": "listening", "port": port}), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
