"""End-to-end frames for the Watch direct connection.

ChaCha20-Poly1305 (RFC 8439). The nonce is the direction plus the counter.
The relay forwards the frame and cannot read it.
"""

from __future__ import annotations

import json
import struct


class RelayBoxError(ValueError):
    pass


def _rotl(value: int, bits: int) -> int:
    return ((value << bits) | (value >> (32 - bits))) & 0xFFFFFFFF


def _quarter(state: list[int], a: int, b: int, c: int, d: int) -> None:
    state[a] = (state[a] + state[b]) & 0xFFFFFFFF
    state[d] ^= state[a]
    state[d] = _rotl(state[d], 16)
    state[c] = (state[c] + state[d]) & 0xFFFFFFFF
    state[b] ^= state[c]
    state[b] = _rotl(state[b], 12)
    state[a] = (state[a] + state[b]) & 0xFFFFFFFF
    state[d] ^= state[a]
    state[d] = _rotl(state[d], 8)
    state[c] = (state[c] + state[d]) & 0xFFFFFFFF
    state[b] ^= state[c]
    state[b] = _rotl(state[b], 7)


def _chacha_block(key: bytes, counter: int, nonce: bytes) -> bytes:
    def u32(blob: bytes) -> int:
        return int.from_bytes(blob, "little")

    constants = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574]
    key_words = [u32(key[index : index + 4]) for index in range(0, 32, 4)]
    nonce_words = [u32(nonce[index : index + 4]) for index in range(0, 12, 4)]
    state = constants + key_words + [counter & 0xFFFFFFFF] + nonce_words
    working = state.copy()
    for _ in range(10):
        _quarter(working, 0, 4, 8, 12)
        _quarter(working, 1, 5, 9, 13)
        _quarter(working, 2, 6, 10, 14)
        _quarter(working, 3, 7, 11, 15)
        _quarter(working, 0, 5, 10, 15)
        _quarter(working, 1, 6, 11, 12)
        _quarter(working, 2, 7, 8, 13)
        _quarter(working, 3, 4, 9, 14)
    out = bytearray()
    for index in range(16):
        out += ((working[index] + state[index]) & 0xFFFFFFFF).to_bytes(4, "little")
    return bytes(out)


def _poly1305(message: bytes, key: bytes) -> bytes:
    r_raw = int.from_bytes(key[:16], "little")
    r_raw &= 0x0FFFFFFC0FFFFFFC0FFFFFFC0FFFFFFF
    s_raw = int.from_bytes(key[16:32], "little")
    prime = (1 << 130) - 5
    accumulator = 0
    for offset in range(0, len(message), 16):
        block = message[offset : offset + 16]
        number = int.from_bytes(block + b"\x01", "little")
        accumulator = (accumulator + number) * r_raw % prime
    accumulator = (accumulator + s_raw) & ((1 << 128) - 1)
    return accumulator.to_bytes(16, "little")


def _pad16(data: bytes) -> bytes:
    extra = len(data) % 16
    if extra == 0:
        return b""
    return b"\x00" * (16 - extra)


def aead_seal(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes = b"") -> tuple[bytes, bytes]:
    if len(key) != 32 or len(nonce) != 12:
        raise RelayBoxError("bad key")
    one_time = _chacha_block(key, 0, nonce)[:32]
    ciphertext = bytearray()
    counter = 1
    offset = 0
    while offset < len(plaintext):
        block = _chacha_block(key, counter, nonce)
        chunk = plaintext[offset : offset + 64]
        ciphertext += bytes(left ^ right for left, right in zip(chunk, block))
        offset += 64
        counter += 1
    body = bytes(ciphertext)
    mac_data = (
        aad
        + _pad16(aad)
        + body
        + _pad16(body)
        + len(aad).to_bytes(8, "little")
        + len(body).to_bytes(8, "little")
    )
    return body, _poly1305(mac_data, one_time)


