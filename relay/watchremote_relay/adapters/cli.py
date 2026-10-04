import json
import os
import re
import subprocess
import threading
import time
import uuid


class CLIAdapter:
    """Wraps `grok -p` streaming-json. No interactive approvals; stopping closes the process."""

    name = "cli"

    def __init__(self) -> None:
        self.sessions: dict[str, dict] = {}
        self._procs: dict[str, subprocess.Popen[str]] = {}
        self._lock = threading.Lock()

    def list_sessions(self) -> list[dict]:
        listed = self._run_list()
        with self._lock:
            known = {item["id"]: item for item in self.sessions.values()}
        for item in listed:
            known.setdefault(item["id"], item)
        return list(known.values())

    def start(self, prompt: str, cwd: str) -> dict:
        session_id = str(uuid.uuid4())
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
        thread = threading.Thread(target=self._run, args=(session_id, prompt, cwd), daemon=True)
        thread.start()
        return session

    def cancel(self, session_id: str) -> None:
        with self._lock:
            proc = self._procs.get(session_id)
            session = self.sessions.get(session_id)
        if proc is not None and proc.poll() is None:
            proc.kill()
        if session is not None:
            session["status"] = "stopped"
            session["summary"] = "Stopped."
            session["updatedAt"] = time.time()

    def decide(self, permission_id: str, allow: bool) -> None:
        raise RuntimeError("Command mode cannot approve or deny. Use the agent server.")

    def _binary(self) -> str:
        override = os.environ.get("GROK_BIN")
        if override:
            return override
        home = os.path.expanduser("~/.grok/bin/grok")
        return home if os.path.isfile(home) and os.access(home, os.X_OK) else "grok"

    def _run(self, session_id: str, prompt: str, cwd: str) -> None:
        command = [
            self._binary(),
            "-p",
            prompt,
            "--output-format",
            "streaming-json",
            "--no-auto-update",
            "--permission-mode",
            "dontAsk",
        ]
        if cwd:
            command.extend(["--cwd", cwd])
        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        with self._lock:
            self._procs[session_id] = proc
        assert proc.stdout is not None
        summary: list[str] = []
        remote_id = session_id
        for line in proc.stdout:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = event.get("type")
            session = self.sessions[session_id]
            if kind == "text":
                summary.append(str(event.get("data") or ""))
                session["summary"] = " ".join("".join(summary).split())[:280]
            elif kind == "tool_call":
                session["summary"] = f"Using {event.get('title') or event.get('toolName') or 'a tool'}."
            elif kind == "end":
                remote_id = str(event.get("sessionId") or session_id)
                session["status"] = "idle"
            elif kind == "error":
                session["status"] = "failed"
                session["summary"] = str(event.get("message") or "The task failed.")
            session["updatedAt"] = time.time()
        code = proc.wait()
        session = self.sessions[session_id]
        if code != 0 and session["status"] == "running":
            session["status"] = "failed"
            session["summary"] = f"The task ended with status {code}."
        if remote_id != session_id:
            session["id"] = remote_id
            self.sessions[remote_id] = session
            self.sessions.pop(session_id, None)

    def _run_list(self) -> list[dict]:
        try:
            completed = subprocess.run(
                [self._binary(), "sessions", "list", "--limit", "20"],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired):
            return []
        return _parse_table(completed.stdout)


def _parse_table(text: str) -> list[dict]:
    found = []
    pattern = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    for line in text.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        session_id = match.group(0)
        summary = line[match.end():].strip() or session_id
        found.append({
            "id": session_id,
            "title": summary[:80],
            "summary": summary[:280],
            "status": "idle",
            "updatedAt": time.time(),
            "cwd": "",
            "permission": None,
        })
    return found
