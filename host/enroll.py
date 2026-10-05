"""One-shot pairing channel. The iPhone posts its public key. This process adds it and exits.

The listener binds to the overlay address from the QR, or to 127.0.0.1 in tests.
It checks a single-use ticket, then stops. It does not log the ticket or the key.
"""

from __future__ import annotations

import hmac
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pairing

DEFAULT_PORT = 2478
TTL_SECONDS = 600
MAX_BODY = 2048
MAX_FAILURES = 8
SOCKET_TIMEOUT = 10


class EnrollError(Exception):
    pass


def _bearer(header: object) -> str | None:
    """ASCII token after ``Bearer``, or None when the header is missing or malformed."""
    try:
        if not isinstance(header, str):
            return None
        text = header.strip()
        if len(text) < 7 or text[:7].lower() != "bearer ":
            return None
        token = text[7:].strip()
        if not token or not token.isascii():
            return None
        if any(ord(char) < 0x21 or ord(char) > 0x7E for char in token):
            return None
        return token
    except (UnicodeError, ValueError, AttributeError):
        return None


def serve_enroll(
    address: str,
    port: int,
    ticket: str,
    keys_path: Path,
    timeout: float = TTL_SECONDS,
    ready: threading.Event | None = None,
    socket_timeout: float = SOCKET_TIMEOUT,
    bound: dict[str, int] | None = None,
) -> str:
    if not ticket or pairing.normalize_token(ticket) != ticket:
        raise EnrollError("The one-time pairing ticket is not usable.")
    if address not in {"127.0.0.1", "localhost"} and not pairing.in_overlay(address):
        raise EnrollError("The pairing channel only listens on the private overlay.")
    # Port 0 asks the kernel for an ephemeral port. Tests use that so they do not rebind a just-closed socket.
    ephemeral = port == 0 and address in {"127.0.0.1", "localhost"}
    if isinstance(port, bool) or not isinstance(port, int) or not (ephemeral or 1 <= port <= 65535):
        raise EnrollError("The pairing channel port is not usable.")

    outcome = {"value": "expired"}
    failures = {"n": 0}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(socket_timeout)

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
            if not isinstance(length, str) or not length.isdigit() or int(length) > MAX_BODY:
                self._reply(400, b"Refused\n")
                return
            try:
                body = self.rfile.read(int(length))
            except (TimeoutError, socket.timeout, OSError):
                self._fail_auth()
                return
            if not self._authorized():
                return
            try:
                pairing.authorize_key(body.decode("utf-8"), keys_path)
            except (UnicodeError, pairing.PairingError):
                self._reply(400, b"Refused\n")
                return
            outcome["value"] = "enrolled"
            self._reply(200, b'{"ok":true}\n')

        def _authorized(self) -> bool:
            try:
                presented = _bearer(self.headers.get("Authorization"))
                ok = presented is not None and hmac.compare_digest(presented, ticket)
            except (TypeError, ValueError, UnicodeError):
                ok = False
            if ok:
                return True
            self._fail_auth()
            return False

        def _fail_auth(self) -> None:
            failures["n"] += 1
            if failures["n"] >= MAX_FAILURES and outcome["value"] == "expired":
                outcome["value"] = "refused"
            try:
                self._reply(401, b"Refused\n")
            except (TimeoutError, socket.timeout, OSError):
                return

        def _reply(self, status: int, payload: bytes) -> None:
            kind = "application/json" if status == 200 else "text/plain"
            self.send_response(status)
            self.send_header("Content-Type", f"{kind}; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

    class EnrollServer(ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True

        def server_bind(self) -> None:
            # HTTPServer.server_bind calls getfqdn, which can stall on a reverse lookup.
            # The phone is already waiting. Bind, then use the address we asked for.
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.socket.bind(self.server_address)
            self.server_address = self.socket.getsockname()
            host, chosen = self.server_address[:2]
            self.server_name = host
            self.server_port = chosen

    server = EnrollServer((address, port), Handler)
    server.timeout = 0.5
    if bound is not None:
        bound["port"] = int(server.server_address[1])
    if ready is not None:
        ready.set()
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline and outcome["value"] == "expired":
            server.handle_request()
    finally:
        server.server_close()
    return outcome["value"]
