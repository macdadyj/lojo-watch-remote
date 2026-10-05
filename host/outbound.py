#!/usr/bin/env python3
"""Outbound direct mode. The computer connects to the relay. The Watch does too.

Frames are sealed with the pairing key. The relay only forwards ciphertext.
SSH from the iPhone is unchanged.
"""

from __future__ import annotations

import json
import os
import select
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

import miniws  # noqa: E402
import relaybox  # noqa: E402


AGENT_DOWN = "The agent server on this computer is not answering."


def clip(text: str, limit: int = 160) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 1] + "…"


def title_from(prompt: str) -> str:
    words = prompt.split()
    return " ".join(words[:6]) or "Task"


class AgentDown:
    available = False

    def list_sessions(self) -> list[dict]:
        raise RuntimeError(AGENT_DOWN)

    def start(self, prompt: str, cwd: str) -> str:
        raise RuntimeError(AGENT_DOWN)

    def decide(self, session_id: str, permission_id: str, allow: bool) -> None:
        raise RuntimeError(AGENT_DOWN)

    def stop(self, session_id: str) -> None:
        raise RuntimeError(AGENT_DOWN)

    def take_update(self) -> dict | None:
        return None


class MemoryAgent:
    """In-memory stand-in used by tests. The shape matches what the Watch decodes."""

    def __init__(self) -> None:
        self.available = True
        self.rows: list[dict] = []
        self.started: list[str] = []
        self.decisions: list[tuple[str, str, bool]] = []
        self.stopped: list[str] = []
        self._push: dict | None = None

    def list_sessions(self) -> list[dict]:
        return self.rows

    def start(self, prompt: str, cwd: str) -> str:
        session_id = f"session-{len(self.started) + 1}"
        self.started.append(prompt)
        self.rows.insert(0, {
            "id": session_id,
            "title": title_from(prompt),
            "summary": "Starting.",
            "status": "running",
            "cwd": cwd,
        })
        return session_id

    def decide(self, session_id: str, permission_id: str, allow: bool) -> None:
        self.decisions.append((session_id or "", permission_id or "", allow))
        for row in self.rows:
            if row["id"] == session_id:
                row["permission"] = None
                row["status"] = "running" if allow else "stopped"
                row["summary"] = "Allowed." if allow else "Denied."

    def stop(self, session_id: str) -> None:
        self.stopped.append(session_id or "")
        for row in self.rows:
            if row["id"] == session_id:
                row["status"] = "stopped"
                row["summary"] = "Stopped."
                row["permission"] = None

    def take_update(self) -> dict | None:
        return None


def handle(agent: object, message: dict) -> dict:
    op = message.get("op")
    ident = str(message.get("id") or "")
    try:
        if op == "ping":
            return {"op": "pong", "id": ident}
        if op == "list":
            return {
                "op": "sessions",
                "id": ident,
                "sessions": agent.list_sessions(),
                "approvalsAvailable": bool(getattr(agent, "available", True)),
            }
        if op == "start":
            prompt = str(message.get("prompt") or "").strip()
            if not prompt:
                return {"op": "error", "id": ident, "message": "Say what the task should do."}
            session_id = agent.start(prompt, str(message.get("cwd") or ""))
            return {"op": "started", "id": ident, "sessionID": session_id}
        if op == "approve":
            agent.decide(message.get("sessionID"), message.get("permissionID"), True)
            return {"op": "ok", "id": ident}
        if op == "deny":
            agent.decide(message.get("sessionID"), message.get("permissionID"), False)
            return {"op": "ok", "id": ident}
        if op == "stop":
            agent.stop(str(message.get("sessionID") or ""))
            return {"op": "ok", "id": ident}
        return {"op": "error", "id": ident, "message": "That command is not supported."}
    except RuntimeError as error:
        text = str(error).strip() or "The computer could not do that."
        return {"op": "error", "id": ident, "message": text}


