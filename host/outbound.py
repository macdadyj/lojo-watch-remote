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
import pairing  # noqa: E402
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
            # The Watch shows these lines as the chat. Cutting the latest prompt off left its
            # answer with no question above it, and the Watch put the prompt back below it.
            prompts = [index for index, line in enumerate(lines) if str(line).startswith("You:")]
            if prompts:
                keep = min(FOCUS_LINES, max(keep, len(lines) - prompts[-1]))
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
    elif op == "result":
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
        self.default = True
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


def authorized_keys_path() -> Path:
    raw = os.environ.get("WATCHREMOTE_AUTHORIZED_KEYS", "").strip()
    if raw:
        return Path(raw).expanduser()
    return Path.home() / ".ssh" / "authorized_keys"


def _fold_prompt(text: str) -> str:
    return " ".join(str(text).split()).lower().strip(".?!")


def _reply_span(prompt: str, lines: list) -> list[str]:
    """Transcript from the user's prompt through a later Grok line, or nothing yet."""
    needle = _fold_prompt(prompt)
    last = None
    for index, line in enumerate(lines):
        text = str(line)
        if not text.startswith("You:"):
            continue
        if not needle or _fold_prompt(text.split(":", 1)[-1]) == needle:
            last = index
    if last is None:
        return []
    tail = [str(line) for line in lines[last:]]
    if any(line.startswith("Grok:") for line in tail[1:]):
        return tail
    return []


def _session_rows(agent: object) -> list:
    list_sessions = getattr(agent, "list_sessions", None)
    if list_sessions is None:
        return []
    try:
        rows = list_sessions()
    except (RuntimeError, OSError):
        return []
    return rows if isinstance(rows, list) else []


class TurnReceipts:
    """One Watch command's answer, kept on the computer until the Watch asks again.

    The relay's queue is not a mailbox: any poller of the pairing can ack a frame,
    and the Watch stops polling when the wrist goes down or the app is killed.
    A later poll asks for this command id and gets the same answer.
    """

    LIMIT = 64
    TTL = 6 * 60 * 60
    KEEP_LINES = 40

    def __init__(self, path: Path | None) -> None:
        self.path = path
        self.rows: dict[str, dict] = {}
        self.last_repeat = 0.0
        self._load()

    def get(self, command_id: str) -> dict | None:
        self._expire()
        row = self.rows.get(command_id)
        return dict(row) if row else None

    def begin(self, command_id: str, session_id: str, prompt: str) -> None:
        if not command_id:
            return
        self._expire()
        current = self.rows.get(command_id)
        if current and current.get("sessionID"):
            return
        self.rows[command_id] = {
            "commandID": command_id,
            "sessionID": str(session_id or ""),
            "prompt": str(prompt or ""),
            "status": "pending",
            "message": "",
            "lines": [],
            "updated": time.time(),
        }
        self._trim()
        self._save()

    def fail(self, command_id: str, message: str) -> None:
        if not command_id:
            return
        row = self.rows.get(command_id) or {}
        if row.get("status") == "done":
            return
        self.rows[command_id] = {
            "commandID": command_id,
            "sessionID": str(row.get("sessionID") or ""),
            "prompt": str(row.get("prompt") or ""),
            "status": "error",
            "message": str(message or "The computer could not do that."),
            "lines": [],
            "updated": time.time(),
        }
        self._trim()
        self._save()

    def observe(self, sessions: list) -> None:
        if not self.rows or not sessions:
            return
        changed = False
        for row in self.rows.values():
            if row.get("status") != "pending":
                continue
            session_id = str(row.get("sessionID") or "")
            match = next(
                (item for item in sessions if isinstance(item, dict) and str(item.get("id") or "") == session_id),
                None,
            )
            if match is None:
                continue
            lines = match.get("transcript")
            if not isinstance(lines, list):
                lines = match.get("lines")
            span = _reply_span(str(row.get("prompt") or ""), lines if isinstance(lines, list) else [])
            if span:
                kept = [clip_line(line) for line in span[-self.KEEP_LINES :]]
                grok = next((line for line in reversed(kept) if line.startswith("Grok:")), "")
                row["status"] = "done"
                row["lines"] = kept
                row["message"] = grok.split(":", 1)[-1].strip()
                row["updated"] = time.time()
                self.last_repeat = row["updated"]
                changed = True
                continue
            if str(match.get("status") or "") == "failed":
                row["status"] = "error"
                row["message"] = str(match.get("summary") or "The computer could not do that.")
                row["lines"] = []
                row["updated"] = time.time()
                changed = True
        if changed:
            self._save()

    def reply(self, request_id: str, command_id: str) -> dict:
        self._expire()
        row = self.rows.get(command_id)
        if row is None:
            return {"op": "result", "id": request_id, "commandID": command_id, "status": "unknown"}
        return {
            "op": "result",
            "id": request_id,
            "commandID": command_id,
            "sessionID": row.get("sessionID") or "",
            "status": row.get("status") or "pending",
            "message": row.get("message") or "",
            "lines": list(row.get("lines") or []),
        }

    def due_repeat(self) -> bool:
        """Push the session list again for a Watch that is still on the build without receipts.

        That build only shows a reply when a session frame arrives. A frame the relay already
        handed to another poller is gone. Repeating for a minute and a half covers the wrist
        coming back up. A Watch that asks by command id does not need this.
        """
        now = time.time()
        fresh = any(
            row.get("status") == "done" and now - float(row.get("updated") or 0) < 90
            for row in self.rows.values()
        )
        if not fresh or now - self.last_repeat < 2:
            return False
        self.last_repeat = now
        return True

    def _expire(self) -> None:
        now = time.time()
        stale = [key for key, row in self.rows.items() if now - float(row.get("updated") or 0) > self.TTL]
        if not stale:
            return
        for key in stale:
            self.rows.pop(key, None)
        self._save()

    def _trim(self) -> None:
        if len(self.rows) <= self.LIMIT:
            return
        ordered = sorted(self.rows, key=lambda key: float(self.rows[key].get("updated") or 0))
        for key in ordered[: len(self.rows) - self.LIMIT]:
            self.rows.pop(key, None)

    def _load(self) -> None:
        if self.path is None or not self.path.is_file():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        rows = raw.get("receipts") if isinstance(raw, dict) else None
        if not isinstance(rows, list):
            return
        for row in rows:
            if isinstance(row, dict) and row.get("commandID"):
                self.rows[str(row["commandID"])] = row

    def _save(self) -> None:
        if self.path is None:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(self.path.name + ".tmp")
            temporary.write_text(json.dumps({"receipts": list(self.rows.values())}), encoding="utf-8")
            temporary.chmod(0o600)
            os.replace(temporary, self.path)
            self.path.chmod(0o600)
        except OSError:
            pass


