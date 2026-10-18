#!/usr/bin/env python3
"""Real end-to-end check of Watch Remote against this computer's agent door and real Grok Build.

Run it on the host computer (the one the iPhone SSHes into), from a checkout of the repo:

    e2e/run-real-host-check.sh

That installs this checkout's door and outbound service first. `python3 e2e/real_host_check.py`
runs the check alone against whatever is installed.

It talks to the door on 127.0.0.1:2419 exactly as the iPhone does after SSH forwards the port
(same upgrade headers, same ACP requests, same transcript rules; see e2e/phone_mirror.py), and,
when this computer is paired with the relay, to the deployed relay exactly as the Watch does.
Nothing here is a stand-in: the prompts go to the real `grok agent serve` and its real model.

Every scenario asserts that the prompt is the first line of its turn, that the reply streamed
into that chat belongs to that prompt's turn (Grok's own promptId from _x.ai/queue/changed,
the prompt result, and _x.ai/session/prompt_complete must agree), and that the final answer
arrives within --timeout seconds. Recordings of every frame go to --out as replay fixtures.

Exit status is 0 only when every scenario passed.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
from pathlib import Path
from urllib.parse import quote, urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "host"))

import outbound  # noqa: E402
import pairing  # noqa: E402
import phone_mirror as phone  # noqa: E402
import watch_poll  # noqa: E402

DEFAULT_PROMPT = "What's the weather today in Argyle Texas"
DEFAULT_SECOND = "And what about tomorrow there?"
DEFAULT_OTHER = "What's the weather today in Amarillo Texas"
# "Texas.Pulling": a chunk boundary lost its space (a reload trimmed the line it streamed onto).
# The same shape sits inside a forecast link: MapClick.php?CityName matches at "p?Ci".
GLUED_SENTENCE = re.compile(r"[a-z][.!?][A-Z][a-z]")
_TOKEN_BREAKS = frozenset(" \t\r\n<>()[]\"'`")
SCENARIOS = ["turns", "reopen", "background", "relaunch", "crossing", "watch", "together", "fresh"]


class CheckFailed(Exception):
    pass


class Recording:
    """Every frame in order, with the phone's own UI steps, as a replay fixture."""

    def __init__(self, name: str, redactions: list[tuple[str, str]]) -> None:
        self.name = name
        self.redactions = [(old, new) for old, new in redactions if old]
        self.events: list[dict] = []
        self.lock = threading.Lock()
        self.started = time.monotonic()

    def add(self, event: dict) -> None:
        stamped = dict(event)
        stamped["t"] = round(time.monotonic() - self.started, 3)
        with self.lock:
            self.events.append(self._redact(stamped))

    def _redact(self, value: object) -> object:
        if isinstance(value, str):
            for old, new in self.redactions:
                value = value.replace(old, new)
            return value
        if isinstance(value, list):
            return [self._redact(item) for item in value]
        if isinstance(value, dict):
            return {key: self._redact(item) for key, item in value.items()}
        return value

    def check(self, session_id: str, transcript: list[str], **expect: object) -> None:
        self.add({"k": "check", "s": session_id, "transcript": list(transcript), **expect})

    def write(self, directory: Path, meta: dict) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{self.name}.json"
        with self.lock:
            body = {"scenario": self.name, "meta": self._redact(meta), "events": list(self.events)}
        path.write_text(json.dumps(body, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        return path


class Context:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.address = (args.door_host, args.door_port)
        self.secret = read_secret(Path(args.secret_file).expanduser())
        home = str(Path.home())
        user = getpass.getuser()
        # Grok names its per-folder session directories with the folder path percent-encoded.
        self.redactions = [
            (home, "~"), (quote(home, safe=""), "~"),
            (f"/{user}/", "/user/"), (f"%2F{user}%2F", "%2Fuser%2F"),
            (platform.node(), "host"),
        ]
        self.results: list[tuple[str, bool, str]] = []
        self.meta = {
            "grok": grok_version(),
            "door": f"{args.door_host}:{args.door_port}",
            "prompt": args.prompt,
            "recordedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }

    def model(self, recording: Recording, auto_approve: bool = True) -> phone.PhoneModel:
        return phone.PhoneModel(self.args.cwd, auto_approve, recording.add)

    def connect(self, model: phone.PhoneModel, link: phone.LinkState) -> phone.Pipe:
        pipe = phone.Pipe(link, self.address, self.secret, model.on_frame, model.on_inbound)
        model.attach(pipe)
        pipe.initialize()
        return pipe


def read_secret(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise SystemExit(f"Cannot read the agent secret at {path}: {error.strerror}")
    if not text:
        raise SystemExit(f"The agent secret file {path} is empty.")
    return text


def grok_version() -> str:
    candidates = [os.environ.get("GROK_BIN", ""), str(Path.home() / ".grok" / "bin" / "grok"), "grok"]
    for binary in [item for item in candidates if item]:
        try:
            completed = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if completed.stdout.strip():
            return completed.stdout.strip()
    return "unknown"


def short(session_id: str) -> str:
    """Grok's session ids are time-ordered, so chats made a moment apart share a prefix."""
    return session_id[-8:]


def new_link() -> phone.LinkState:
    return phone.LinkState(str(uuid.uuid4()))


def log(text: str) -> None:
    print(f"  {time.strftime('%H:%M:%S')} {text}", flush=True)


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


def glued_join(line: str) -> re.Match[str] | None:
    """A missing space after sentence punctuation. The same characters inside a URL are not a join.

    MapClick.php?CityName matches at "p?Ci" because "?" starts a query. "Texas.Pulling" and
    "up?City" still match. A URL earlier in the line does not hide a later join.
    """
    for match in GLUED_SENTENCE.finditer(line):
        if _url_token(line, match.start()):
            continue
        return match
    return None


def _url_token(line: str, index: int) -> bool:
    start = index
    while start > 0 and line[start - 1] not in _TOKEN_BREAKS:
        start -= 1
    end = index + 1
    while end < len(line) and line[end] not in _TOKEN_BREAKS:
        end += 1
    token = line[start:end]
    if "://" in token or token.startswith("www."):
        return True
    return re.search(r"\.(?:php|html|aspx|asp|cgi)\?", token, re.IGNORECASE) is not None


def wait_idle(model: phone.PhoneModel, session_id: str, timeout: float, what: str) -> float:
    started = time.monotonic()
    ok = model.wait(lambda: model.chat(session_id).status in {"idle", "stopped", "failed"}, timeout)
    elapsed = time.monotonic() - started
    chat = model.chat(session_id)
    expect(ok, f"{what}: no final answer within {timeout:.0f}s (status {chat.status}). Last lines: {chat.transcript[-3:]}")
    expect(chat.status == "idle", f"{what}: the turn ended as {chat.status}, not idle.")
    return elapsed


def turn_lines(transcript: list[str], prompt: str) -> list[str]:
    """The lines of the turn that starts with `prompt`, up to the next prompt."""
    wanted = f"You: {prompt}"
    starts = [index for index, line in enumerate(transcript) if line == wanted]
    expect(bool(starts), f"the prompt {prompt!r} is not in the chat: {transcript}")
    start = starts[-1]
    end = next((index for index in range(start + 1, len(transcript)) if transcript[index].startswith("You:")), len(transcript))
    return transcript[start:end]


def check_turn(model: phone.PhoneModel, session_id: str, prompt: str, words: list[str], forbidden: list[str], what: str) -> str:
    chat = model.chat(session_id)
    lines = turn_lines(chat.transcript, prompt)
    replies = [line for line in lines if line.startswith("Grok:")]
    expect(bool(replies), f"{what}: no reply after the prompt. Turn: {lines}")
    expect(lines[-1].startswith("Grok:"), f"{what}: the turn does not end with the answer. Turn: {lines}")
    final = phone.spoken_text(lines[-1])
    for word in words:
        expect(word.lower() in final.lower(), f"{what}: the final answer does not mention {word!r}: {final[:300]!r}")
    for word in forbidden:
        text = " ".join(phone.spoken_text(line) for line in replies)
        expect(word.lower() not in text.lower(), f"{what}: the reply mentions {word!r}, which belongs to another chat: {text[:300]!r}")
    expect(not any(line == "Tool: Tool" for line in lines), f"{what}: a title-less tool update became its own step: {lines}")
    for line in replies:
        glued = glued_join(line)
        expect(glued is None, f"{what}: two streamed chunks were glued together at {glued.group(0) if glued else ''!r}: {line[:300]!r}")
    return final


def check_ownership(model: phone.PhoneModel, session_id: str, prompt: str, what: str) -> str:
    """Grok's promptId for this prompt is the one that ran and the one that completed."""
    running = [pid for pid, (sid, text) in model.queue_running.items() if sid == session_id and text == prompt]
    expect(bool(running), f"{what}: Grok never reported running {prompt!r} in this chat (_x.ai/queue/changed).")
    prompt_id = running[-1]
    completed = model.completed.get(session_id, [])
    expect(prompt_id in completed, f"{what}: prompt_complete for {prompt_id} never arrived (got {completed}).")
    others = [pid for pid, (sid, _text) in model.queue_running.items() if sid != session_id]
    expect(prompt_id not in others, f"{what}: promptId {prompt_id} also ran in another chat.")
    return prompt_id


def first_line_is(model: phone.PhoneModel, session_id: str, prompt: str, what: str) -> None:
    transcript = model.chat(session_id).transcript
    expect(bool(transcript) and transcript[0] == f"You: {prompt}", f"{what}: the first line is not the prompt: {transcript[:3]}")


def steps_match_tools(model: phone.PhoneModel, recording: Recording, session_id: str, what: str) -> None:
    tool_ids = set()
    for event in recording.events:
        frame = event.get("f") or {}
        if event.get("k") != "in" or frame.get("method") != "session/update":
            continue
        params = frame.get("params") or {}
        update = params.get("update") or {}
        if params.get("sessionId") == session_id and update.get("sessionUpdate") == "tool_call":
            tool_ids.add(update.get("toolCallId"))
    cards = [line for line in model.chat(session_id).transcript if phone.is_tool_card(line)]
    expect(len(cards) <= max(1, len(tool_ids)), f"{what}: {len(cards)} step cards for {len(tool_ids)} tools: {cards}")


# Scenarios


def scenario_turns(ctx: Context, recording: Recording) -> str:
    """New chat, first prompt, then a second prompt in the same chat."""
    args = ctx.args
    model = ctx.model(recording)
    ctx.connect(model, new_link())
    sent = time.monotonic()
    session_id = model.start(args.prompt)
    log(f"chat {short(session_id)}: sent {args.prompt!r}")
    elapsed = wait_idle(model, session_id, args.timeout, "first prompt")
    log(f"final answer after {elapsed:.1f}s")
    first_line_is(model, session_id, args.prompt, "first prompt")
    final = check_turn(model, session_id, args.prompt, args.expect, [], "first prompt")
    check_ownership(model, session_id, args.prompt, "first prompt")
    steps_match_tools(model, recording, session_id, "first prompt")
    recording.check(session_id, model.chat(session_id).transcript, first=f"You: {args.prompt}")
    model.continue_chat(session_id, args.second)
    log(f"sent second prompt {args.second!r}")
    wait_idle(model, session_id, args.timeout, "second prompt")
    first_line_is(model, session_id, args.prompt, "second prompt")
    check_turn(model, session_id, args.second, [], [], "second prompt")
    check_ownership(model, session_id, args.second, "second prompt")
    transcript = model.chat(session_id).transcript
    expect(transcript.index(f"You: {args.prompt}") < transcript.index(f"You: {args.second}"), "the prompts are out of order")
    recording.check(session_id, transcript, first=f"You: {args.prompt}")
    ctx.meta.setdefault("chats", {})["turns"] = session_id
    total = time.monotonic() - sent
    return f"chat {short(session_id)}: both answers in order ({total:.0f}s). Final: {final[:80]!r}"


def scenario_reopen(ctx: Context, recording: Recording) -> str:
    """The app was relaunched with an old, wrong cached copy of the chat. Reopening must show
    the computer's order: every prompt above its own answer, every final answer present."""
    args = ctx.args
    session_id = ctx.meta.get("chats", {}).get("turns")
    expect(bool(session_id), "needs the chat from the turns scenario")
    model = ctx.model(recording)
    pipe = ctx.connect(model, new_link())
    rows = pipe.list_sessions()
    listed = next((row for row in rows if row.get("sessionId") == session_id), None)
    expect(listed is not None, f"chat {short(session_id)} is not in _x.ai/session/list")
    # The copy build 221 kept: the first prompt missing, one card per tool update, an old reply on top.
    stale = ["Grok: an older reply about tomorrow's forecast", "Tool: Tool", "Tool: Tool", "Tool: Tool", f"You: {args.second}"]
    model.set_cache(session_id, stale)
    model.resume(session_id)
    transcript = model.chat(session_id).transcript
    first_line_is(model, session_id, args.prompt, "reopen")
    expect("Grok: an older reply about tomorrow's forecast" not in transcript, f"reopen kept a stale line: {transcript}")
    check_turn(model, session_id, args.prompt, args.expect, [], "reopen, first turn")
    check_turn(model, session_id, args.second, [], [], "reopen, second turn")
    expect(model.chat(session_id).status == "idle", f"reopen: a finished chat shows {model.chat(session_id).status}")
    recording.check(session_id, transcript, first=f"You: {args.prompt}")
    return f"chat {short(session_id)} reopened in the computer's order ({len(transcript)} lines), title {listed.get('title')!r}"


def first_tool_or_permission(model: phone.PhoneModel, session_id: str) -> bool:
    chat = model.chat(session_id)
    return chat.permission is not None or any(phone.is_tool_card(line) for line in chat.transcript) or chat.status == "idle"


def scenario_background(ctx: Context, recording: Recording) -> str:
    """The phone sleeps mid-turn for longer than the old door's 30 second idle limit, then comes back."""
    args = ctx.args
    model = ctx.model(recording)
    link = new_link()
    pipe = ctx.connect(model, link)
    expect(pipe.door_version >= 3, "the agent door on this computer predates the shared Grok connection; install host/agentdoor.py (e2e/run-real-host-check.sh does)")
    session_id = model.start(args.prompt)
    log(f"chat {short(session_id)}: sent, waiting for the first tool step")
    expect(model.wait(lambda: first_tool_or_permission(model, session_id), args.timeout), "no tool step or answer arrived")
    if model.chat(session_id).status == "idle":
        log("the turn finished before the phone could leave; dropping anyway")
    recording.add({"k": "ui", "a": "background", "s": session_id, "seen": link.seen})
    pipe.drop()
    log(f"phone away for {args.away:.0f}s (seen {link.seen} frames)")
    time.sleep(args.away)
    back = time.monotonic()
    pipe = ctx.connect(model, link)
    recording.add({"k": "ui", "a": "foreground", "s": session_id, "resumed": pipe.resumed})
    expect(pipe.resumed, "the door did not resume the link; frames sent while the phone was away are lost")
    model.resume(session_id)
    elapsed = wait_idle(model, session_id, args.timeout, "after coming back")
    log(f"final answer {elapsed:.1f}s after coming back")
    first_line_is(model, session_id, args.prompt, "background")
    final = check_turn(model, session_id, args.prompt, args.expect, [], "background")
    check_ownership(model, session_id, args.prompt, "background")
    recording.check(session_id, model.chat(session_id).transcript, first=f"You: {args.prompt}")
    return f"away {args.away:.0f}s, answer {time.monotonic() - back:.0f}s after return: {final[:60]!r}"


def scenario_relaunch(ctx: Context, recording: Recording) -> str:
    """An approval is waiting when iOS kills the app. The relaunched app is a new link; it must
    still see that approval, answer it, and get the final answer."""
    args = ctx.args
    model = ctx.model(recording, auto_approve=False)
    pipe = ctx.connect(model, new_link())
    session_id = model.start(args.prompt)
    log(f"chat {short(session_id)}: sent with auto-approve off, waiting for an approval request")
    asked = model.wait(lambda: model.chat(session_id).permission is not None or model.chat(session_id).status == "idle", args.timeout)
    expect(asked, "neither an approval request nor an answer arrived")
    had_approval = model.chat(session_id).permission is not None
    cached = list(model.chat(session_id).transcript)
    recording.add({"k": "ui", "a": "killed", "s": session_id, "approvalWaiting": had_approval})
    pipe.drop()
    time.sleep(3)
    relaunched = ctx.model(recording, auto_approve=True)
    pipe = ctx.connect(relaunched, new_link())
    rows = pipe.list_sessions()
    expect(any(row.get("sessionId") == session_id for row in rows), "the chat is missing from the list after relaunch")
    relaunched.set_cache(session_id, cached)
    relaunched.resume(session_id)
    elapsed = wait_idle(relaunched, session_id, args.timeout, "after relaunch")
    first_line_is(relaunched, session_id, args.prompt, "relaunch")
    final = check_turn(relaunched, session_id, args.prompt, args.expect, [], "relaunch")
    recording.check(session_id, relaunched.chat(session_id).transcript, first=f"You: {args.prompt}")
    if not had_approval:
        return f"Grok asked for no approval (this folder may have an always-allow grant); relaunch reload verified in {elapsed:.0f}s"
    expect(any(item.get("sessionID") == session_id for item in relaunched.permissions_seen),
           "the relaunched app never received the approval that was waiting")
    return f"the waiting approval reached the relaunched app; answer {elapsed:.0f}s later: {final[:60]!r}"


def scenario_crossing(ctx: Context, recording: Recording) -> str:
    """Two chats stream at once on one link, and one is reopened mid-stream. Neither gets the other's text."""
    args = ctx.args
    model = ctx.model(recording)
    ctx.connect(model, new_link())
    first = model.start(args.prompt)
    second = model.start(args.other)
    log(f"chats {short(first)} and {short(second)} running at once")
    model.wait(lambda: any(line.startswith("Grok:") for line in model.chat(second).transcript), args.timeout)
    model.resume(first)
    wait_idle(model, first, args.timeout, "first chat")
    wait_idle(model, second, args.timeout, "second chat")
    city_one = args.expect[0] if args.expect else "Argyle"
    city_two = args.other_expect
    check_turn(model, first, args.prompt, args.expect, [city_two], "first chat")
    check_turn(model, second, args.other, [city_two], [city_one], "second chat")
    first_line_is(model, first, args.prompt, "first chat")
    first_line_is(model, second, args.other, "second chat")
    check_ownership(model, first, args.prompt, "first chat")
    check_ownership(model, second, args.other, "second chat")
    recording.check(first, model.chat(first).transcript, first=f"You: {args.prompt}")
    recording.check(second, model.chat(second).transcript, first=f"You: {args.other}")
    return "each chat holds only its own prompt and answer"


class WatchSide:
    """The Watch on the deployed relay, polling the way the Watch app does."""

    def __init__(self, ctx: Context, recording: Recording) -> None:
        config_path = Path(ctx.args.relay_config).expanduser()
        if not config_path.is_file():
            raise CheckFailed(f"skipped: {config_path} does not exist (this computer is not paired with the relay)")
        config = outbound.load_config(config_path)
        parts = urlsplit(str(config["relay"]))
        scheme = "https" if parts.scheme == "wss" else "http"
        self.base = f"{scheme}://{parts.netloc}"
        self.recording = recording
        recording.add({"k": "ui", "a": "relay", "url": self.base})
        self.watch = watch_poll.HttpWatch(
            self.base, str(config["token"]), config["key"],
            on_message=lambda message: recording.add({"k": "relay-in", "f": message}),
        )
        # A just-restarted outbound service takes a few seconds to reach the relay.
        deadline = time.monotonic() + 30
        self.watch.poll(wait_ms=0)
        while not self.watch.host_online and time.monotonic() < deadline:
            time.sleep(1)
            self.watch.poll(wait_ms=0)
        expect(self.watch.host_online, f"the relay at {self.base} says this computer's outbound service is offline")
        # Same prefix the relay writes in its log (`room`). It is not the token.
        room = hashlib.sha256(self.watch.token.encode()).hexdigest()[:8]
        print(f"  public relay room {room}", flush=True)

    def start(self, prompt: str, session_id: str | None = None) -> str:
        ident = self.watch.send("start", prompt=prompt, sessionID=session_id, autoApprove=True)
        self.recording.add({"k": "relay-out", "f": {"op": "start", "id": ident, "sessionID": session_id, "prompt": prompt}})
        started = self.watch.reply(ident, timeout=30)
        expect(started.get("op") == "started", f"the computer answered the Watch start with {started}")
        return str(started.get("sessionID") or session_id or "")

    def row(self, session_id: str) -> dict:
        for message in reversed(self.watch.inbox):
            for item in message.get("sessions") or []:
                if item.get("id") == session_id:
                    return item
        return {}

    def answered(self, session_id: str, prompt: str) -> bool:
        item = self.row(session_id)
        lines = [str(line) for line in item.get("transcript") or []]
        if f"You: {prompt}" not in lines:
            return False
        tail = lines[len(lines) - 1 - lines[::-1].index(f"You: {prompt}"):]
        return item.get("status") == "idle" and any(line.startswith("Grok:") for line in tail[1:])

    def wait_answer(self, session_id: str, prompt: str, timeout: float, what: str) -> list[str]:
        deadline = time.monotonic() + timeout
        while not self.answered(session_id, prompt) and time.monotonic() < deadline:
            self.watch.poll(wait_ms=4000)
        expect(self.answered(session_id, prompt), f"{what}: the Watch never got the final answer for chat {short(session_id)}: {self.row(session_id)}")
        lines = [str(line) for line in self.row(session_id).get("transcript") or []]
        expect(lines.index(f"You: {prompt}") < max(index for index, line in enumerate(lines) if line.startswith("Grok:")),
               f"{what}: the Watch shows the answer above the prompt: {lines}")
        return lines

    def resume(self, session_id: str) -> list[str]:
        ident = self.watch.send("resume", sessionID=session_id)
        restored = self.watch.reply(ident, timeout=30)
        return [str(line) for line in restored.get("lines") or []]


def drop_authorized_blob(path: Path, blob: str) -> None:
    """Remove one public-key blob from authorized_keys and leave every other line."""
    if not path.is_file():
        return
    rows = [row for row in path.read_text(encoding="utf-8").splitlines() if blob not in row.split()]
    body = ("\n".join(rows).rstrip() + "\n") if rows else ""
    temporary = path.with_name(path.name + ".watch-remote-tmp")
    temporary.write_text(body, encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, path)
    if path.exists():
        path.chmod(0o600)


def scenario_fresh(ctx: Context, recording: Recording) -> str:
    """A Watch with no iPhone key yet still gets an auto-approved answer, then the key is authorized."""
    args = ctx.args
    side = WatchSide(ctx, recording)
    with tempfile.TemporaryDirectory() as directory:
        key_path = Path(directory) / "phone"
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-f", str(key_path), "-N", "", "-C", "watch-remote-e2e@iphone", "-q"],
            check=True,
        )
        public = Path(str(key_path) + ".pub").read_text(encoding="utf-8").strip()
    blob = public.split()[1]
    keys = Path.home() / ".ssh" / "authorized_keys"
    before = keys.read_text(encoding="utf-8") if keys.is_file() else ""
    expect(blob not in before, "the fresh key was already authorized on this computer")
    session_id = ""
    try:
        session_id = side.start(args.prompt)
        lines = side.wait_answer(session_id, args.prompt, args.timeout, "fresh install")
        for line in lines:
            expect(
                "Generate a key" not in line and "Tasks cannot ask for approval" not in line,
                f"fresh install: the key setup error landed in the chat: {line[:300]!r}",
            )
        ident = side.watch.send("authorize", publicKey=public)
        reply = side.watch.reply(ident, timeout=30)
        expect(reply.get("op") == "ok", f"the computer did not authorize the fresh key: {reply}")
        text = keys.read_text(encoding="utf-8") if keys.is_file() else ""
        expect(blob in text, "the fresh key was not written")
        row = next(item for item in text.splitlines() if blob in item.split())
        expect(pairing.exec_is_refused(row), "the fresh key can do more than forward to the agent port")
        recording.check(session_id, lines, authorized=True)
    finally:
        drop_authorized_blob(keys, blob)
    return f"Watch chat {short(session_id)} answered before a key existed, then the computer authorized one"


def scenario_watch(ctx: Context, recording: Recording) -> str:
    """Watch-alone: the deployed relay and this computer, with no iPhone in the path."""
    args = ctx.args
    side = WatchSide(ctx, recording)
    session_id = side.start(args.prompt)
    side.wait_answer(session_id, args.prompt, args.timeout, "first Watch prompt")
    side.start(args.second, session_id)
    side.wait_answer(session_id, args.second, args.timeout, "second Watch prompt")
    restored_lines = side.resume(session_id)
    prompts = [line for line in restored_lines if line.startswith("You:")]
    expect(prompts[-2:] == [f"You: {args.prompt}", f"You: {args.second}"], f"reopening on the Watch shows {prompts}")
    expect(restored_lines[-1].startswith("Grok:"), f"reopening on the Watch does not end with the answer: {restored_lines[-3:]}")
    expect(side.watch.http_version == 11, "the Watch client did not poll over HTTP/1.1")
    return f"Watch-alone chat {short(session_id)}: prompt then Grok reply in order, no phone, reopen in order"


def scenario_together(ctx: Context, recording: Recording) -> str:
    """The phone and the Watch run chats at the same moment, as on Jon's wrist and in his hand.
    Grok streams only to its newest connection, so before door v3 one of them never got its answer."""
    args = ctx.args
    side = WatchSide(ctx, recording)
    model = ctx.model(recording)
    ctx.connect(model, new_link())
    phone_chat = model.start(args.prompt)
    log(f"phone chat {short(phone_chat)} sent; starting a Watch chat while it runs")
    watch_chat = side.start(args.other)
    log(f"Watch chat {short(watch_chat)} sent")
    wait_idle(model, phone_chat, args.timeout, "phone chat beside the Watch")
    city_one = args.expect[0] if args.expect else "Argyle"
    check_turn(model, phone_chat, args.prompt, args.expect, [args.other_expect], "phone chat beside the Watch")
    check_ownership(model, phone_chat, args.prompt, "phone chat beside the Watch")
    first_line_is(model, phone_chat, args.prompt, "phone chat beside the Watch")
    lines = side.wait_answer(watch_chat, args.other, args.timeout, "Watch chat beside the phone")
    replies = " ".join(line for line in lines if line.startswith("Grok:"))
    expect(city_one.lower() not in replies.lower(), f"the Watch chat got the phone chat's answer: {replies[:300]!r}")
    expect(watch_chat not in model.chats or not model.chat(watch_chat).transcript,
           "the phone's open chat list picked up the Watch chat's stream")
    recording.check(phone_chat, model.chat(phone_chat).transcript, first=f"You: {args.prompt}")
    model.continue_chat(phone_chat, args.second)
    wait_idle(model, phone_chat, args.timeout, "second phone prompt beside the Watch")
    check_turn(model, phone_chat, args.second, [], [], "second phone prompt beside the Watch")
    recording.check(phone_chat, model.chat(phone_chat).transcript, first=f"You: {args.prompt}")
    return f"phone chat {short(phone_chat)} and Watch chat {short(watch_chat)} both answered, neither crossed"


RUNNERS = {
    "turns": scenario_turns,
    "reopen": scenario_reopen,
    "background": scenario_background,
    "relaunch": scenario_relaunch,
    "crossing": scenario_crossing,
    "watch": scenario_watch,
    # Same phone-free path. Kept out of SCENARIOS so a full run does not ask Grok twice.
    "watch-alone": scenario_watch,
    "together": scenario_together,
    "fresh": scenario_fresh,
}


def grants_report() -> list[str]:
    root = Path(os.environ.get("GROK_HOME") or Path.home() / ".grok") / "sessions"
    if not root.is_dir():
        return []
    return [str(path) for path in sorted(root.glob("*/permission*.toml"))]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--door-host", default="127.0.0.1")
    parser.add_argument("--door-port", type=int, default=int(os.environ.get("WATCHREMOTE_DOOR_PORT", "2419")))
    parser.add_argument("--secret-file", default=os.environ.get("GROK_AGENT_SECRET_FILE", "~/.config/watch-remote/agent-secret"))
    parser.add_argument("--relay-config", default="~/.config/watch-remote/outbound.json")
    parser.add_argument("--cwd", default=None, help="Chat folder. Default: a new empty folder, so no saved always-allow grant skips the approval cases.")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT)
    parser.add_argument("--second", default=DEFAULT_SECOND)
    parser.add_argument("--other", default=DEFAULT_OTHER)
    parser.add_argument("--expect", action="append", default=None, help="A word the first final answer must contain (default Argyle).")
    parser.add_argument("--other-expect", default="Amarillo")
    parser.add_argument("--timeout", type=float, default=120.0, help="Seconds a final answer may take.")
    parser.add_argument("--away", type=float, default=40.0, help="Seconds the phone sleeps in the background scenario.")
    parser.add_argument(
        "--only",
        default=",".join(SCENARIOS),
        help="Comma-separated scenarios: " + ", ".join(SCENARIOS) + ". watch-alone is the phone-free watch scenario.",
    )
    parser.add_argument("--out", default=str(HERE / "recordings" / time.strftime("%Y%m%d-%H%M%S")))
    parser.add_argument("--allow-skip", action="store_true", help="A skipped scenario (no relay pairing) does not fail the run.")
    args = parser.parse_args(argv)
    if args.cwd is None:
        args.cwd = tempfile.mkdtemp(prefix="watch-remote-e2e-")
    if args.expect is None:
        args.expect = ["Argyle"]
    wanted = [name.strip() for name in args.only.split(",") if name.strip()]
    unknown = [name for name in wanted if name not in RUNNERS]
    if unknown:
        parser.error("unknown scenarios: " + ", ".join(unknown))

    ctx = Context(args)
    out = Path(args.out)
    print(f"Watch Remote real-host check: {ctx.meta['grok']}, door {ctx.meta['door']}, recordings in {out}")
    grants = grants_report()
    if grants:
        print("Note: always-allow grants exist, so Grok may skip approval requests in those folders:")
        for path in grants:
            print(f"  {path}")
    failed = False
    for name in wanted:
        print(f"[{name}]", flush=True)
        recording = Recording(name, ctx.redactions)
        try:
            summary = RUNNERS[name](ctx, recording)
            ctx.results.append((name, True, summary))
            print(f"  PASS {summary}")
        except CheckFailed as error:
            skipped = str(error).startswith("skipped:")
            passed = skipped and args.allow_skip
            ctx.results.append((name, passed, str(error)))
            print(f"  {'SKIP' if skipped else 'FAIL'} {error}")
            failed = failed or not passed
        except Exception as error:  # noqa: BLE001 - a broken scenario is a failed scenario
            ctx.results.append((name, False, f"{type(error).__name__}: {error}"))
            print(f"  FAIL {type(error).__name__}: {error}")
            traceback.print_exc()
            failed = True
        finally:
            path = recording.write(out, ctx.meta)
            print(f"  recorded {len(recording.events)} events to {path}")
    print()
    for name, ok, summary in ctx.results:
        print(f"{'PASS' if ok else 'FAIL'} {name}: {summary}")
    print("RESULT: " + ("FAILED" if failed else "PASSED"))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
