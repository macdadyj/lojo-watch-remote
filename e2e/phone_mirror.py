"""The iPhone's ACP client logic, mirrored in Python for the real-host check.

Each piece names the Swift it mirrors. Requests carry the same JSON objects the app sends
(JSONSerialization does not fix key order, so the bytes can differ in order only), the upgrade
request carries the same headers, and the transcript rules are the same rules, so a transcript
built here from a recorded stream is the transcript the app builds from it. The Swift replay
test (App/Tests/RealStreamReplayTests.swift) replays the recordings through the Swift code and
asserts it ends with the transcripts recorded here.
"""

from __future__ import annotations

import base64
import json
import os
import socket
import threading
import time
from typing import Callable

# ChatTranscript (Core/Sources/WatchRemoteCore/ChatThread.swift)

TOOL_PREFIX = "Tool:"
AUTO_PREFIX = "Auto-approved:"


def tool_card(title: str) -> str:
    name = title.strip()
    return f"{TOOL_PREFIX} {name or 'tool'}"


def is_tool_card(line: str) -> bool:
    return line.startswith(TOOL_PREFIX)


def is_note(line: str) -> bool:
    return line.startswith(AUTO_PREFIX)


def is_status_noise(line: str) -> bool:
    folded = line.strip().lower()
    if not folded:
        return True
    if folded in {"on-device speech", "speech on iphone", "listening", "hearing you", "restoring", "restored"}:
        return True
    if folded == "sending" or folded.startswith("sending.") or folded.startswith("sending "):
        return True
    return folded.startswith("keychain error")


def spoken_text(line: str) -> str:
    if line.startswith("You:"):
        return line[4:].strip(" ")
    if line.startswith("Grok:"):
        return line[5:].strip(" ")
    return line.strip()


def append(line: str, lines: list[str]) -> list[str]:
    trimmed = line.strip()
    return lines + [trimmed] if trimmed else lines


def streaming_speaker(prefix: str, chunk: str, lines: list[str]) -> list[str]:
    if not chunk:
        return lines
    copy = list(lines)
    if copy and copy[-1].startswith(prefix):
        copy[-1] = (copy[-1] + chunk)[:8000]
        return copy
    trimmed = chunk.lstrip()
    if not trimmed:
        return lines
    copy.append(f"{prefix} {trimmed}")
    return copy


def noting_auto_approval(title: str, lines: list[str]) -> list[str]:
    if lines and is_tool_card(lines[-1]):
        return lines
    return append(f"{AUTO_PREFIX} {title.strip() or 'tool'}", lines)


def merging_user_echo(chunk: str, lines: list[str]) -> list[str]:
    trimmed = chunk.strip()
    if not trimmed:
        return lines
    if not lines or not lines[-1].startswith("You:"):
        return streaming_speaker("You:", chunk, lines)
    spoken = spoken_text(lines[-1])
    if spoken == trimmed or (len(trimmed) <= len(spoken) and (spoken.startswith(trimmed) or spoken.endswith(trimmed))):
        return lines
    if len(spoken) < len(trimmed) and trimmed.startswith(spoken):
        copy = list(lines)
        copy[-1] = f"You: {trimmed}"
        return copy
    return streaming_speaker("You:", chunk, lines)


def chat_lines(lines: list[str]) -> list[str]:
    cleaned = [line.strip() for line in lines if line.strip() and not is_status_noise(line.strip())]
    marked = any(line.startswith(("You:", "Grok:")) or is_tool_card(line) or is_note(line) for line in cleaned)
    return cleaned if marked else []


# StreamEvent / ACPCodec.parse (Core/Sources/WatchRemoteCore/ACPCodec.swift)


