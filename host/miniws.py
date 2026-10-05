"""A small WebSocket client for the outbound agent. Loopback may use ws. Everywhere else uses wss."""

from __future__ import annotations

import base64
import os
import socket
import ssl
from urllib.parse import urlsplit


class SocketError(OSError):
    pass


class WSConn:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buffer = b""

    def send(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length <= 0xFFFF:
            header.append(0x80 | 126)
            header += length.to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += length.to_bytes(8, "big")
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)

    def send_text(self, text: str) -> None:
        self.send(1, text.encode("utf-8"))

    def send_binary(self, payload: bytes) -> None:
        self.send(2, payload)

    def pending(self) -> bool:
        return _parse(self.buffer) is not None

    def recv(self) -> tuple[int, bytes]:
        while True:
            opcode, payload = self._recv_one()
            if opcode == 9:
                self.send(10, payload)
                continue
            if opcode == 8:
                raise SocketError("The socket closed.")
            if opcode == 10:
                continue
            return opcode, payload

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            return

    def _recv_one(self) -> tuple[int, bytes]:
        while True:
            parsed = _parse(self.buffer)
            if parsed is not None:
                opcode, payload, size = parsed
                self.buffer = self.buffer[size:]
                return opcode, payload
            chunk = self.sock.recv(8192)
            if not chunk:
                raise SocketError("The socket closed.")
            self.buffer += chunk


def connect(url: str, timeout: float = 10, headers: dict[str, str] | None = None) -> WSConn:
    parts = urlsplit(url.strip())
    scheme = (parts.scheme or "").lower()
    host = parts.hostname or ""
    if not host:
        raise SocketError("The relay URL is missing a host.")
    if parts.username or parts.password or parts.query or parts.fragment:
        raise SocketError("The relay URL cannot carry a token or a password.")
    port = parts.port or (443 if scheme == "wss" else 80)
    path = parts.path or "/"
    if scheme == "wss":
        raw = socket.create_connection((host, port), timeout=timeout)
        context = ssl.create_default_context()
        sock: socket.socket = context.wrap_socket(raw, server_hostname=host)
    elif scheme == "ws" and host in {"127.0.0.1", "localhost"}:
        sock = socket.create_connection((host, port), timeout=timeout)
    else:
        raise SocketError("The relay URL has to be wss.")
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    host_header = host if port in {80, 443} else f"{host}:{port}"
    extra = _header_block(headers)
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"{extra}"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    header = b""
    while b"\r\n\r\n" not in header:
        chunk = sock.recv(1)
        if not chunk:
            raise SocketError("The relay closed the connection.")
        header += chunk
        if len(header) > 8192:
            raise SocketError("The relay did not accept the connection.")
    status = header.split(b"\r\n", 1)[0]
    if b" 101 " not in status and not status.endswith(b" 101"):
        raise SocketError("The relay did not accept the connection.")
    conn = WSConn(sock)
    leftover = header.split(b"\r\n\r\n", 1)[1]
    conn.buffer = leftover
    sock.settimeout(timeout)
    return conn


def _header_block(headers: dict[str, str] | None) -> str:
    if not headers:
        return ""
    lines: list[str] = []
    for name, value in headers.items():
        if not name or any(ord(char) < 0x21 or ord(char) > 0x7E for char in name):
            raise SocketError("A header name is not usable.")
        if any(ord(char) < 0x20 or ord(char) > 0x7E for char in value):
            raise SocketError("A header value is not usable.")
        lines.append(f"{name}: {value}")
    return "\r\n".join(lines) + "\r\n"


def _parse(buffer: bytes) -> tuple[int, bytes, int] | None:
    if len(buffer) < 2:
        return None
    length = buffer[1] & 0x7F
    offset = 2
    if length == 126:
        if len(buffer) < 4:
            return None
        length = int.from_bytes(buffer[2:4], "big")
        offset = 4
    elif length == 127:
        if len(buffer) < 10:
            return None
        length = int.from_bytes(buffer[2:10], "big")
        offset = 10
    masked = buffer[1] & 0x80
    mask_len = 4 if masked else 0
    total = offset + mask_len + length
    if len(buffer) < total:
        return None
    payload = buffer[offset + mask_len : total]
    if masked:
        mask = buffer[offset : offset + 4]
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return buffer[0] & 0x0F, payload, total
