from typing import Protocol


class Adapter(Protocol):
    name: str

    def list_sessions(self) -> list[dict]:
        ...

    def start(self, prompt: str, cwd: str) -> dict:
        ...

    def cancel(self, session_id: str) -> None:
        ...

    def decide(self, permission_id: str, allow: bool) -> None:
        ...

    def restore(self, session_id: str) -> dict:
        ...

    def continue_session(self, session_id: str, prompt: str, cwd: str) -> dict:
        ...