def content_text(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if isinstance(value.get("text"), str):
            return value["text"]
        if "content" in value:
            return content_text(value["content"])
    if isinstance(value, list):
        return "".join(content_text(item) for item in value)
    return ""


def update_event(update: object) -> tuple:
    if not isinstance(update, dict):
        return ("ignored",)
    kind = update.get("sessionUpdate") or ""
    text = content_text(update.get("content"))
    if not text:
        text = content_text(update.get("text"))
    if not text:
        text = content_text(update.get("message"))
    if kind in {"user_message_chunk", "user_message"}:
        return ("user", text)
    if kind in {"agent_message_chunk", "agent_message"}:
        return ("text", text)
    if kind in {"agent_thought_chunk", "agent_thought"}:
        return ("thought", text)
    if kind == "tool_call":
        title = update.get("title") if isinstance(update.get("title"), str) else "Tool"
        ident = update.get("toolCallId")
        if isinstance(ident, str) and ident:
            return ("toolCall", ident, title)
        return ("tool", title)
    if kind == "tool_call_update":
        title = update.get("title") if isinstance(update.get("title"), str) and update["title"].strip() else None
        status = update.get("status") if isinstance(update.get("status"), str) else None
        ident = update.get("toolCallId")
        if isinstance(ident, str) and ident:
            return ("toolCallUpdate", ident, title, status)
        return ("toolUpdate", status or "")
    if kind == "session_info_update":
        title = str(update.get("title") or "").strip()
        return ("title", title) if title else ("ignored",)
    return ("ignored",)


def option_id(options: list, once: str, fallback: str) -> str | None:
    rows = [option for option in options if isinstance(option, dict)]
    for option in rows:
        if str(option.get("kind") or "").lower() == once:
            return option.get("optionId")

    def words(option: dict) -> str:
        return str(option.get("kind") or "").lower() + " " + str(option.get("name") or "").lower()

    for option in rows:
        if fallback in words(option) and "always" not in words(option):
            return option.get("optionId")
    for option in rows:
        if fallback in words(option):
            return option.get("optionId")
    return None


def parse(obj: dict) -> tuple | None:
    method = obj.get("method")
    params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
    if isinstance(method, str):
        if method == "session/update":
            return ("update", str(params.get("sessionId") or ""), update_event(params.get("update")))
        if method == "session/request_permission":
            ident = obj.get("id")
            session_id = str(params.get("sessionId") or "")
            tool = params.get("toolCall") if isinstance(params.get("toolCall"), dict) else {}
            options = params.get("options") if isinstance(params.get("options"), list) else []
            return ("permission", {
                "id": f"{session_id}:{ident}",
                "sessionID": session_id,
                "rpcID": ident,
                "title": params.get("title") or tool.get("title") or "Approve this action",
                "allow": option_id(options, "allow_once", "allow"),
                "deny": option_id(options, "reject_once", "reject"),
            })
        if method == "_x.ai/session/prompt_complete":
            session_id = str(params.get("sessionId") or "")
            reason = str(params.get("stopReason") or "") or "end_turn"
            return ("update", session_id, ("turnComplete", str(params.get("promptId") or ""), reason))
        if method == "_x.ai/queue/changed":
            running = params.get("runningPromptId")
            if isinstance(params.get("sessionId"), str) and isinstance(running, str) and running:
                return ("update", params["sessionId"], ("turnStarted", running))
            return ("notification", method)
        if method == "_x.ai/sessions/changed":
            rows = params.get("upserted") if isinstance(params.get("upserted"), list) else []
            activity = [
                (str(row["sessionId"]), row.get("activity") == "working")
                for row in rows
                if isinstance(row, dict) and row.get("sessionId") and isinstance(row.get("activity"), str)
            ]
            return ("activity", activity) if activity else ("notification", method)
        return ("notification", method)
    if "error" in obj:
        error = obj["error"] if isinstance(obj["error"], dict) else {}
        return ("failure", obj.get("id"), str(error.get("message") or "The agent reported an error."))
    if "result" in obj:
        return ("result", obj.get("id"), obj)
    return None


def running_prompt_id(load_result: dict) -> str | None:
    result = load_result.get("result") if isinstance(load_result.get("result"), dict) else {}
    meta = result.get("_meta") if isinstance(result.get("_meta"), dict) else {}
    value = meta.get("x.ai/runningPromptId")
    return value if isinstance(value, str) and value else None


# ChatFold (Core/Sources/WatchRemoteCore/ChatFold.swift)


class ChatFold:
    def __init__(self, live: bool) -> None:
        self.live = live
        self.tool_lines: dict[str, int] = {}

    def forget_tools(self) -> None:
        self.tool_lines = {}

    def apply(self, event: tuple, lines: list[str]) -> list[str]:
        kind = event[0]
        if kind == "user":
            return merging_user_echo(event[1], lines) if self.live else streaming_speaker("You:", event[1], lines)
        if kind == "text":
            return streaming_speaker("Grok:", event[1], lines)
        if kind == "tool":
            return append(tool_card(event[1]), lines)
        if kind == "toolCall":
            return self._card(event[1], event[2], lines)
        if kind == "toolCallUpdate":
            if event[2] is None:
                return lines
            return self._card(event[1], event[2], lines)
        return lines

    def _card(self, ident: str, title: str, lines: list[str]) -> list[str]:
        line = tool_card(title)
        index = self.tool_lines.get(ident)
        if index is not None and index < len(lines) and is_tool_card(lines[index]):
            if lines[index] == line:
                return lines
            copy = list(lines)
            copy[index] = line
            return copy
        appended = append(line, lines)
        if len(appended) > len(lines):
            self.tool_lines[ident] = len(appended) - 1
        return appended

    @staticmethod
    def replay(events: list[tuple]) -> list[str]:
        fold = ChatFold(live=False)
        lines: list[str] = []
        for event in events:
            lines = fold.apply(event, lines)
        return lines


class TurnTracker:
    """TurnTracker (ChatFold.swift): when a chat's turn is over."""

    def __init__(self) -> None:
        self.unstarted = 0
        self.running: str | None = None
        self.generation = 0

    def sent(self) -> int:
        self.unstarted += 1
        self.generation += 1
        return self.generation

    def started(self, prompt_id: str) -> None:
        if self.running == prompt_id:
            return
        self.running = prompt_id
        self.unstarted = max(0, self.unstarted - 1)

    def completed(self, prompt_id: str) -> bool:
        if self.unstarted:
            return False
        if self.running is not None and prompt_id and self.running != prompt_id:
            return False
        self.running = None
        return True

    def answered(self, generation: int) -> bool:
        if generation != self.generation:
            return False
        self.unstarted = 0
        self.running = None
        return True

    def loaded(self, running_prompt_id: str | None) -> None:
        self.running = running_prompt_id
        self.unstarted = 0


# SessionResume.merge (Core/Sources/WatchRemoteCore/SessionResume.swift)


def prompt_key(line: str) -> str:
    return " ".join(spoken_text(line).split()).lower()


def merge(local: list[str], host: list[str]) -> list[str]:
    return keeping_trailing_space(host, merged_lines(local, host))


def keeping_trailing_space(host: list[str], merged: list[str]) -> list[str]:
    raw = next((line for line in reversed(host) if line.strip()), None)
    if not merged or raw is None:
        return merged
    last = merged[-1]
    if raw == last or not raw.startswith(last) or raw.strip() != last:
        return merged
    return merged[:-1] + [raw]


def merged_lines(local: list[str], host: list[str]) -> list[str]:
    host_chat = chat_lines(host)
    local_chat = chat_lines(local)
    host_prompts = [prompt_key(line) for line in host_chat if line.startswith("You:")]
    if not host_prompts:
        return local_chat if len(local_chat) > len(host_chat) else host_chat
    following = 0
    tail_start = None
    for index, line in enumerate(local_chat):
        if not line.startswith("You:"):
            continue
        key = prompt_key(line)
        if key in host_prompts[following:]:
            following = host_prompts.index(key, following) + 1
            tail_start = None
        elif tail_start is None:
            tail_start = index
    if tail_start is None:
        return host_chat
    return host_chat + local_chat[tail_start:]


# The link (App/iOS/Services/LiveLink.swift, Core DoorLink.swift)


class LinkState:
    """One app process talking to one computer: a link id, frames seen on it, request ids."""

    def __init__(self, link_id: str) -> None:
        self.link_id = link_id
        self.seen = 0
        self.next_id = 1
        self.attachments = 0
        self.lock = threading.Lock()

    def take_id(self) -> int:
        with self.lock:
            ident = self.next_id
            self.next_id += 1
            return ident


class DoorError(Exception):
    pass


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
    return bytes(header) + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


def _parse_frame(buffer: bytes) -> tuple[int, bytes, int] | None:
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
    total = offset + length
    if len(buffer) < total:
        return None
    return buffer[0] & 0x0F, buffer[offset:total], total


class Pipe:
    """ACPPipe: one WebSocket through the door. Captures load replays per chat."""

    def __init__(
        self,
        link: LinkState,
        address: tuple[str, int],
        secret: str,
        on_frame: Callable[[str, str, dict], None],
        on_inbound: Callable[["Pipe", tuple], None],
    ) -> None:
        link.attachments += 1
        self.link = link
        self.label = f"{link.link_id[:8]}#{link.attachments}"
        self.on_frame = on_frame
        self.on_inbound = on_inbound
        self.lock = threading.Lock()
        self.waiters: dict[int, dict] = {}
        self.done: dict[int, threading.Event] = {}
        self.captures: dict[str, list[tuple]] = {}
        self.loads: dict[int, str] = {}
        self.replays: dict[str, list[tuple]] = {}
        self.held: dict[str, list[tuple]] = {}
        self.dead = False
        self.sock = socket.create_connection(address, timeout=10)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        # WebSocketFramer.upgradeRequest, in the same line order.
        lines = [
            "GET /ws HTTP/1.1",
            f"Host: 127.0.0.1:{address[1]}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
            f"Authorization: Bearer {secret}",
            f"X-WatchRemote-Link: {link.link_id}",
            f"X-WatchRemote-Seen: {link.seen}",
            "",
            "",
        ]
        self.sock.sendall("\r\n".join(lines).encode("ascii"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise DoorError("The door closed the connection during the handshake.")
            head += chunk
        text = head.decode("iso-8859-1")
        if " 101 " not in text.split("\r\n", 1)[0] + " ":
            raise DoorError("The door refused the connection: " + text.split("\r\n", 1)[0])
        headers = {}
        for line in text.split("\r\n")[1:]:
            name, sep, value = line.partition(":")
            if sep:
                headers[name.strip().lower()] = value.strip()
        self.door_version = int(headers.get("x-watchremote-door", "0") or 0) if headers.get("x-watchremote-door", "0").isdigit() else 0
        self.resumed = headers.get("x-watchremote-resumed", "").lower() == "yes"
        if not self.resumed:
            link.seen = 0
        self.sock.settimeout(None)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        buffer = b""
        try:
            while True:
                parsed = _parse_frame(buffer)
                if parsed is None:
                    chunk = self.sock.recv(65536)
                    if not chunk:
                        break
                    buffer += chunk
                    continue
                opcode, payload, size = parsed
                buffer = buffer[size:]
                if opcode == 9:
                    self.sock.sendall(_client_frame(10, payload))
                    continue
                if opcode == 8:
                    break
                if opcode != 1:
                    continue
                self.link.seen += 1
                try:
                    obj = json.loads(payload)
                except (UnicodeError, json.JSONDecodeError):
                    continue
                if not isinstance(obj, dict):
                    continue
                self.on_frame(self.label, "in", obj)
                inbound = parse(obj)
                if inbound is not None:
                    self._route(inbound)
        except OSError:
            pass
        self._fail()

    def _route(self, inbound: tuple) -> None:
        kind = inbound[0]
        if kind in {"result", "failure"}:
            ident = inbound[1]
            if isinstance(ident, int):
                with self.lock:
                    event = self.done.get(ident)
                    if event is not None:
                        self.waiters[ident] = inbound[2] if kind == "result" else {"error": inbound[2]}
                    loading = self.loads.pop(ident, None)
                    if loading is not None:
                        # endReplay: the replay is complete; later frames wait for releaseHeld.
                        self.replays[loading] = self.captures.pop(loading, [])
                        self.held.setdefault(loading, [])
                if event is not None:
                    event.set()
            return
        session_id = inbound[1] if kind == "update" else inbound[1]["sessionID"] if kind == "permission" else None
        if session_id is not None:
            with self.lock:
                held = self.held.get(session_id)
                if held is not None:
                    held.append(inbound)
                    return
                capture = self.captures.get(session_id)
                if capture is not None and kind == "update":
                    capture.append(inbound[2])
                    return
        self.on_inbound(self, inbound)

    def release_held(self, session_id: str) -> list[tuple]:
        """Frames for this chat that came after its load result, for after the merge (LiveLink.releaseHeld)."""
        with self.lock:
            return self.held.pop(session_id, [])

    def _fail(self) -> None:
        with self.lock:
            if self.dead:
                return
            self.dead = True
            events = list(self.done.values())
        for event in events:
            event.set()

    def drop(self) -> None:
        """What iOS does to a suspended app's socket: gone, with no close frame."""
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        self._fail()

    def send(self, obj: dict) -> None:
        text = json.dumps(obj, separators=(",", ":"))
        self.on_frame(self.label, "out", obj)
        self.sock.sendall(_client_frame(1, text.encode("utf-8")))

    def request(self, method: str, params: dict, timeout: float | None = 12, loading: str | None = None) -> dict:
        ident = self.link.take_id()
        event = threading.Event()
        with self.lock:
            self.done[ident] = event
            if loading is not None:
                self.loads[ident] = loading
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        event.wait(timeout)
        with self.lock:
            self.done.pop(ident, None)
            result = self.waiters.pop(ident, None)
        if result is None:
            raise DoorError(f"{method} got no answer" + (" (connection closed)" if self.dead else ""))
        if "error" in result and "result" not in result:
            raise DoorError(f"{method} failed: {result['error']}")
        return result

    # ACPCodec requests, same objects.

    def initialize(self) -> dict:
        return self.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            "clientInfo": {"name": "Watch Remote", "version": "1.0"},
        })

    def new_session(self, cwd: str) -> str:
        result = self.request("session/new", {"cwd": cwd, "mcpServers": [], "_meta": {"yoloMode": False, "autoMode": False}})
        session_id = (result.get("result") or {}).get("sessionId")
        if not session_id:
            raise DoorError("session/new returned no session")
        return session_id

    def list_sessions(self) -> list[dict]:
        result = self.request("_x.ai/session/list", {})
        payload = result.get("result") or {}
        if isinstance(payload, dict) and isinstance(payload.get("result"), dict):
            payload = payload["result"]
        rows = payload.get("sessions") if isinstance(payload, dict) else []
        return [row for row in rows or [] if isinstance(row, dict)]

    def load_captured(self, session_id: str, cwd: str) -> tuple[dict, list[tuple]]:
        """The load result and its replay. Later frames for the chat are held until release_held."""
        with self.lock:
            self.captures[session_id] = []
        try:
            result = self.request("session/load", {"sessionId": session_id, "cwd": cwd, "mcpServers": []}, timeout=30,
                                  loading=session_id)
        except DoorError:
            with self.lock:
                self.captures.pop(session_id, None)
                self.replays.pop(session_id, None)
                held = self.held.pop(session_id, [])
            for inbound in held:
                self.on_inbound(self, inbound)
            raise
        with self.lock:
            replay = self.replays.pop(session_id, self.captures.pop(session_id, []))
        return result, replay

    def prompt_async(self, session_id: str, text: str, on_done: Callable[[dict | None], None]) -> int:
        ident = self.link.take_id()
        event = threading.Event()
        with self.lock:
            self.done[ident] = event
        self.send({"jsonrpc": "2.0", "id": ident, "method": "session/prompt", "params": {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": text}],
        }})

        def wait() -> None:
            event.wait()
            with self.lock:
                self.done.pop(ident, None)
                result = self.waiters.pop(ident, None)
            on_done(result)

        threading.Thread(target=wait, daemon=True).start()
        return ident

    def answer(self, permission: dict, allow: bool) -> None:
        option = permission["allow"] if allow else permission["deny"]
        outcome = {"outcome": "selected", "optionId": option} if option else {"outcome": "cancelled"}
        self.send({"jsonrpc": "2.0", "id": permission["rpcID"], "result": {"outcome": outcome}})


# RemoteStore, SSH mode (App/iOS/Services/RemoteStore.swift)


class Chat:
    def __init__(self, session_id: str, title: str = "") -> None:
        self.id = session_id
        self.title = title
        self.transcript: list[str] = []
        self.status = "idle"
        self.permission: dict | None = None
        self.fold = ChatFold(live=True)
        self.turns = TurnTracker()
        self.prompt_ids: list[str] = []


class PhoneModel:
    def __init__(self, cwd: str, auto_approve: bool, record: Callable[[dict], None]) -> None:
        self.cwd = cwd
        self.auto_approve = auto_approve
        self.record = record
        self.chats: dict[str, Chat] = {}
        self.pipe: Pipe | None = None
        self.cond = threading.Condition()
        self.answered: set[str] = set()
        self.permissions_seen: list[dict] = []
        self.queue_running: dict[str, tuple[str, str]] = {}
        self.completed: dict[str, list[str]] = {}
        self.prompt_results: dict[str, list[dict]] = {}

    def chat(self, session_id: str) -> Chat:
        if session_id not in self.chats:
            self.chats[session_id] = Chat(session_id)
        return self.chats[session_id]

    def on_frame(self, label: str, direction: str, obj: dict) -> None:
        self.record({"k": direction, "c": label, "f": obj})
        method = obj.get("method")
        params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
        if direction == "in" and method == "_x.ai/queue/changed" and params.get("runningPromptId"):
            with self.cond:
                self.queue_running[str(params.get("runningPromptId"))] = (str(params.get("sessionId") or ""), str(params.get("runningText") or ""))
        if direction == "in" and method == "_x.ai/session/prompt_complete":
            with self.cond:
                self.completed.setdefault(str(params.get("sessionId") or ""), []).append(str(params.get("promptId") or ""))

    def on_inbound(self, pipe: Pipe, inbound: tuple) -> None:
        with self.cond:
            kind = inbound[0]
            if kind == "update":
                self._apply_stream(inbound[1], inbound[2])
            elif kind == "permission":
                request = inbound[1]
                self.permissions_seen.append(request)
                chat = self.chat(request["sessionID"])
                chat.status = "needsApproval"
                chat.permission = request
                # A request that comes again (resent after a reconnect) is still unanswered.
                self.answered.discard(request["id"])
                self._consider_auto_approve(pipe, chat)
            elif kind == "activity":
                for session_id, working in inbound[1]:
                    chat = self.chats.get(session_id)
                    if chat is None:
                        continue
                    if working and chat.status in {"idle", "stopped", "failed"}:
                        chat.status = "running"
            self.cond.notify_all()

    def _consider_auto_approve(self, pipe: Pipe, chat: Chat) -> None:
        request = chat.permission
        if request is None or not self.auto_approve or request["id"] in self.answered:
            return
        self.answered.add(request["id"])
        chat.transcript = noting_auto_approval(request["title"], chat.transcript)
        self.record({"k": "ui", "a": "autoApproved", "s": chat.id, "title": request["title"]})
        pipe.answer(request, True)
        chat.permission = None
        chat.status = "running"

    def _apply_stream(self, session_id: str, event: tuple) -> None:
        chat = self.chats.get(session_id)
        if chat is None:
            return
        kind = event[0]
        if kind in {"user", "text", "tool", "toolCall", "toolCallUpdate"}:
            chat.transcript = chat.fold.apply(event, chat.transcript)
            if kind != "toolCallUpdate":
                chat.status = "running" if chat.status != "needsApproval" else chat.status
        elif kind == "title":
            chat.title = event[1]
        elif kind == "turnStarted":
            chat.turns.started(event[1])
            if chat.status != "needsApproval":
                chat.status = "running"
        elif kind == "turnComplete":
            if chat.turns.completed(event[1]):
                chat.permission = None
                chat.status = "stopped" if event[2] == "cancelled" else "idle"

    def attach(self, pipe: Pipe) -> None:
        self.pipe = pipe

    def start(self, prompt: str) -> str:
        """startSSH: the prompt is on screen first, then the chat is created, then the prompt is sent."""
        assert self.pipe is not None
        pipe = self.pipe
        session_id = pipe.new_session(self.cwd)
        with self.cond:
            chat = self.chat(session_id)
            chat.title = " ".join(prompt.split()[:6])
            chat.transcript = append(f"You: {prompt}", chat.transcript)
            chat.status = "running"
            generation = chat.turns.sent()
            self.record({"k": "ui", "a": "prompt", "s": session_id, "text": prompt})
        self._send_prompt(pipe, session_id, prompt, generation)
        return session_id

    def continue_chat(self, session_id: str, prompt: str) -> None:
        """continueSSH: show the prompt, load the chat (host order wins), then send the prompt."""
        assert self.pipe is not None
        pipe = self.pipe
        with self.cond:
            chat = self.chat(session_id)
            chat.transcript = append(f"You: {prompt}", chat.transcript)
            chat.status = "running"
            generation = chat.turns.sent()
            self.record({"k": "ui", "a": "prompt", "s": session_id, "text": prompt})
        self._load_and_merge(pipe, session_id, keep_running=True)
        self._send_prompt(pipe, session_id, prompt, generation)

    def resume(self, session_id: str) -> dict:
        """resumeSSH: load the chat and take the computer's order. A running turn stays running."""
        assert self.pipe is not None
        return self._load_and_merge(self.pipe, session_id, keep_running=False)

    def set_cache(self, session_id: str, lines: list[str]) -> None:
        with self.cond:
            chat = self.chat(session_id)
            chat.transcript = list(lines)
            chat.fold.forget_tools()
            self.record({"k": "ui", "a": "cache", "s": session_id, "lines": list(lines)})

    def _load_and_merge(self, pipe: Pipe, session_id: str, keep_running: bool) -> dict:
        result, replay = pipe.load_captured(session_id, self.cwd)
        with self.cond:
            chat = self.chat(session_id)
            host = ChatFold.replay(replay)
            chat.transcript = merge(chat.transcript, host)
            chat.fold.forget_tools()
            if not keep_running:
                running = running_prompt_id(result)
                chat.turns.loaded(running)
                if chat.permission is None:
                    chat.status = "running" if running else "idle"
            # adoptHeld: what came after the load result applies on top of the merged chat.
            for inbound in pipe.release_held(session_id):
                self.on_inbound(pipe, inbound)
            self.cond.notify_all()
        return result

    def _send_prompt(self, pipe: Pipe, session_id: str, prompt: str, generation: int) -> None:
        def done(result: dict | None) -> None:
            if result is None:
                # Disconnected mid-turn. The turn keeps running on the computer; prompt_complete ends it.
                return
            with self.cond:
                self.prompt_results.setdefault(session_id, []).append(result)
                chat = self.chat(session_id)
                if "error" in result and "result" not in result:
                    if chat.turns.answered(generation):
                        chat.status = "failed"
                else:
                    meta = (result.get("result") or {}).get("_meta") or {}
                    if meta.get("promptId"):
                        chat.prompt_ids.append(str(meta["promptId"]))
                    reason = (result.get("result") or {}).get("stopReason") or "end_turn"
                    if chat.turns.answered(generation):
                        chat.permission = None
                        chat.status = "stopped" if reason == "cancelled" else "idle"
                self.cond.notify_all()

        pipe.prompt_async(session_id, prompt, done)

    def wait(self, predicate: Callable[[], bool], timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        with self.cond:
            while not predicate():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.cond.wait(min(remaining, 0.5))
            return True
