import hashlib
import json
import os
import secrets
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from subprocess import check_call, check_output

from watchremote_relay.adapters.acp import ACPAdapter
from watchremote_relay.adapters.cli import CLIAdapter
from watchremote_relay.adapters.mock import MockAdapter

LOOPBACK = "127.0.0.1"


class TokenStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._hashes: set[str] = set()
        if path.exists():
            self._hashes = set(json.loads(path.read_text() or "[]"))

    def issue(self) -> str:
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        with self._lock:
            self._hashes.add(digest)
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(sorted(self._hashes)))
            os.chmod(self.path, 0o600)
        return token

    def accepts(self, token: str) -> bool:
        digest = hashlib.sha256(token.encode()).hexdigest()
        with self._lock:
            return digest in self._hashes


def build_adapter(name: str):
    if name == "acp":
        return ACPAdapter()
    if name == "cli":
        return CLIAdapter()
    if name == "mock":
        return MockAdapter()
    raise SystemExit(f"Unknown adapter {name}")


def make_handler(adapter, tokens: TokenStore, admin: str):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args) -> None:
            print(f"relay {self.command} {self.path} {args[1] if len(args) > 1 else ''}")

        def do_GET(self) -> None:
            if self.path == "/health":
                self._json(200, {"ok": True, "adapter": adapter.name})
                return
            if not self._authorized():
                return
            if self.path.split("?", 1)[0] == "/v1/sessions":
                self._json(200, {"sessions": adapter.list_sessions()})
                return
            self._json(404, {"error": "Not found"})

        def do_POST(self) -> None:
            path = self.path.split("?", 1)[0]
            if path == "/v1/pair":
                if self._bearer() != admin:
                    self._json(401, {"error": "Admin token required"})
                    return
                self._json(201, {"token": tokens.issue()})
                return
            if not self._authorized():
                return
            body = self._body()
            if path == "/v1/sessions":
                prompt = str(body.get("prompt") or "").strip()
                if not prompt:
                    self._json(400, {"error": "Prompt is empty"})
                    return
                try:
                    session = adapter.start(prompt, str(body.get("cwd") or ""))
                except Exception as exc:  # noqa: BLE001
                    self._json(502, {"error": str(exc)})
                    return
                self._json(201, session)
                return
            if path.startswith("/v1/sessions/") and path.endswith("/cancel"):
                session_id = path.removeprefix("/v1/sessions/").removesuffix("/cancel").strip("/")
                adapter.cancel(session_id)
                self._json(200, {"ok": True})
                return
            if path.startswith("/v1/permissions/"):
                permission_id = path.removeprefix("/v1/permissions/").strip("/")
                try:
                    adapter.decide(permission_id, bool(body.get("allow")))
                except Exception as exc:  # noqa: BLE001
                    self._json(409, {"error": str(exc)})
                    return
                self._json(200, {"ok": True})
                return
            self._json(404, {"error": "Not found"})

        def _authorized(self) -> bool:
            token = self._bearer()
            if token and tokens.accepts(token):
                return True
            self._json(401, {"error": "Device token required"})
            return False

        def _bearer(self) -> str:
            header = self.headers.get("Authorization", "")
            prefix = "Bearer "
            return header[len(prefix):].strip() if header.startswith(prefix) else ""

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            if not raw:
                return {}
            try:
                value = json.loads(raw)
            except json.JSONDecodeError:
                return {}
            return value if isinstance(value, dict) else {}

        def _json(self, status: int, payload: dict) -> None:
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def _ipv4(text: str) -> tuple[int, int, int, int] | None:
    parts = text.split(".")
    if len(parts) != 4:
        return None
    numbers: list[int] = []
    for part in parts:
        if not part.isdigit():
            return None
        # Leading zeros are not canonical decimal. getaddrinfo may treat them as octal.
        if len(part) > 1 and part.startswith("0"):
            return None
        number = int(part)
        if number > 255:
            return None
        numbers.append(number)
    return numbers[0], numbers[1], numbers[2], numbers[3]


def _canonical(numbers: tuple[int, int, int, int]) -> str:
    return ".".join(str(number) for number in numbers)


def in_overlay(host: str) -> bool:
    numbers = _ipv4(host)
    if numbers is None:
        return False
    first, second, _, _ = numbers
    return first == 100 and 64 <= second <= 127


def bind_address(host: str) -> str:
    if host == LOOPBACK:
        return host
    numbers = _ipv4(host)
    if numbers is not None and in_overlay(host):
        return _canonical(numbers)
    raise SystemExit(
        "Set WATCHREMOTE_RELAY_BIND to an address in 100.64.0.0/10, or 127.0.0.1. "
        "The relay has no default address and refuses public addresses."
    )


def configured_bind() -> str:
    raw = os.environ.get("WATCHREMOTE_RELAY_BIND", "").strip()
    if not raw:
        raise SystemExit("Set WATCHREMOTE_RELAY_BIND. The relay has no default address.")
    return bind_address(raw)


def main() -> None:
    host = configured_bind()
    port = int(os.environ.get("WATCHREMOTE_RELAY_PORT", "2479"))
    admin = os.environ.get("WATCHREMOTE_RELAY_ADMIN", "")
    if not admin:
        raise SystemExit("Set WATCHREMOTE_RELAY_ADMIN to pair devices. It is not stored in git.")
    state = Path(os.environ.get("WATCHREMOTE_RELAY_STATE", os.path.expanduser("~/.config/watch-remote")))
    tokens = TokenStore(state / "device-tokens.json")
    adapter = build_adapter(os.environ.get("WATCHREMOTE_RELAY_ADAPTER", "acp"))
    handler = make_handler(adapter, tokens, admin)
    server = ThreadingHTTPServer((host, port), handler)
    if os.environ.get("WATCHREMOTE_RELAY_TLS", "1") != "0":
        cert, key = _ensure_cert(state, host)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        print(f"relay tls fingerprint {_fingerprint(cert)}")
    print(f"relay listening on {host}:{port} adapter={adapter.name}")
    server.serve_forever()


def _ensure_cert(state: Path, host: str) -> tuple[Path, Path]:
    cert = state / "relay.crt"
    key = state / "relay.key"
    if cert.exists() and key.exists():
        return cert, key
    state.mkdir(parents=True, exist_ok=True)
    names = [f"IP:{host}"]
    if host != LOOPBACK:
        names.append(f"IP:{LOOPBACK}")
    check_call([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "825",
        "-subj", "/CN=watch-remote-relay",
        "-addext", "subjectAltName=" + ",".join(names),
    ])
    os.chmod(key, 0o600)
    return cert, key


def _fingerprint(cert: Path) -> str:
    raw = check_output(["openssl", "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha256"], text=True)
    return raw.strip().split("=", 1)[-1].replace(":", "").lower()
