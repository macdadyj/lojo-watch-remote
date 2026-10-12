#!/usr/bin/env python3
"""Outbound direct mode. The computer connects to the relay. The Watch does too.

Frames are sealed with the pairing key. The relay only forwards ciphertext.
SSH from the iPhone is unchanged.
"""

from __future__ import annotations

import base64
import json
import os
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))

import miniws  # noqa: E402
import relaybox  # noqa: E402


AGENT_DOWN = "The agent server on this computer is not answering."
MISSING_SESSION = "That chat is no longer on this computer."
NOTHING_RECORDED = "Nothing was recorded."
NO_TRANSCRIBER = "No transcriber is configured on this computer."


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

    def restore(self, session_id: str) -> list[str]:
        raise RuntimeError(AGENT_DOWN)

    def continue_session(self, session_id: str, prompt: str, cwd: str) -> str:
        raise RuntimeError(AGENT_DOWN)

    def transcribe(self, audio: object) -> str:
        raise RuntimeError(AGENT_DOWN)

    def take_update(self) -> dict | None:
        return None


class MemoryAgent:
    """In-memory stand-in used by tests. The shape matches what the Watch decodes."""

    def __init__(self, rows: list | None = None) -> None:
        self.available = True
        self.rows = [dict(row) for row in rows] if rows else []
        self.started: list[str] = []
        self.decisions: list[tuple[str, str, bool]] = []
        self.stopped: list[str] = []
        self._push: dict | None = None
        self._queued: list[tuple[str, str]] = []
        self._push_n = 0

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
        self._queued.append((session_id, prompt))
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

    def restore(self, session_id: str) -> list[str]:
        for row in self.rows:
            if row.get("id") != session_id:
                continue
            stored = row.get("lines")
            if isinstance(stored, list):
                lines = [str(item).strip() for item in stored if str(item).strip()]
                if lines:
                    return lines
            title = str(row.get("title") or "").strip()
            summary = str(row.get("summary") or "").strip()
            fallback = [part for part in (title, summary) if part]
            return fallback or ["Session"]
        raise RuntimeError(MISSING_SESSION)

    def continue_session(self, session_id: str, prompt: str, cwd: str) -> str:
        for row in self.rows:
            if row.get("id") == session_id:
                self.started.append(prompt)
                row["status"] = "running"
                row["summary"] = clip(prompt) or "Continuing."
                if cwd:
                    row["cwd"] = cwd
                self._queued.append((session_id, prompt))
                return session_id
        raise RuntimeError(MISSING_SESSION)

    def transcribe(self, audio: object) -> str:
        raw = audio if isinstance(audio, str) else ""
        if not raw.strip():
            raise RuntimeError(NOTHING_RECORDED)
        return "list sessions"

    def take_update(self) -> dict | None:
        if not self._queued:
            return None
        session_id, prompt = self._queued.pop(0)
        reply = reply_line(prompt)
        spoken = reply.split(":", 1)[-1].strip()
        you = f"You: {prompt}" if prompt else ""
        for row in self.rows:
            if row.get("id") != session_id:
                continue
            lines = [str(item) for item in (row.get("lines") or []) if str(item).strip()]
            if you and (not lines or lines[-1] != you):
                lines.append(you)
            lines.append(reply)
            row["lines"] = lines
            row["status"] = "idle"
            row["summary"] = spoken or "Done."
        self._push_n += 1
        return {
            "op": "update",
            "id": f"push-{self._push_n}",
            "sessions": [for_watch(row) for row in self.rows],
            "approvalsAvailable": True,
        }


def reply_line(prompt: str) -> str:
    """Canned host reply. The Watch test looks for these exact sentences."""
    folded = " ".join(prompt.split()).lower()
    if folded == "again":
        return "Grok: Heard again."
    if folded.startswith("reopen"):
        return "Grok: Reopened."
    return "Grok: I can hear you."


def for_watch(row: dict) -> dict:
    """The Watch decodes `transcript`. The host stores the same lines under `lines`."""
    if not isinstance(row, dict):
        return row
    copy = dict(row)
    lines = copy.get("lines")
    if isinstance(lines, list):
        transcript = [str(item).strip() for item in lines if str(item).strip()]
        if transcript:
            copy["transcript"] = transcript
    return copy


