#!/usr/bin/env python3
"""ChaCha20-Poly1305 and replay tests. Vectors match Node and the Swift tests."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import relaybox  # noqa: E402


RFC_KEY = bytes.fromhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
RFC_NONCE = bytes.fromhex("070000004041424344454647")
RFC_AAD = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
RFC_PLAIN = bytes.fromhex(
    "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a"
    "204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f72207468"
    "65206675747572652c2073756e73637265656e20776f756c642069742062653f"
)
RFC_CT = bytes.fromhex(
    "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282"
    "fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab3"
    "24e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d2658ddfc6407007"
)
RFC_TAG = bytes.fromhex("045a97c8077b2505b9aaa3b1c14df55f")

FRAME_KEY = bytes([0x11]) * 32
FRAME_PLAIN = b'{"id":"1","op":"ping"}'
FRAME_CT = bytes.fromhex("8bc31305497225517325c99e7a51aa28abcd1e803c99")
FRAME_TAG = bytes.fromhex("b2fdc500f2c20b7acda9b0c074211b68")


class RelayBoxTests(unittest.TestCase):
    def test_rfc_vector(self) -> None:
        ciphertext, tag = relaybox.aead_seal(RFC_KEY, RFC_NONCE, RFC_PLAIN, RFC_AAD)
        self.assertEqual(ciphertext, RFC_CT)
        self.assertEqual(tag, RFC_TAG)
        opened = relaybox.aead_open(RFC_KEY, RFC_NONCE, ciphertext, tag, RFC_AAD)
        self.assertEqual(opened, RFC_PLAIN)

    def test_frame_round_trip_matches_the_phone(self) -> None:
        frame = relaybox.seal(FRAME_PLAIN, FRAME_KEY, relaybox.WATCH_TO_HOST, 1)
        self.assertEqual(frame[:10], bytes.fromhex("01010000000000000001"))
        self.assertEqual(frame[10:-16], FRAME_CT)
        self.assertEqual(frame[-16:], FRAME_TAG)
        replay = relaybox.ReplayWindow()
        opened = relaybox.open_frame(frame, FRAME_KEY, relaybox.WATCH_TO_HOST, replay)
        self.assertEqual(opened, FRAME_PLAIN)
        reply = relaybox.seal(b'{"id":"1","op":"pong"}', FRAME_KEY, relaybox.HOST_TO_WATCH, 1)
        back = relaybox.open_frame(reply, FRAME_KEY, relaybox.HOST_TO_WATCH, relaybox.ReplayWindow())
        self.assertEqual(back, b'{"id":"1","op":"pong"}')

    def test_replay_is_rejected(self) -> None:
        frame = relaybox.seal(FRAME_PLAIN, FRAME_KEY, relaybox.WATCH_TO_HOST, 1)
        again = relaybox.seal(b"second", FRAME_KEY, relaybox.WATCH_TO_HOST, 2)
        replay = relaybox.ReplayWindow()
        self.assertEqual(relaybox.open_frame(frame, FRAME_KEY, relaybox.WATCH_TO_HOST, replay), FRAME_PLAIN)
        with self.assertRaises(relaybox.RelayBoxError):
            relaybox.open_frame(frame, FRAME_KEY, relaybox.WATCH_TO_HOST, replay)
        self.assertEqual(relaybox.open_frame(again, FRAME_KEY, relaybox.WATCH_TO_HOST, replay), b"second")
        restored = relaybox.ReplayWindow.restored(replay.highest)
        with self.assertRaises(relaybox.RelayBoxError):
            relaybox.open_frame(again, FRAME_KEY, relaybox.WATCH_TO_HOST, restored)
        nxt = relaybox.seal(b"third", FRAME_KEY, relaybox.WATCH_TO_HOST, 3)
        self.assertEqual(relaybox.open_frame(nxt, FRAME_KEY, relaybox.WATCH_TO_HOST, restored), b"third")

    def test_wrong_direction_and_bad_key(self) -> None:
        frame = relaybox.seal(FRAME_PLAIN, FRAME_KEY, relaybox.WATCH_TO_HOST, 4)
        with self.assertRaises(relaybox.RelayBoxError):
            relaybox.open_frame(frame, FRAME_KEY, relaybox.HOST_TO_WATCH, relaybox.ReplayWindow())
        fresh = relaybox.ReplayWindow()
        with self.assertRaises(relaybox.RelayBoxError):
            relaybox.open_frame(frame, bytes(32), relaybox.WATCH_TO_HOST, fresh)
        self.assertEqual(fresh.highest, 0)
        forged = bytearray(relaybox.seal(FRAME_PLAIN, FRAME_KEY, relaybox.WATCH_TO_HOST, 40))
        forged[-1] ^= 0x01
        with self.assertRaises(relaybox.RelayBoxError):
            relaybox.open_frame(bytes(forged), FRAME_KEY, relaybox.WATCH_TO_HOST, fresh)
        self.assertEqual(fresh.highest, 0)
        self.assertEqual(relaybox.open_frame(frame, FRAME_KEY, relaybox.WATCH_TO_HOST, fresh), FRAME_PLAIN)


if __name__ == "__main__":
    unittest.main()