def handle(agent: object, message: dict, receipts: TurnReceipts | None = None) -> dict:
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
        if op == "authorize":
            text = str(message.get("publicKey") or "").strip()
            if not text:
                return {"op": "error", "id": ident, "message": "That key could not be authorized."}
            try:
                pairing.authorize_key(text, authorized_keys_path())
            except (pairing.PairingError, OSError):
                return {"op": "error", "id": ident, "message": "That key could not be authorized."}
            return {"op": "ok", "id": ident}
        if op == "list":
            focus = getattr(agent, "watch_focus", None)
            return {
                "op": "sessions",
                "id": ident,
                "sessions": watch_rows(agent.list_sessions(), focus() if focus else None),
                "approvalsAvailable": bool(getattr(agent, "available", True)),
            }
        if op == "result":
            command_id = str(message.get("commandID") or "")
            if receipts is not None:
                receipts.observe(_session_rows(agent))
                return receipts.reply(ident, command_id)
            return {"op": "result", "id": ident, "commandID": command_id, "status": "unknown"}
        if op == "start":
            prompt = str(message.get("prompt") or "").strip()
            if not prompt:
                return {"op": "error", "id": ident, "message": "Say what the task should do."}
            if receipts is not None:
                existing = receipts.get(ident)
                if existing and existing.get("sessionID"):
                    return {"op": "started", "id": ident, "sessionID": existing["sessionID"]}
            session_id = str(message.get("sessionID") or "").strip()
            if session_id:
                if approvals is not None:
                    approvals.note({"autoApprove": message.get("autoApprove"), "sessionID": session_id})
                continued = agent.continue_session(session_id, prompt, str(message.get("cwd") or ""))
                if receipts is not None:
                    receipts.begin(ident, continued, prompt)
                return {"op": "started", "id": ident, "sessionID": continued}
            session_id = agent.start(prompt, str(message.get("cwd") or ""))
            if approvals is not None:
                approvals.note({"autoApprove": message.get("autoApprove"), "sessionID": session_id})
            if receipts is not None:
                receipts.begin(ident, session_id, prompt)
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
        if receipts is not None and op == "start":
            receipts.fail(ident, text)
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
        # Only the chat being loaded is captured. Live chunks of other chats keep streaming to their rows.
        self.capture_session: str | None = None
        self.replay_lines: list[str] = []
        self.awaiting_prompt: dict[int, str] = {}
        self.turns: dict[str, TurnTracker] = {}
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
        self.capture_session = session_id
        try:
            loaded = self.request("session/load", {
                "sessionId": session_id,
                "cwd": directory,
                "mcpServers": [],
            })
        finally:
            self.capture_session = None
        self.loaded.add(session_id)
        host = self.replay_lines or transcript_lines(loaded.get("result"))
        chosen = merge_transcript(stored, host)
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
        if method == "_x.ai/session/prompt_complete":
            self._turn_complete(obj)
            return
        if method == "_x.ai/queue/changed":
            params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
            running = params.get("runningPromptId")
            if isinstance(running, str) and running and isinstance(params.get("sessionId"), str):
                self.turns.setdefault(params["sessionId"], TurnTracker()).started(running)
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
        self.turns.setdefault(session_id, TurnTracker()).sent()
        for row in self.rows:
            if row.get("id") == session_id:
                row["lines"] = fold_speaker(list(row.get("lines") or []), "You:", prompt)

    def _settle_prompt(self, ident: int, obj: dict) -> None:
        session_id = self.awaiting_prompt.pop(ident, None)
        if session_id is None:
            return
        if session_id in self.awaiting_prompt.values():
            return
        self.turns.setdefault(session_id, TurnTracker()).answered()
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

    def _turn_complete(self, obj: dict) -> None:
        """Grok tells every connection with the chat loaded that a turn ended, including a turn
        whose `session/prompt` went out on a connection that has since been replaced."""
        params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
        session_id = str(params.get("sessionId") or "")
        if not session_id:
            return
        if not self.turns.setdefault(session_id, TurnTracker()).completed(str(params.get("promptId") or "")):
            return
        for ident, waiting in list(self.awaiting_prompt.items()):
            if waiting == session_id:
                self.awaiting_prompt.pop(ident, None)
        cancelled = params.get("stopReason") == "cancelled"
        for row in self.rows:
            if row.get("id") != session_id or row.get("status") not in {"running", "needsApproval"}:
                continue
            row["status"] = "stopped" if cancelled else "idle"
            row.pop("permission", None)
            lines = row.get("lines") or []
            grok = next((str(line) for line in reversed(lines) if str(line).startswith("Grok:")), "")
            if grok:
                row["summary"] = clip(grok.split(":", 1)[-1].strip())
        for key in [key for key in self.permissions if key.startswith(session_id + ":")]:
            self.permissions.pop(key, None)
        self.pending_push = True
        self.urgent = True

    def _remember_permission(self, obj: dict) -> None:
        params = obj.get("params") if isinstance(obj.get("params"), dict) else {}
        session_id = str(params.get("sessionId") or "")
        rpc = obj.get("id")
        number = isinstance(rpc, int)
        rpc_text = str(rpc)
        options = params.get("options") if isinstance(params.get("options"), list) else []
        allow = option_id(options, "allow_once", "allow")
        deny = option_id(options, "reject_once", "reject")
        tool = params.get("toolCall") if isinstance(params.get("toolCall"), dict) else {}
        title = params.get("title") or tool.get("title") or "Approve this action"
        detail = params.get("description") or ""
        permission_id = f"{session_id}:{rpc_text}"
        if allow and self.approvals.allows(session_id):
            self.permissions[permission_id] = {"rpc": rpc_text, "number": number, "allow": allow, "deny": deny, "permission": {}}
            self.decide(session_id, permission_id, True)
            for row in self.rows:
                if row.get("id") == session_id:
                    row["lines"] = note_auto_approval(list(row.get("lines") or []), str(title))
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
        capturing = self.capture_session is not None and session_id == self.capture_session
        if kind == "tool_call":
            title = clip(str(update.get("title") or "Tool"), 120)
            if capturing:
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
        if capturing:
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
                    row["lines"] = note_auto_approval(list(row.get("lines") or []), title)
            self.pending_push = True
            self.urgent = True

    def _apply_permissions(self) -> None:
        for row in self.rows:
            matches = [value for key, value in self.permissions.items() if key.startswith(str(row.get("id")) + ":")]
            if not matches:
                continue
            row["status"] = "needsApproval"
            row["permission"] = matches[0]["permission"]