class ACPAgent:
    available = True

    def __init__(self, secret: str, host: str = "127.0.0.1", port: int = 2419) -> None:
        self.secret = secret
        self.host = host
        self.port = port
        self.conn: miniws.WSConn | None = None
        self.next_id = 1
        self.results: dict[int, dict] = {}
        self.rows: list[dict] = []
        self.permissions: dict[str, dict] = {}
        self.pending_push = False
        self.push_n = 0

    def open(self) -> None:
        # The secret is a header so a proxy access log cannot record it from the URL.
        self.conn = miniws.connect(
            f"ws://{self.host}:{self.port}/ws",
            timeout=4,
            headers={"Authorization": "Bearer " + self.secret},
        )
        self.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            "clientInfo": {"name": "Watch Remote", "version": "1.0"},
        })

    def list_sessions(self) -> list[dict]:
        result = self.request("x.ai/session/list", {})
        self.rows = sessions_from(result.get("result"))
        self._apply_permissions()
        return self.rows

    def start(self, prompt: str, cwd: str) -> str:
        directory = cwd.strip() or str(Path.home())
        created = self.request("session/new", {
            "cwd": directory,
            "mcpServers": [],
            "_meta": {"yoloMode": False, "autoMode": False},
        })
        session_id = ""
        result = created.get("result") if isinstance(created.get("result"), dict) else {}
        if isinstance(result, dict):
            session_id = str(result.get("sessionId") or "")
        if not session_id:
            raise RuntimeError("The agent did not return a session.")
        self._send(None, "session/prompt", {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": prompt}],
        })
        row = {
            "id": session_id,
            "title": title_from(prompt),
            "summary": "Starting.",
            "status": "running",
            "cwd": directory,
        }
        self.rows = [row] + [item for item in self.rows if item.get("id") != session_id]
        return session_id

    def decide(self, session_id: str, permission_id: str, allow: bool) -> None:
        stored = self.permissions.get(str(permission_id or ""))
        if stored is None:
            raise RuntimeError("That approval is no longer waiting.")
        option = stored["allow"] if allow else stored["deny"]
        if option:
            outcome = {"outcome": "selected", "optionId": option}
        else:
            outcome = {"outcome": "cancelled"}
        rpc_id: object = int(stored["rpc"]) if stored["number"] and str(stored["rpc"]).isdigit() else stored["rpc"]
        self._send_raw({"jsonrpc": "2.0", "id": rpc_id, "result": {"outcome": outcome}})
        self.permissions.pop(str(permission_id), None)
        for row in self.rows:
            if row.get("id") == session_id:
                row.pop("permission", None)
                row["status"] = "running" if allow else "stopped"
                row["summary"] = "Allowed." if allow else "Denied."

    def stop(self, session_id: str) -> None:
        self._send_raw({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session_id}})
        for row in self.rows:
            if row.get("id") == session_id:
                row["status"] = "stopped"
                row["summary"] = "Stopped."
                row.pop("permission", None)

    def take_update(self) -> dict | None:
        if not self.pending_push:
            return None
        self.pending_push = False
        self.push_n += 1
        return {
            "op": "update",
            "id": f"push-{self.push_n}",
            "sessions": self.rows,
            "approvalsAvailable": True,
        }

    def pump(self) -> None:
        if self.conn is None:
            return
        opcode, payload = self.conn.recv()
        if opcode == 1:
            self._ingest(payload.decode("utf-8"))

    def request(self, method: str, params: dict) -> dict:
        ident = self.next_id
        self.next_id += 1
        self._send(ident, method, params)
        deadline = time.time() + 12
        while ident not in self.results:
            if time.time() > deadline:
                raise RuntimeError("The agent server did not answer.")
            assert self.conn is not None
            self.conn.sock.settimeout(max(0.2, deadline - time.time()))
            self.pump()
        result = self.results.pop(ident)
        if "error" in result:
            message = "The agent reported an error."
            error = result["error"]
            if isinstance(error, dict) and isinstance(error.get("message"), str):
                message = error["message"]
            raise RuntimeError(message)
        return result

    def _send(self, ident: int | None, method: str, params: dict) -> None:
        body: dict = {"jsonrpc": "2.0", "method": method, "params": params}
        if ident is not None:
            body["id"] = ident
        self._send_raw(body)

    def _send_raw(self, body: dict) -> None:
        if self.conn is None:
            raise RuntimeError(AGENT_DOWN)
        self.conn.send_text(json.dumps(body, separators=(",", ":")))

    def _ingest(self, text: str) -> None:
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            return
        if not isinstance(obj, dict):
            return
        method = obj.get("method")
        if method == "session/request_permission":
            self._remember_permission(obj)
            self.pending_push = True
            return
        if method == "session/update":
            self._remember_text(obj)
            self.pending_push = True
            return
        if "id" in obj and ("result" in obj or "error" in obj):
            ident = obj["id"]
            if isinstance(ident, int):
                self.results[ident] = obj

    def _remember_permission(self, obj: dict) -> None:
        params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
        session_id = str(params.get("sessionId") or "")
        rpc = obj.get("id")
        number = isinstance(rpc, int)
        rpc_text = str(rpc)
        options = params.get("options") if isinstance(params.get("options"), list) else []
        allow = option_id(options, "allow")
        deny = option_id(options, "reject")
        tool = params.get("toolCall") if isinstance(params.get("toolCall"), dict) else {}
        title = params.get("title") or tool.get("title") or "Approve this action"
        detail = params.get("description") or ""
        permission_id = f"{session_id}:{rpc_text}"
        self.permissions[permission_id] = {
            "rpc": rpc_text,
            "number": number,
            "allow": allow,
            "deny": deny,
            "permission": permission,
        }
        permission = {
            "id": permission_id,
            "sessionID": session_id,
            "rpcID": rpc_text,
            "rpcIDIsNumber": number,
            "title": str(title),
            "detail": clip(str(detail)),
            "allowOptionID": allow,
            "denyOptionID": deny,
        }
        found = False
        for row in self.rows:
            if row.get("id") == session_id:
                row["status"] = "needsApproval"
                row["permission"] = permission
                row["summary"] = str(title)
                found = True
        if not found:
            self.rows.insert(0, {
                "id": session_id or permission_id,
                "title": str(title),
                "summary": str(title),
                "status": "needsApproval",
                "permission": permission,
            })

    def _remember_text(self, obj: dict) -> None:
        params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
        session_id = str(params.get("sessionId") or "")
        update = params.get("update") if isinstance(params.get("update"), dict) else {}
        kind = str(update.get("sessionUpdate") or "")
        if kind not in {"agent_message_chunk", "agent_message"}:
            return
        content = update.get("content")
        text = ""
        if isinstance(content, dict):
            text = str(content.get("text") or "")
        elif isinstance(content, str):
            text = content
        if not text:
            return
        for row in self.rows:
            if row.get("id") == session_id:
                row["summary"] = clip((row.get("summary") or "") + text)

    def _apply_permissions(self) -> None:
        for row in self.rows:
            matches = [value for key, value in self.permissions.items() if key.startswith(str(row.get("id")) + ":")]
            if not matches:
                continue
            row["status"] = "needsApproval"
            row["permission"] = matches[0]["permission"]