PUSH_INTERVAL = 0.5
WATCH_SESSIONS = 24
FOCUS_LINES = 40
OTHER_LINES = 4
RESTORE_LINES = 80
LINE_LIMIT = 2000
# The relay refuses frames over 256 KB; stay far below it once sealed and base64'd.
WATCH_BUDGET = 96 * 1024
# A frame the relay refuses also costs the computer its relay connection, so nothing larger leaves.
FRAME_BUDGET = 160 * 1024
TOO_LARGE = "That reply was too large for the Watch."


def watch_rows(rows: list, focus: set[str] | None = None, budget: int = WATCH_BUDGET) -> list[dict]:
    """Rows for the Watch: recent sessions only, transcripts trimmed to fit one frame."""
    focus = focus or set()
    chosen = [row for row in rows if isinstance(row, dict)][:WATCH_SESSIONS]
    out: list[dict] = []
    for row in chosen:
        copy = for_watch(row)
        lines = copy.get("transcript")
        if isinstance(lines, list):
            keep = FOCUS_LINES if str(copy.get("id")) in focus else OTHER_LINES
            copy["transcript"] = [clip_line(line) for line in lines[-keep:]]
        copy.pop("lines", None)
        out.append(copy)
    while len(json.dumps(out, separators=(",", ":"))) > budget:
        longest = max(out, key=lambda item: len(item.get("transcript") or []), default=None)
        if not longest or len(longest.get("transcript") or []) <= 1:
            out = out[:-1]
            if not out:
                break
            continue
        longest["transcript"] = longest["transcript"][len(longest["transcript"]) // 2 :]
    return out


def watch_lines(lines: list, keep: int = RESTORE_LINES, budget: int = WATCH_BUDGET) -> list[str]:
    """The latest transcript lines of one chat, trimmed to fit one frame."""
    out = [clip_line(str(line)) for line in lines if str(line).strip()][-keep:]
    while len(out) > 1 and len(json.dumps(out, separators=(",", ":"))) > budget:
        out = out[len(out) // 2 :]
    return out


def fit_for_watch(message: dict) -> dict:
    """Shrinks a reply that would be over the relay's frame limit, or swaps it for an error."""
    if len(relaybox.encode_message(message)) <= FRAME_BUDGET:
        return message
    copy = dict(message)
    op = message.get("op")
    if op in {"sessions", "update"}:
        copy["sessions"] = watch_rows(list(message.get("sessions") or []), budget=FRAME_BUDGET // 2)
    elif op == "restored":
        copy["lines"] = watch_lines(list(message.get("lines") or []), budget=FRAME_BUDGET // 2)
    if len(relaybox.encode_message(copy)) <= FRAME_BUDGET:
        return copy
    return {"op": "error", "id": str(message.get("id") or ""), "message": TOO_LARGE}


def clip_line(line: str) -> str:
    text = str(line)
    return text if len(text) <= LINE_LIMIT else text[: LINE_LIMIT - 1] + "…"


class ApprovalPolicy:
    """Auto-approve choice sent by the Watch: a default plus per-chat overrides."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path
        self.default = False
        self.chats: dict[str, bool] = {}
        if path is not None and path.is_file():
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                raw = {}
            if isinstance(raw, dict):
                self.default = raw.get("default") is True
                chats = raw.get("chats")
                if isinstance(chats, dict):
                    self.chats = {str(key): value for key, value in chats.items() if isinstance(value, bool)}

    def allows(self, session_id: str) -> bool:
        return self.chats.get(str(session_id or ""), self.default)

    def note(self, message: dict) -> bool:
        """Apply `autoApprove` from a Watch message. True when something changed."""
        value = message.get("autoApprove")
        if not isinstance(value, bool):
            return False
        session_id = str(message.get("sessionID") or "").strip()
        if session_id:
            if self.chats.get(session_id) == value:
                return False
            self.chats[session_id] = value
            if len(self.chats) > 200:
                for key in list(self.chats)[: len(self.chats) - 200]:
                    self.chats.pop(key, None)
        else:
            if self.default == value:
                return False
            self.default = value
        self._save()
        return True

    def _save(self) -> None:
        if self.path is None:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(self.path.name + ".tmp")
            temporary.write_text(json.dumps({"default": self.default, "chats": self.chats}), encoding="utf-8")
            temporary.chmod(0o600)
            os.replace(temporary, self.path)
        except OSError:
            pass


def merge_session_rows(previous: list, fresh: list) -> list:
    """Keep transcript lines when a session list arrives in the middle of a reply."""
    prior = {str(row.get("id")): row for row in previous if isinstance(row, dict) and row.get("id")}
    merged: list[dict] = []
    seen: set[str] = set()
    for row in fresh:
        if not isinstance(row, dict) or not row.get("id"):
            continue
        copy = dict(row)
        old = prior.get(str(copy.get("id")))
        if old:
            lines = old.get("lines")
            if isinstance(lines, list) and lines:
                copy["lines"] = list(lines)
            if old.get("status") == "running" and copy.get("status") not in {"needsApproval", "failed"}:
                copy["status"] = "running"
                summary = str(old.get("summary") or "")
                if summary:
                    copy["summary"] = summary
        merged.append(copy)
        seen.add(str(copy.get("id")))
    for row in previous:
        if not isinstance(row, dict):
            continue
        session_id = str(row.get("id") or "")
        if session_id and session_id not in seen and row.get("status") == "running":
            merged.insert(0, dict(row))
    return merged


def wav_bytes(pcm: bytes, sample_rate: int = 16000) -> bytes:
    rate = sample_rate if sample_rate > 0 else 16000
    channels = 1
    bits = 16
    block_align = channels * bits // 8
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(pcm),
        b"WAVE",
        b"fmt ",
        16,
        1,
        channels,
        rate,
        rate * block_align,
        block_align,
        bits,
        b"data",
        len(pcm),
    )
    return header + pcm


def transcribe_audio(
    audio: object,
    *,
    environ: dict[str, str] | None = None,
    which=None,
    run=None,
) -> str:
    """Turn one Watch utterance into text.

    `WATCHREMOTE_STT_COMMAND` is run as `[command, wavpath]` with no shell.
    Otherwise a `whisper` binary is used when one is configured or on `PATH`.
    """
    env = os.environ if environ is None else environ
    finder = shutil.which if which is None else which
    runner = subprocess.run if run is None else run
    raw = audio.strip() if isinstance(audio, str) else ""
    if not raw:
        raise RuntimeError(NOTHING_RECORDED)
    try:
        pcm = base64.b64decode(raw, validate=False)
    except (ValueError, TypeError) as error:
        raise RuntimeError("The recording could not be read.") from error
    if not pcm:
        raise RuntimeError(NOTHING_RECORDED)
    wav = wav_bytes(pcm)
    command = str(env.get("WATCHREMOTE_STT_COMMAND") or "").strip()
    if command:
        return _transcribe_with_command(command, wav, runner)
    whisper = str(env.get("WATCHREMOTE_WHISPER") or "").strip()
    if not whisper:
        whisper = finder("whisper") or ""
    if not whisper:
        raise RuntimeError(NO_TRANSCRIBER)
    model = str(env.get("WATCHREMOTE_WHISPER_MODEL") or "tiny").strip() or "tiny"
    return _transcribe_with_whisper(whisper, model, wav, runner)


def _transcribe_with_command(command: str, wav: bytes, runner) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "utterance.wav"
        path.write_bytes(wav)
        completed = runner(
            [command, str(path)],
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        return _transcript_stdout(completed, "The transcriber did not return text.")


def _transcribe_with_whisper(binary: str, model: str, wav: bytes, runner) -> str:
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        path = folder / "utterance.wav"
        path.write_bytes(wav)
        completed = runner(
            [
                binary,
                str(path),
                "--model",
                model,
                "--output_format",
                "txt",
                "--output_dir",
                str(folder),
            ],
            capture_output=True,
            text=True,
            shell=False,
            check=False,
        )
        if getattr(completed, "returncode", 1) != 0:
            detail = str(getattr(completed, "stderr", "") or "").strip()
            raise RuntimeError(detail or "Whisper did not transcribe that audio.")
        text_path = folder / "utterance.txt"
        if text_path.is_file():
            text = text_path.read_text(encoding="utf-8").strip()
            if text:
                return text
        text = str(getattr(completed, "stdout", "") or "").strip()
        if text:
            return text
        raise RuntimeError("Whisper did not transcribe that audio.")


def _transcript_stdout(completed: object, empty: str) -> str:
    code = getattr(completed, "returncode", 1)
    stdout = str(getattr(completed, "stdout", "") or "").strip()
    stderr = str(getattr(completed, "stderr", "") or "").strip()
    if code != 0 or not stdout:
        raise RuntimeError(stderr or empty)
    return stdout


def handle(agent: object, message: dict) -> dict:
    op = message.get("op")
    ident = str(message.get("id") or "")
    approvals = getattr(agent, "approvals", None)
    if approvals is not None and op in {"ping", "list", "resume"} and approvals.note(message):
        approve_waiting = getattr(agent, "approve_waiting", None)
        if approve_waiting is not None:
            try:
                approve_waiting()
            except (RuntimeError, OSError):
                pass
    try:
        if op == "ping":
            return {"op": "pong", "id": ident}
        if op == "list":
            focus = getattr(agent, "watch_focus", None)
            return {
                "op": "sessions",
                "id": ident,
                "sessions": watch_rows(agent.list_sessions(), focus() if focus else None),
                "approvalsAvailable": bool(getattr(agent, "available", True)),
            }
        if op == "start":
            prompt = str(message.get("prompt") or "").strip()
            if not prompt:
                return {"op": "error", "id": ident, "message": "Say what the task should do."}
            session_id = str(message.get("sessionID") or "").strip()
            if session_id:
                if approvals is not None:
                    approvals.note({"autoApprove": message.get("autoApprove"), "sessionID": session_id})
                continued = agent.continue_session(session_id, prompt, str(message.get("cwd") or ""))
                return {"op": "started", "id": ident, "sessionID": continued}
            session_id = agent.start(prompt, str(message.get("cwd") or ""))
            if approvals is not None:
                approvals.note({"autoApprove": message.get("autoApprove"), "sessionID": session_id})
            return {"op": "started", "id": ident, "sessionID": session_id}
        if op == "resume":
            session_id = str(message.get("sessionID") or "").strip()
            lines = watch_lines(agent.restore(session_id))
            return {"op": "restored", "id": ident, "sessionID": session_id, "lines": lines}
        if op == "approve":
            agent.decide(message.get("sessionID"), message.get("permissionID"), True)
            return {"op": "ok", "id": ident}
        if op == "deny":
            agent.decide(message.get("sessionID"), message.get("permissionID"), False)
            return {"op": "ok", "id": ident}
        if op == "stop":
            agent.stop(str(message.get("sessionID") or ""))
            return {"op": "ok", "id": ident}
        if op == "transcribe":
            text = str(agent.transcribe(message.get("audio")) or "").strip()
            if not text:
                return {"op": "error", "id": ident, "message": NOTHING_RECORDED}
            return {"op": "transcript", "id": ident, "message": text}
        return {"op": "error", "id": ident, "message": "That command is not supported."}
    except RuntimeError as error:
        text = str(error).strip() or "The computer could not do that."
        return {"op": "error", "id": ident, "message": text}
    except (OSError, miniws.SocketError):
        if hasattr(agent, "broken"):
            agent.broken = True
        return {"op": "error", "id": ident, "message": AGENT_DOWN}
    except Exception as error:  # noqa: BLE001 - the Watch gets an answer instead of a dead host
        print(f"Command failed: {type(error).__name__}", file=sys.stderr)
        return {"op": "error", "id": ident, "message": "The computer could not do that."}


class ACPAgent:
    available = True

    def __init__(self, secret: str, host: str = "127.0.0.1", port: int = 2419, approvals: "ApprovalPolicy | None" = None) -> None:
        self.broken = False
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
        self.capture_replay = False
        self.replay_lines: list[str] = []
        self.awaiting_prompt: dict[int, str] = {}
        self.loaded: set[str] = set()
        self.urgent = False
        self.last_push = 0.0
        self.approvals = approvals if approvals is not None else ApprovalPolicy()

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
        result = self.request("_x.ai/session/list", {})
        fresh = sessions_from(result.get("result"))
        self.rows = merge_session_rows(self.rows, fresh)
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
        row = {
            "id": session_id,
            "title": title_from(prompt),
            "summary": "Starting.",
            "status": "running",
            "cwd": directory,
        }
        self.rows = [row] + [item for item in self.rows if item.get("id") != session_id]
        self.loaded.add(session_id)
        self._arm_prompt(session_id, prompt)
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

    def restore(self, session_id: str) -> list[str]:
        if not session_id:
            raise RuntimeError(MISSING_SESSION)
        rows = self.list_sessions()
        match = next((row for row in rows if row.get("id") == session_id), None)
        if match is None:
            raise RuntimeError(MISSING_SESSION)
        stored = match.get("lines") if isinstance(match.get("lines"), list) else []
        if session_id in self.loaded and stored:
            return list(stored)
        directory = str(match.get("cwd") or Path.home())
        self.replay_lines = []
        self.capture_replay = True
        try:
            loaded = self.request("session/load", {
                "sessionId": session_id,
                "cwd": directory,
                "mcpServers": [],
            })
        finally:
            self.capture_replay = False
        self.loaded.add(session_id)
        chosen = best_transcript(self.replay_lines, transcript_lines(loaded.get("result")), stored)
        if chosen:
            match["lines"] = chosen
            return chosen
        return []

    def continue_session(self, session_id: str, prompt: str, cwd: str) -> str:
        if session_id in self.awaiting_prompt.values():
            raise RuntimeError("Grok is still answering in that chat.")
        self.restore(session_id)
        for row in self.rows:
            if row.get("id") == session_id:
                row["status"] = "running"
                row["summary"] = "Continuing."
                if cwd:
                    row["cwd"] = cwd
        self._arm_prompt(session_id, prompt)
        return session_id

    def stop(self, session_id: str) -> None:
        self._send_raw({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session_id}})
        for row in self.rows:
            if row.get("id") == session_id:
                row["status"] = "stopped"
                row["summary"] = "Stopped."
                row.pop("permission", None)

    def transcribe(self, audio: object) -> str:
        return transcribe_audio(audio)

    def take_update(self, now: float | None = None) -> dict | None:
        """Streaming chunks are coalesced so the relay sees at most a few frames a second."""
        if not self.pending_push:
            return None
        moment = time.monotonic() if now is None else now
        if not self.urgent and moment - self.last_push < PUSH_INTERVAL:
            return None
        self.pending_push = False
        self.urgent = False
        self.last_push = moment
        self.push_n += 1
        return {
            "op": "update",
            "id": f"push-{self.push_n}",
            "sessions": watch_rows(self.rows, self.watch_focus()),
            "approvalsAvailable": True,
        }

    def watch_focus(self) -> set[str]:
        """Chats that keep their longer transcript on the Watch: answering or asking."""
        return set(self.awaiting_prompt.values()) | {key.split(":", 1)[0] for key in self.permissions}

    def request_push(self) -> None:
        """Send the current chats at once, e.g. after a relay reconnect lost the last push."""
        if self.rows:
            self.pending_push = True
            self.urgent = True

    def push_due_in(self, now: float | None = None) -> float | None:
        if not self.pending_push:
            return None
        if self.urgent:
            return 0.0
        moment = time.monotonic() if now is None else now
        return max(0.0, PUSH_INTERVAL - (moment - self.last_push))

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
                self._settle_prompt(ident, obj)

    def _arm_prompt(self, session_id: str, prompt: str) -> None:
        ident = self.next_id
        self.next_id += 1
        self._send(ident, "session/prompt", {
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": prompt}],
        })
        self.awaiting_prompt[ident] = session_id
        for row in self.rows:
            if row.get("id") == session_id:
                row["lines"] = fold_speaker(list(row.get("lines") or []), "You:", prompt)

    def _settle_prompt(self, ident: int, obj: dict) -> None:
        session_id = self.awaiting_prompt.pop(ident, None)
        if session_id is None:
            return
        failed = "error" in obj
        message = "The agent reported an error."
        if failed:
            error = obj.get("error")
            if isinstance(error, dict) and isinstance(error.get("message"), str):
                message = error["message"]
        for row in self.rows:
            if row.get("id") != session_id:
                continue
            if failed:
                row["status"] = "failed"
                row["summary"] = clip(message)
                continue
            if row.get("status") == "running":
                row["status"] = "idle"
            lines = row.get("lines") or []
            grok = next((str(line) for line in reversed(lines) if str(line).startswith("Grok:")), "")
            if grok:
                row["summary"] = clip(grok.split(":", 1)[-1].strip())
        self.pending_push = True
        self.urgent = True

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
        if allow and self.approvals.allows(session_id):
            self.permissions[permission_id] = {"rpc": rpc_text, "number": number, "allow": allow, "deny": deny, "permission": {}}
            self.decide(session_id, permission_id, True)
            for row in self.rows:
                if row.get("id") == session_id:
                    row["lines"] = list(row.get("lines") or []) + [f"Auto-approved: {clip(str(title), 120)}"]
                    row["summary"] = clip(f"Auto-approved: {title}")
            return
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
        self.permissions[permission_id] = {
            "rpc": rpc_text,
            "number": number,
            "allow": allow,
            "deny": deny,
            "permission": permission,
        }
        self.urgent = True
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
        if kind == "tool_call":
            title = clip(str(update.get("title") or "Tool"), 120)
            if self.capture_replay:
                self.replay_lines.append(f"Tool: {title}")
                return
            for row in self.rows:
                if row.get("id") == session_id:
                    row["lines"] = list(row.get("lines") or []) + [f"Tool: {title}"]
            return
        if kind in {"user_message_chunk", "user_message"}:
            prefix = "You:"
        elif kind in {"agent_message_chunk", "agent_message"}:
            prefix = "Grok:"
        else:
            return
        content = update.get("content")
        text = ""
        if isinstance(content, dict):
            text = str(content.get("text") or "")
        elif isinstance(content, str):
            text = content
        if not text:
            return
        if self.capture_replay:
            # session/load replays the whole history; it must not be appended to the live row again.
            self.replay_lines = fold_speaker(self.replay_lines, prefix, text)
            return
        if prefix == "You:" and session_id in self.awaiting_prompt.values():
            # _arm_prompt already recorded this prompt; an echo would be glued onto it.
            return
        for row in self.rows:
            if row.get("id") == session_id:
                if prefix == "Grok:":
                    row["summary"] = clip((row.get("summary") or "") + text)
                row["lines"] = fold_speaker(list(row.get("lines") or []), prefix, text)

    def approve_waiting(self) -> None:
        """Allow approvals that were already waiting when auto-approve was turned on."""
        for permission_id, stored in list(self.permissions.items()):
            session_id = permission_id.split(":", 1)[0]
            if not stored.get("allow") or not self.approvals.allows(session_id):
                continue
            title = str((stored.get("permission") or {}).get("title") or "Approve this action")
            self.decide(session_id, permission_id, True)
            for row in self.rows:
                if row.get("id") == session_id:
                    row["lines"] = list(row.get("lines") or []) + [f"Auto-approved: {clip(title, 120)}"]
            self.pending_push = True
            self.urgent = True

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


def transcript_lines(result: object) -> list[str]:
    root = result
    if isinstance(root, dict) and isinstance(root.get("result"), (dict, list)):
        root = root["result"]
    lines: list[str] = []
    for row in _message_rows(root):
        line = _transcript_line(row)
        if line:
            lines.append(line)
    return lines[-80:]


def fold_speaker(lines: list[str], prefix: str, text: str) -> list[str]:
    if lines and lines[-1].startswith(prefix):
        lines[-1] = (lines[-1] + text)[:8000]
        return lines
    body = " ".join(text.split())
    if not body:
        return lines
    lines.append(f"{prefix} {body}")
    return lines


def best_transcript(*groups: list) -> list[str]:
    """Prefer a real conversation over a title or summary standing in for one."""
    best: list[str] = []
    for group in groups:
        lines = [str(line) for line in group if str(line).strip()]
        if not any(line.startswith(("You:", "Grok:", "Tool:", "Auto-approved:")) for line in lines):
            continue
        if len(lines) >= len(best):
            best = lines
    return best


def _message_rows(root: object) -> list:
    if isinstance(root, list):
        return root
    if not isinstance(root, dict):
        return []
    for key in ("messages", "conversation", "transcript", "history"):
        value = root.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict) and isinstance(value.get("messages"), list):
            return value["messages"]
    content = root.get("content")
    if isinstance(content, list):
        return content
    return []


def _transcript_line(row: object) -> str:
    if isinstance(row, str):
        return " ".join(row.split())
    if not isinstance(row, dict):
        return ""
    role = str(row.get("role") or row.get("type") or "").lower()
    body = _text_body(row.get("content")) or _text_body(row.get("text")) or _text_body(row.get("message"))
    body = " ".join(body.split())
    if not body:
        return ""
    if role in {"user", "human"}:
        return f"You: {body}"
    if role in {"assistant", "agent", "model"}:
        return f"Grok: {body}"
    if not role or role in {"text", "message"}:
        return body
    return f"{role}: {body}"


def _text_body(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = [_text_body(item) for item in value]
        return " ".join(part for part in parts if part)
    if isinstance(value, dict):
        if isinstance(value.get("text"), str):
            return str(value["text"])
        return _text_body(value.get("content"))
    return ""


def sessions_from(result: object) -> list[dict]:
    current = result
    for _ in range(2):
        if isinstance(current, dict) and isinstance(current.get("sessions"), list):
            break
        if isinstance(current, dict) and isinstance(current.get("result"), (dict, list)):
            current = current["result"]
            continue
        break
    rows: object = []
    if isinstance(current, dict) and isinstance(current.get("sessions"), list):
        rows = current["sessions"]
    elif isinstance(current, list):
        rows = current
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


def agent_port(environ: dict[str, str] | None = None) -> int:
    env = os.environ if environ is None else environ
    try:
        port = int(str(env.get("GROK_AGENT_PORT") or "2419"))
    except ValueError:
        return 2419
    return port if 0 < port < 65536 else 2419


def open_agent(approvals: ApprovalPolicy | None = None) -> object:
    try:
        agent = ACPAgent(read_secret(), port=agent_port(), approvals=approvals)
        agent.open()
        return agent
    except (OSError, RuntimeError, miniws.SocketError, relaybox.RelayBoxError):
        down = AgentDown()
        down.approvals = approvals
        return down


def next_counter(previous: int, now_ms: int | None = None) -> int:
    """Counters follow the clock, so a side that lost its saved counter still moves past the peer's replay window."""
    clock = int(time.time() * 1000) if now_ms is None else now_ms
    return max(previous + 1, clock)


AGENT_RETRY = 5.0


class AgentSlot:
    """Owns the agent connection across relay reconnects, so a relay blip does not lose a reply in flight."""

    def __init__(self, counters: Path, agent: object | None = None) -> None:
        self.owned = agent is None
        self.approvals = ApprovalPolicy(counters.with_name("outbound-approvals.json")) if self.owned else None
        self.agent = agent
        self.next_open = 0.0

    def ensure(self) -> object:
        agent = self.agent
        if not self.owned:
            return agent
        if agent is None or getattr(agent, "broken", False) or not getattr(agent, "available", True):
            if time.monotonic() >= self.next_open or agent is None:
                self.close()
                self.agent = open_agent(self.approvals)
                self.next_open = time.monotonic() + AGENT_RETRY
        return self.agent

    def close(self) -> None:
        conn = getattr(self.agent, "conn", None)
        if conn is not None and self.owned:
            try:
                conn.close()
            except OSError:
                pass


def run(config_path: Path, agent: object | None = None, slot: AgentSlot | None = None) -> None:
    counters = counter_path(config_path)
    serve_connection(load_config(config_path), agent, counters, slot)


def serve_connection(config: dict, agent: object | None, counters: Path, slot: AgentSlot | None = None) -> None:
    send_n, recv_n = load_counters(counters)
    replay = relaybox.ReplayWindow.restored(recv_n)
    conn = miniws.connect(config["relay"])
    local = slot is None
    if slot is None:
        slot = AgentSlot(counters, agent)

    def seal(message: dict) -> None:
        nonlocal send_n
        send_n = next_counter(send_n)
        plain = relaybox.encode_message(fit_for_watch(message))
        conn.send_binary(relaybox.seal(plain, config["key"], relaybox.HOST_TO_WATCH, send_n))
        save_counters(counters, send_n, replay.highest)

    try:
        conn.send_text(json.dumps({"role": "host", "token": config["token"]}, separators=(",", ":")))
        opcode, payload = conn.recv()
        if opcode != 1 or b'"ok":true' not in payload:
            raise miniws.SocketError("The relay did not accept this pairing.")
        conn.sock.settimeout(1)
        caught_up = getattr(slot.agent, "request_push", None)
        if caught_up is not None:
            caught_up()
        while True:
            agent = slot.ensure()
            agent_conn = getattr(agent, "conn", None)
            agent_sock = getattr(agent_conn, "sock", None)
            if agent_sock is not None:
                agent_sock.settimeout(1)
            sockets = [conn.sock]
            if agent_sock is not None:
                sockets.append(agent_sock)
            # A frame can already be in the client buffer from the previous read.
            # select does not see that, so a queued hello-plus-command would stall.
            wait = 1.0
            due = getattr(agent, "push_due_in", None)
            if due is not None:
                pending = due()
                if pending is not None:
                    wait = min(wait, pending)
            if conn.pending() or (agent_conn is not None and agent_conn.pending()):
                wait = 0
            readable, _, _ = select.select(sockets, [], [], wait)
            if conn.pending() and conn.sock not in readable:
                readable = [*readable, conn.sock]
            if agent_conn is not None and agent_conn.pending() and agent_sock not in readable:
                readable = [*readable, agent_sock]
            if agent_sock is not None and agent_sock in readable:
                try:
                    agent.pump()
                except TimeoutError:
                    pass
                except (OSError, miniws.SocketError):
                    if hasattr(agent, "broken"):
                        agent.broken = True
                except Exception as error:  # noqa: BLE001 - one bad agent message must not stop the host
                    print(f"Skipped an agent message: {type(error).__name__}", file=sys.stderr)
            update = agent.take_update()
            if update is not None:
                seal(update)
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
                message = relaybox.decode_message(plain)
            except (relaybox.RelayBoxError, ValueError):
                continue
            seal(handle(agent, message))
    finally:
        conn.close()
        if local:
            slot.close()


def main(argv: list[str] | None = None) -> int:
    del argv
    path = Path(os.environ.get("WATCHREMOTE_OUTBOUND_FILE", "")).expanduser() if os.environ.get("WATCHREMOTE_OUTBOUND_FILE") else Path.home() / ".config" / "watch-remote" / "outbound.json"
    if not path.is_file():
        print("No direct pairing yet. Run watch-remote-pair --relay-url with your wss address.", file=sys.stderr)
        return 1
    slot = AgentSlot(counter_path(path))
    while True:
        try:
            run(path, slot=slot)
        except (OSError, miniws.SocketError, relaybox.RelayBoxError, json.JSONDecodeError):
            print("Direct connection dropped. Trying again.", file=sys.stderr)
            time.sleep(2)
        except Exception as error:  # noqa: BLE001 - systemd should not have to restart us for one bug
            print(f"Direct connection failed: {type(error).__name__}. Trying again.", file=sys.stderr)
            time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
