#!/usr/bin/env python3
"""A Watch stand-in that uses the relay's HTTPS long-poll, the same path the Watch app takes.

Used by the host tests and by the transport harness self-check.
"""

from __future__ import annotations

import base64
import http.client
import io
import json
import time
import urllib.error
from email.message import Message
from typing import Callable
from urllib.parse import urlsplit

import outbound
import relaybox


class HttpWatch:
    """Watch stand-in. Speaks HTTP/1.1 on a new connection per poll, with no phone in the path."""

    def __init__(self, base_url: str, token: str, key: bytes, on_message: Callable[[dict], None] | None = None) -> None:
        self.on_message = on_message
        self.url = base_url.rstrip("/") + "/v1/watch"
        self.token = token
        self.key = key
        self.after = 0
        self.epoch = ""
        self.counter = 0
        self.replay = relaybox.ReplayWindow()
        self.host_online = False
        self.http_version = 0
        self.inbox: list[dict] = []
        self.next_id = 0

    def poll(self, send: list[dict] | None = None, wait_ms: int = 0) -> list[dict]:
        frames = []
        for message in send or []:
            self.counter = outbound.next_counter(self.counter)
            sealed = relaybox.seal(relaybox.encode_message(message), self.key, relaybox.WATCH_TO_HOST, self.counter)
            frames.append(base64.b64encode(sealed).decode("ascii"))
        body = json.dumps({"send": frames, "after": self.after, "epoch": self.epoch, "wait": wait_ms}).encode("utf-8")
        raw = self._post(body, timeout=wait_ms / 1000 + 10)
        reply = json.loads(raw.decode("utf-8"))
        if reply.get("epoch") != self.epoch:
            # A new epoch restarts sequence numbers at 1. Keeping the old cursor would ack them unseen.
            self.epoch = str(reply.get("epoch") or "")
            self.after = 0
        self.host_online = bool(reply.get("host"))
        opened: list[dict] = []
        for frame in reply.get("frames") or []:
            self.after = max(self.after, int(frame.get("seq") or 0))
            try:
                plain = relaybox.open_frame(base64.b64decode(frame["data"]), self.key, relaybox.HOST_TO_WATCH, self.replay)
                message = relaybox.decode_message(plain)
            except (relaybox.RelayBoxError, ValueError, KeyError):
                continue
            opened.append(message)
            if self.on_message is not None:
                self.on_message(message)
        self.inbox.extend(opened)
        return opened

    def _post(self, body: bytes, timeout: float) -> bytes:
        parts = urlsplit(self.url)
        if parts.scheme == "https":
            connection: http.client.HTTPConnection = http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=timeout)
        elif parts.scheme == "http":
            connection = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout)
        else:
            raise RuntimeError("Watch poll address is not http or https")
        path = parts.path or "/"
        if parts.query:
            path = f"{path}?{parts.query}"
        try:
            connection.request(
                "POST",
                path,
                body=body,
                headers={
                    "Authorization": f"Bearer {self.token}",
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    "Connection": "close",
                },
            )
            response = connection.getresponse()
            raw = response.read()
            version = response.version
            status = response.status
            reason = response.reason
        finally:
            connection.close()
        if version != 11:
            major, minor = divmod(version, 10)
            raise RuntimeError(f"Watch poll got HTTP/{major}.{minor}; this path is HTTP/1.1")
        self.http_version = version
        if status >= 400:
            raise urllib.error.HTTPError(self.url, status, reason, Message(), io.BytesIO(raw))
        return raw

    def send(self, op: str, **fields: object) -> str:
        self.next_id += 1
        ident = f"w{self.next_id}"
        message = {"op": op, "id": ident}
        message.update({key: value for key, value in fields.items() if value is not None})
        self.poll([message])
        return ident

    def wait_for(self, predicate, timeout: float = 15.0) -> dict:
        deadline = time.time() + timeout
        while True:
            for message in self.inbox:
                if predicate(message):
                    return message
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("no matching frame from the host")
            try:
                self.poll(wait_ms=int(min(remaining, 5) * 1000))
            except (urllib.error.URLError, OSError):
                time.sleep(0.2)


def reply_in(message: dict, session_id: str, text: str) -> bool:
    if message.get("op") not in {"update", "sessions"}:
        return False
    for row in message.get("sessions") or []:
        if row.get("id") == session_id and any(text in str(line) for line in row.get("transcript") or []):
            return True
    return False