def option_id(options: list, needle: str) -> str | None:
    for option in options:
        if not isinstance(option, dict):
            continue
        kind = str(option.get("kind") or "").lower()
        name = str(option.get("name") or "").lower()
        if needle in kind or needle in name:
            value = option.get("optionId")
            if isinstance(value, str):
                return value
    return None


def sessions_from(result: object) -> list[dict]:
    rows: object = []
    if isinstance(result, dict) and isinstance(result.get("sessions"), list):
        rows = result["sessions"]
    elif isinstance(result, list):
        rows = result
    parsed: list[dict] = []
    if not isinstance(rows, list):
        return parsed
    for row in rows:
        if not isinstance(row, dict):
            continue
        session_id = str(row.get("sessionId") or row.get("id") or "")
        if not session_id:
            continue
        status = str(row.get("status") or "unknown")
        if status not in {"running", "needsApproval", "idle", "stopped", "failed", "unknown"}:
            status = "unknown"
        parsed.append({
            "id": session_id,
            "title": str(row.get("title") or "Session"),
            "summary": clip(str(row.get("summary") or "")),
            "status": status,
        })
    return parsed


def load_config(path: Path) -> dict:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise relaybox.RelayBoxError("The direct pairing file could not be read.")
    relay = raw.get("relay")
    token = raw.get("token")
    e2e = raw.get("e2e")
    if not isinstance(relay, str) or not isinstance(token, str) or not isinstance(e2e, str):
        raise relaybox.RelayBoxError("The direct pairing file could not be read.")
    url = saved_relay_url(relay)
    room = saved_token(token)
    key = saved_key(e2e)
    if url is None or room is None or key is None:
        raise relaybox.RelayBoxError("The direct pairing file could not be read.")
    return {"relay": url, "token": room, "key": key}


def saved_relay_url(text: str) -> str | None:
    trimmed = text.strip()
    if not 12 <= len(trimmed) <= 300 or any(char.isspace() for char in trimmed):
        return None
    parts = urlsplit(trimmed)
    host = parts.hostname or ""
    if not host or len(host) > 253 or parts.username or parts.password or parts.query or parts.fragment:
        return None
    scheme = parts.scheme.lower()
    if scheme == "wss":
        return trimmed
    if scheme == "ws" and host in {"127.0.0.1", "localhost"}:
        return trimmed
    return None


def saved_token(text: str) -> str | None:
    trimmed = text.strip()
    if not 16 <= len(trimmed) <= 128 or any(char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for char in trimmed):
        return None
    return trimmed