def option_id(options: list, exact: str, needle: str | None = None) -> str | None:
    """Grok lists "always allow" first, and that grant covers every later bash command in the
    folder. Prefer the option whose kind is exactly `exact` (allow_once, reject_once)."""
    rows = [option for option in options if isinstance(option, dict) and isinstance(option.get("optionId"), str)]
    for option in rows:
        if str(option.get("kind") or "").lower() == exact:
            return option["optionId"]
    word = needle or exact
    matches = [
        option for option in rows
        if word in str(option.get("kind") or "").lower() or word in str(option.get("name") or "").lower()
    ]
    for option in matches:
        if "always" not in (str(option.get("kind") or "") + str(option.get("name") or "")).lower():
            return option["optionId"]
    return matches[0]["optionId"] if matches else None


class TurnTracker:
    """When a chat's turn is over. Mirrors TurnTracker in Core/Sources/WatchRemoteCore/ChatFold.swift.

    Grok sends `prompt_complete` before the `session/prompt` result, and to every connection with the
    chat loaded, so a completion for an earlier prompt must not end one still queued behind it."""

    def __init__(self) -> None:
        self.unstarted = 0
        self.running: str | None = None

    def sent(self) -> None:
        self.unstarted += 1

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

    def answered(self) -> None:
        self.unstarted = 0
        self.running = None


