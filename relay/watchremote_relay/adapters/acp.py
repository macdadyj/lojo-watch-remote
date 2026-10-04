import base64
import json
import os
import select
import socket
import threading
import time


class ACPAdapter:
    """One WebSocket to `grok agent serve` on loopback. The secret stays in the environment."""

    name = "acp"

    def __init__(self, host: str = "127.0.0.1", port: int = 2419) -> None:
        self.host = host
        self.port = port
        self.sessions: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._cv = threading.Condition()
        self._outbox: list[str] = []
        self._waiters: dict[int, dict] = {}
        self._next = 1
        self._ready = False
        self._error: str | None = None
        self._thread: threading.Thread | None = None

    def list_sessions(self) -> list[dict]:
        try:
            result = self._call("x.ai/session/list", {})
        except OSError:
            with self._lock:
                return list(self.sessions.values())
        rows = result.get("sessions") if isinstance(result, dict) else result
        if not isinstance(rows, list):
            with self._lock:
                return list(self.sessions.values())
        parsed = []
        for row in rows:
            if isinstance(row, dict):
                parsed.append({
                    "id": row.get("id") or row.get("sessionId") or "",
                    "title": row.get("title") or row.get("name") or "Session",
                    "summary": row.get("summary") or row.get("last_turn_summary") or "",
                    "status": row.get("status") or "idle",
                    "updatedAt": time.time(),
                    "cwd": row.get("cwd") or "",
                    "permission": None,
                })
        return parsed or list(self.sessions.values())

    def start(self, prompt: str, cwd: str) -> dict:
        created = self._call("session/new", {
            "cwd": cwd or "/",
            "mcpServers": [],
            "_meta": {"yoloMode": False, "autoMode": False},
        })
        session_id = str(created.get("sessionId") or "")
        if not session_id:
            raise RuntimeError("The agent did not return a session.")
        session = {
            "id": session_id,
            "title": " ".join(prompt.split()[:6]) or "New task",
            "summary": "Starting.",
            "status": "running",
            "updatedAt": time.time(),
            "cwd": cwd,
            "permission": None,
        }
        with self._lock:
            self.sessions[session_id] = session
        threading.Thread(target=self._prompt, args=(session_id, prompt), daemon=True).start()
        return session

    def cancel(self, session_id: str) -> None:
        self._ensure()
        self._enqueue(json.dumps({
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": {"sessionId": session_id},
        }))
        with self._lock:
            session = self.sessions.get(session_id)
        if session is not None:
            session["status"] = "stopped"
            session["permission"] = None
            session["summary"] = "Stopped."

    def decide(self, permission_id: str, allow: bool) -> None:
        with self._lock:
            pending = None
            for session in self.sessions.values():
                permission = session.get("permission") or {}
                if permission.get("id") == permission_id:
                    pending = permission
                    session["permission"] = None
                    session["status"] = "running" if allow else "stopped"
                    session["summary"] = "Allowed." if allow else "Denied."
                    break
        if pending is None:
            raise RuntimeError("That approval is no longer waiting.")
        option = pending.get("allowOptionID") if allow else pending.get("denyOptionID")
        outcome = {"outcome": "selected", "optionId": option} if option else {"outcome": "cancelled"}
        rpc = int(pending["rpcID"]) if pending.get("rpcIDIsNumber") else pending.get("rpcID")
        self._enqueue(json.dumps({"jsonrpc": "2.0", "id": rpc, "result": {"outcome": outcome}}))

    def _prompt(self, session_id: str, prompt: str) -> None:
        try:
            self._call("session/prompt", {
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": prompt}],
            })
            with self._lock:
                session = self.sessions.get(session_id)
            if session is not None and session["status"] == "running":
                session["status"] = "idle"
        except Exception as exc:  # noqa: BLE001 — the session card shows the agent error
            with self._lock:
                session = self.sessions.get(session_id)
            if session is not None:
                session["status"] = "failed"
                session["summary"] = str(exc)

    def _call(self, method: str, params: dict) -> dict:
        self._ensure()
        with self._cv:
            number = self._next
            self._next += 1
            self._outbox.append(json.dumps({
                "jsonrpc": "2.0",
                "id": number,
                "method": method,
                "params": params,
            }))
            self._cv.notify_all()
        deadline = time.time() + 120
        while time.time() < deadline:
            with self._cv:
                found = self._waiters.pop(number, None)
                if found is None:
                    self._cv.wait(timeout=0.2)
                    found = self._waiters.pop(number, None)
            if found is None:
                continue
            if "error" in found:
                raise RuntimeError(str(found["error"]))
            result = found.get("result")
            return result if isinstance(result, dict) else {"value": result}
        raise TimeoutError(method)

    def _enqueue(self, payload: str) -> None:
        self._ensure()
        with self._cv:
            self._outbox.append(payload)
            self._cv.notify_all()

    def _ensure(self) -> None:
        with self._cv:
            if self._thread is None:
                self._thread = threading.Thread(target=self._loop, daemon=True)
                self._thread.start()
            deadline = time.time() + 8
            while not self._ready and self._error is None and time.time() < deadline:
                self._cv.wait(timeout=0.2)
            if self._error:
                raise RuntimeError(self._error)
            if not self._ready:
                raise TimeoutError("The agent server did not complete the WebSocket handshake.")

    def _loop(self) -> None:
        secret = os.environ.get("GROK_AGENT_SECRET", "")
        if not secret:
            with self._cv:
                self._error = "GROK_AGENT_SECRET is not set."
                self._cv.notify_all()
            return
        try:
            sock = socket.create_connection((self.host, self.port), timeout=8)
            key = base64.b64encode(os.urandom(16)).decode()
            request = (
                f"GET /ws?server-key={_quote(secret)} HTTP/1.1\r\n"
                f"Host: {self.host}:{self.port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            )
            sock.sendall(request.encode())
            header = b""
            while b"\r\n\r\n" not in header:
                chunk = sock.recv(4096)
                if not chunk:
                    raise RuntimeError("Agent server closed during the handshake.")
                header += chunk
            if b"101" not in header.split(b"\r\n", 1)[0]:
                raise RuntimeError("The agent server refused the WebSocket.")
            sock.setblocking(False)
            with self._cv:
                self._ready = True
                self._cv.notify_all()
            buffer = b""
            while True:
                with self._cv:
                    while self._outbox:
                        sock.sendall(client_frame(self._outbox.pop(0).encode()))
                readable, _, _ = select.select([sock], [], [], 0.2)
                if not readable:
                    continue
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while True:
                    frame, buffer = pop_server_frame(buffer)
                    if frame is None:
                        break
                    self._handle(frame)
        except Exception as exc:  # noqa: BLE001 — reported to the next caller
            with self._cv:
                self._error = str(exc)
                self._ready = False
                self._cv.notify_all()

    def _handle(self, text: str) -> None:
        try:
            incoming = json.loads(text)
        except json.JSONDecodeError:
            return
        self._note(incoming)
        if "id" in incoming and ("result" in incoming or "error" in incoming):
            with self._cv:
                self._waiters[int(incoming["id"])] = incoming
                self._cv.notify_all()

    def _note(self, incoming: dict) -> None:
        method = incoming.get("method")
        params = incoming.get("params") or {}
        session_id = str(params.get("sessionId") or "")
        with self._lock:
            session = self.sessions.get(session_id)
        if session is None:
            return
        if method == "session/request_permission":
            options = params.get("options") or []
            allow = next((item.get("optionId") for item in options if "allow" in str(item.get("kind", "")).lower()), None)
            deny = next((item.get("optionId") for item in options if "reject" in str(item.get("kind", "")).lower()), None)
            tool = params.get("toolCall") or {}
            session["status"] = "needsApproval"
            session["summary"] = params.get("title") or tool.get("title") or "Needs approval"
            session["permission"] = {
                "id": f"{session_id}:{incoming.get('id')}",
                "sessionID": session_id,
                "rpcID": str(incoming.get("id")),
                "rpcIDIsNumber": isinstance(incoming.get("id"), int),
                "title": session["summary"],
                "detail": params.get("description") or "",
                "allowOptionID": allow,
                "denyOptionID": deny,
            }
        elif method == "session/update":
            update = params.get("update") or {}
            content = update.get("content")
            text = content.get("text") if isinstance(content, dict) else ""
            if update.get("sessionUpdate") in {"agent_message_chunk", "agent_message"} and text:
                session["summary"] = " ".join(((session.get("summary") or "") + text).split())[:280]


def client_frame(payload: bytes) -> bytes:
    mask = os.urandom(4)
    count = len(payload)
    if count < 126:
        header = bytes([0x81, 0x80 | count])
    elif count <= 65535:
        header = bytes([0x81, 0xFE]) + count.to_bytes(2, "big")
    else:
        header = bytes([0x81, 0xFF]) + count.to_bytes(8, "big")
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return header + mask + masked


def pop_server_frame(buffer: bytes) -> tuple[str | None, bytes]:
    if len(buffer) < 2:
        return None, buffer
    length = buffer[1] & 0x7F
    offset = 2
    if length == 126:
        if len(buffer) < 4:
            return None, buffer
        length = int.from_bytes(buffer[2:4], "big")
        offset = 4
    elif length == 127:
        if len(buffer) < 10:
            return None, buffer
        length = int.from_bytes(buffer[2:10], "big")
        offset = 10
    if len(buffer) < offset + length:
        return None, buffer
    payload = buffer[offset:offset + length]
    return payload.decode(errors="replace"), buffer[offset + length:]


def _quote(text: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "-._~" else "%%%02X" % ord(ch) for ch in text)