def saved_key(text: str) -> bytes | None:
    import base64

    trimmed = text.strip().replace("=", "")
    if not trimmed or any(char.isspace() for char in trimmed):
        return None
    pad = "=" * ((4 - len(trimmed) % 4) % 4)
    try:
        key = base64.urlsafe_b64decode(trimmed + pad)
    except Exception:
        return None
    if len(key) != 32:
        return None
    return key


def counter_path(config_path: Path) -> Path:
    return config_path.with_name("outbound-counters.json")


def load_counters(path: Path) -> tuple[int, int]:
    if not path.is_file():
        return 0, 0
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 0, 0
    send = int(raw.get("send") or 0) if isinstance(raw, dict) else 0
    recv = int(raw.get("recv") or 0) if isinstance(raw, dict) else 0
    return max(send, 0), max(recv, 0)


def save_counters(path: Path, send: int, recv: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps({"send": send, "recv": recv}), encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, path)
    path.chmod(0o600)


def read_secret() -> str:
    path = Path(os.environ.get("GROK_AGENT_SECRET_FILE", "")).expanduser() if os.environ.get("GROK_AGENT_SECRET_FILE") else Path.home() / ".config" / "watch-remote" / "agent-secret"
    if not path.is_file():
        raise RuntimeError(AGENT_DOWN)
    secret = path.read_text(encoding="utf-8").strip()
    if not secret:
        raise RuntimeError(AGENT_DOWN)
    return secret


def open_agent() -> object:
    try:
        agent = ACPAgent(read_secret())
        agent.open()
        return agent
    except (OSError, RuntimeError, miniws.SocketError, relaybox.RelayBoxError):
        return AgentDown()


def run(config_path: Path, agent: object | None = None) -> None:
    serve_connection(load_config(config_path), agent, counter_path(config_path))


def serve_connection(config: dict, agent: object | None, counters: Path) -> None:
    send_n, recv_n = load_counters(counters)
    replay = relaybox.ReplayWindow.restored(recv_n)
    conn = miniws.connect(config["relay"])
    try:
        conn.send_text(json.dumps({"role": "host", "token": config["token"]}, separators=(",", ":")))
        opcode, payload = conn.recv()
        if opcode != 1 or b'"ok":true' not in payload:
            raise miniws.SocketError("The relay did not accept this pairing.")
        if agent is None:
            agent = open_agent()
        conn.sock.settimeout(1)
        agent_conn = getattr(agent, "conn", None)
        if agent_conn is not None:
            agent_conn.sock.settimeout(1)
        while True:
            sockets = [conn.sock]
            agent_sock = getattr(agent_conn, "sock", None)
            if agent_sock is not None:
                sockets.append(agent_sock)
            # A frame can already be in the client buffer from the previous read.
            # select does not see that, so a queued hello-plus-command would stall.
            wait = 0 if conn.pending() else 1
            readable, _, _ = select.select(sockets, [], [], wait)
            if conn.pending() and conn.sock not in readable:
                readable = [*readable, conn.sock]
            if agent_sock is not None and agent_sock in readable:
                try:
                    agent.pump()
                except (OSError, miniws.SocketError, TimeoutError):
                    agent_conn = None
                    agent_sock = None
            update = agent.take_update()
            if update is not None:
                send_n += 1
                conn.send_binary(relaybox.seal(relaybox.encode_message(update), config["key"], relaybox.HOST_TO_WATCH, send_n))
                save_counters(counters, send_n, replay.highest)
            if conn.sock not in readable:
                continue
            try:
                opcode, payload = conn.recv()
            except TimeoutError:
                continue
            if opcode != 2:
                continue
            try:
                plain = relaybox.open_frame(payload, config["key"], relaybox.WATCH_TO_HOST, replay)
            except relaybox.RelayBoxError:
                continue
            reply = handle(agent, relaybox.decode_message(plain))
            send_n += 1
            conn.send_binary(relaybox.seal(relaybox.encode_message(reply), config["key"], relaybox.HOST_TO_WATCH, send_n))
            save_counters(counters, send_n, replay.highest)
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    del argv
    path = Path(os.environ.get("WATCHREMOTE_OUTBOUND_FILE", "")).expanduser() if os.environ.get("WATCHREMOTE_OUTBOUND_FILE") else Path.home() / ".config" / "watch-remote" / "outbound.json"
    if not path.is_file():
        print("No direct pairing yet. Run watch-remote-pair --relay-url with your wss address.", file=sys.stderr)
        return 1
    while True:
        try:
            run(path)
        except (OSError, miniws.SocketError, relaybox.RelayBoxError, json.JSONDecodeError):
            print("Direct connection dropped. Trying again.", file=sys.stderr)
            time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