def note_auto_approval(lines: list, title: str) -> list:
    """The tool card for this approval is already the step; a note after it would count twice."""
    if lines and str(lines[-1]).startswith("Tool:"):
        return lines
    return lines + [f"Auto-approved: {clip(title, 120)}"]


def merge_transcript(local: list, host: list) -> list[str]:
    """The computer's replay is the record of finished turns, in order. Local lines only add the
    prompt just sent and what streamed after it. Mirrors SessionResume.merge in the app."""
    def chat(lines: list) -> list[str]:
        cleaned = [str(line).strip() for line in lines if str(line).strip()]
        if not any(line.startswith(("You:", "Grok:", "Tool:", "Auto-approved:")) for line in cleaned):
            return []
        return cleaned

    def key(line: str) -> str:
        return " ".join(line[4:].split()).lower()

    merged = _merged_lines(chat(local), chat(host), key)
    # Grok streams "…Texas. " then "Pulling…": a reload mid-answer keeps that trailing space.
    raw = next((str(line) for line in reversed(host) if str(line).strip()), None)
    if merged and raw is not None and raw != merged[-1] and raw.startswith(merged[-1]) and raw.strip() == merged[-1]:
        return merged[:-1] + [raw]
    return merged


def _merged_lines(local_chat: list[str], host_chat: list[str], key) -> list[str]:
    prompts = [key(line) for line in host_chat if line.startswith("You:")]
    if not prompts:
        return local_chat if len(local_chat) > len(host_chat) else host_chat
    following = 0
    tail_start: int | None = None
    for index, line in enumerate(local_chat):
        if not line.startswith("You:"):
            continue
        wanted = key(line)
        if wanted in prompts[following:]:
            following = prompts.index(wanted, following) + 1
            tail_start = None
        elif tail_start is None:
            tail_start = index
    if tail_start is None:
        return host_chat
    return host_chat + local_chat[tail_start:]


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
    # Only leading space goes: a first chunk ending "Texas. " must not glue onto "Today".
    body = text.lstrip()
    if not body.strip():
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
# The relay pings every 25s. Two missed pings means this socket is gone and the
# Watch is being told the computer is offline. A quiet Grok turn still receives
# those pings, so this is not a chat idle timeout.
RELAY_SILENCE_SECONDS = 70.0


def relay_link_expired(last_heard: float, now: float, limit: float | None = None) -> bool:
    span = RELAY_SILENCE_SECONDS if limit is None else limit
    return now - last_heard >= span


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
    receipts = TurnReceipts(counters.with_name("turn-receipts.json"))
    conn = miniws.connect(config["relay"])
    local = slot is None
    if slot is None:
        slot = AgentSlot(counters, agent)

    def seal(message: dict) -> None:
        nonlocal send_n
        sessions = message.get("sessions")
        if isinstance(sessions, list):
            receipts.observe(sessions)
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
        last_heard = time.monotonic()
        caught_up = getattr(slot.agent, "request_push", None)
        if caught_up is not None:
            caught_up()
        while True:
            if relay_link_expired(last_heard, time.monotonic()):
                raise miniws.SocketError("The relay stopped sending.")
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
            # A ping is consumed inside recv and never returned. Hearing the socket
            # at all means the relay still has this computer in the room.
            if conn.sock in readable:
                last_heard = time.monotonic()
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
            elif receipts.due_repeat():
                rows = _session_rows(agent)
                if rows:
                    seal({
                        "op": "update",
                        "id": f"receipt-{int(time.time() * 1000)}",
                        "sessions": watch_rows(rows, getattr(agent, "watch_focus", lambda: None)() or None),
                        "approvalsAvailable": bool(getattr(agent, "available", True)),
                    })
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
            seal(handle(agent, message, receipts))
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
