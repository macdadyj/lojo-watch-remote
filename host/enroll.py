"""One-shot pairing channel. The iPhone posts its public key. This process adds it and exits.

The listener binds to the overlay address from the QR, or to 127.0.0.1 in tests.
It checks a single-use ticket, then stops. It does not log the ticket or the key.
"""

from __future__ import annotations

import hmac
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pairing

DEFAULT_PORT = 2478
TTL_SECONDS = 600
MAX_BODY = 2048
MAX_FAILURES = 8


class EnrollError(Exception):
    pass


def serve_enroll(address: str, port: int, ticket: str, keys_path: Path, timeout: float = TTL_SECONDS) -> str:
    if not ticket or pairing.normalize_token(ticket) != ticket:
        raise EnrollError("The one-time pairing ticket is not usable.")
    if address not in {"127.0.0.1", "localhost"} and not pairing.in_overlay(address):
        raise EnrollError("The pairing channel only listens on the private overlay.")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise EnrollError("The pairing channel port is not usable.")

    outcome = {"value": "expired"}
    failures = {"n": 0}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:
            return

        def log_error(self, format: str, *args: object) -> None:
            return

        def do_GET(self) -> None:
            self._reply(404, b"Not found\n")

        def do_POST(self) -> None:
            if self.path.split("?", 1)[0] != "/v1/enroll":
                self._reply(404, b"Not found\n")
                return
            length = self.headers.get("Content-Length", "0")
            if not length.isdigit() or int(length) > MAX_BODY:
                self._reply(400, b"Refused\n")
                return
            body = self.rfile.read(int(length))
            header = self.headers.get("Authorization", "")
            presented = header[7:].strip() if header.lower().startswith("bearer ") else ""
            if not hmac.compare_digest(presented, ticket):
                failures["n"] += 1
                self._reply(401, b"Refused\n")
                if failures["n"] >= MAX_FAILURES:
                    outcome["value"] = "refused"
                return
            try:
                pairing.authorize_key(body.decode("utf-8"), keys_path)
            except (UnicodeError, pairing.PairingError):
                self._reply(400, b"Refused\n")
                return
            outcome["value"] = "enrolled"
            self._reply(200, b'{"ok":true}\n')

        def _reply(self, status: int, payload: bytes) -> None:
            kind = "application/json" if status == 200 else "text/plain"
            self.send_response(status)
            self.send_header("Content-Type", f"{kind}; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer((address, port), Handler)
    server.timeout = 0.5
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline and outcome["value"] == "expired":
            server.handle_request()
    finally:
        server.server_close()
    return outcome["value"]