def aead_open(key: bytes, nonce: bytes, ciphertext: bytes, tag: bytes, aad: bytes = b"") -> bytes:
    one_time = _chacha_block(key, 0, nonce)[:32]
    mac_data = (
        aad
        + _pad16(aad)
        + ciphertext
        + _pad16(ciphertext)
        + len(aad).to_bytes(8, "little")
        + len(ciphertext).to_bytes(8, "little")
    )
    expected = _poly1305(mac_data, one_time)
    if len(tag) != 16 or not _same(expected, tag):
        raise RelayBoxError("refused")
    plaintext = bytearray()
    counter = 1
    offset = 0
    while offset < len(ciphertext):
        block = _chacha_block(key, counter, nonce)
        chunk = ciphertext[offset : offset + 64]
        plaintext += bytes(left ^ right for left, right in zip(chunk, block))
        offset += 64
        counter += 1
    return bytes(plaintext)


def _same(left: bytes, right: bytes) -> bool:
    if len(left) != len(right):
        return False
    diff = 0
    for a_byte, b_byte in zip(left, right):
        diff |= a_byte ^ b_byte
    return diff == 0


WATCH_TO_HOST = 1
HOST_TO_WATCH = 2


class ReplayWindow:
    def __init__(self, highest: int = 0) -> None:
        self.highest = highest
        self.seen = 0 if highest == 0 else (1 << 64) - 1

    @classmethod
    def restored(cls, highest: int) -> "ReplayWindow":
        return cls(highest)

    def allows(self, counter: int) -> bool:
        trial = ReplayWindow()
        trial.highest = self.highest
        trial.seen = self.seen
        return trial.accept(counter)

    def accept(self, counter: int) -> bool:
        if counter <= 0:
            return False
        if self.highest == 0:
            self.highest = counter
            self.seen = 1
            return True
        if counter > self.highest:
            shift = counter - self.highest
            if shift >= 64:
                self.seen = 1
            else:
                self.seen = ((self.seen << shift) & ((1 << 64) - 1)) | 1
            self.highest = counter
            return True
        age = self.highest - counter
        if age >= 64:
            return False
        bit = 1 << age
        if self.seen & bit:
            return False
        self.seen |= bit
        return True


def nonce_bytes(direction: int, counter: int) -> bytes:
    return struct.pack(">IQ", direction, counter)


def seal(plaintext: bytes, key: bytes, direction: int, counter: int) -> bytes:
    if len(key) != 32 or counter <= 0:
        raise RelayBoxError("bad key")
    if direction not in (WATCH_TO_HOST, HOST_TO_WATCH):
        raise RelayBoxError("bad frame")
    nonce = nonce_bytes(direction, counter)
    ciphertext, tag = aead_seal(key, nonce, plaintext)
    return bytes([1, direction]) + struct.pack(">Q", counter) + ciphertext + tag


def open_frame(frame: bytes, key: bytes, expecting: int, replay: ReplayWindow) -> bytes:
    if len(key) != 32 or len(frame) < 2 + 8 + 16:
        raise RelayBoxError("bad frame")
    if frame[0] != 1 or frame[1] != expecting:
        raise RelayBoxError("wrong direction" if frame[0] == 1 else "bad frame")
    counter = struct.unpack(">Q", frame[2:10])[0]
    if not replay.allows(counter):
        raise RelayBoxError("replayed")
    body = frame[10:]
    ciphertext, tag = body[:-16], body[-16:]
    try:
        plain = aead_open(key, nonce_bytes(expecting, counter), ciphertext, tag)
    except RelayBoxError:
        raise
    except Exception as error:
        raise RelayBoxError("refused") from error
    if not replay.accept(counter):
        raise RelayBoxError("replayed")
    return plain


def encode_message(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")


def decode_message(data: bytes) -> dict:
    value = json.loads(data)
    if not isinstance(value, dict) or "op" not in value or "id" not in value:
        raise RelayBoxError("bad frame")
    return value
