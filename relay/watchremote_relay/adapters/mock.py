import time
import uuid


class MockAdapter:
    name = "mock"

    def __init__(self) -> None:
        self.sessions: dict[str, dict] = {}

    def list_sessions(self) -> list[dict]:
        return list(self.sessions.values())

    def start(self, prompt: str, cwd: str) -> dict:
        session_id = str(uuid.uuid4())
        title = " ".join(prompt.split()[:6]) or "New task"
        permission_id = f"perm-{session_id}"
        session = {
            "id": session_id,
            "title": title,
            "summary": "Waiting for you to allow or deny a command.",
            "status": "needsApproval",
            "updatedAt": time.time(),
            "cwd": cwd,
            "permission": {
                "id": permission_id,
                "sessionID": session_id,
                "rpcID": "11",
                "rpcIDIsNumber": True,
                "title": "Run the project tests",
                "detail": "Demo relay permission.",
                "allowOptionID": "allow-once",
                "denyOptionID": "reject-once",
            },
        }
        self.sessions[session_id] = session
        return session

    def cancel(self, session_id: str) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        session["status"] = "stopped"
        session["permission"] = None
        session["summary"] = "Stopped."
        session["updatedAt"] = time.time()

    def decide(self, permission_id: str, allow: bool) -> None:
        for session in self.sessions.values():
            permission = session.get("permission") or {}
            if permission.get("id") != permission_id:
                continue
            session["permission"] = None
            session["status"] = "idle" if allow else "stopped"
            session["summary"] = "Allowed." if allow else "Denied."
            session["updatedAt"] = time.time()
            return

    def restore(self, session_id: str) -> dict:
        session = self.sessions.get(session_id)
        if session is None:
            raise RuntimeError("That chat is no longer on this computer.")
        lines = list(session.get("lines") or [])
        if not lines:
            lines = [part for part in (session.get("title"), session.get("summary")) if part]
        return {"lines": lines, "session": session}

    def continue_session(self, session_id: str, prompt: str, cwd: str) -> dict:
        session = self.sessions.get(session_id)
        if session is None:
            raise RuntimeError("That chat is no longer on this computer.")
        lines = list(session.get("lines") or [])
        lines.append(f"You: {prompt}")
        lines.append(f"Grok: Done. {prompt}")
        session["lines"] = lines
        session["summary"] = f"Done. {prompt}"
        session["status"] = "idle"
        session["updatedAt"] = time.time()
        if cwd:
            session["cwd"] = cwd
        return session
