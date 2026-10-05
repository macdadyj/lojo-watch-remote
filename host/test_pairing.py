#!/usr/bin/env python3
"""Self-test for the pairing payload. Uses placeholders only."""

from __future__ import annotations

import base64
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import enroll  # noqa: E402
import pairing  # noqa: E402
import qrcodegen  # noqa: E402


FINGERPRINT = "SHA256:" + ("A" * 43)
GOLDEN = (
    "eyJhZGRyZXNzIjoiMTAwLjY0LjAuMiIsImZpbmdlcnByaW50IjoiU0hBMjU2OkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJsYWJlbCI6ImV4YW1wbGUtaG9zdCIsInBvcnQiOjIyLCJzZWNyZXQiOiJleGFtcGxlLXNlY3JldCIsInVzZXIiOiJ1c2VyIiwidiI6MX0"
)
BARE = "eyJhZGRyZXNzIjoiMTAwLjY0LjAuMSIsImxhYmVsIjoiZXhhbXBsZS1ob3N0IiwicG9ydCI6MjIsInVzZXIiOiJ1c2VyIiwidiI6MX0"


class PairingTests(unittest.TestCase):
    def test_round_trip_matches_the_phone_token(self) -> None:
        payload = pairing.build_payload(
            "example-host",
            "100.64.0.2",
            "user",
            22,
            secret="example-secret",
            fingerprint="sha256:" + ("A" * 43) + "=",
        )
        self.assertEqual(payload["fingerprint"], FINGERPRINT)
        self.assertEqual(pairing.token_for(payload), GOLDEN)
        url = pairing.url_for(payload)
        self.assertTrue(url.startswith("watchremote://pair?d="))
        decoded = pairing.decode_text("  " + url + "\n")
        self.assertEqual(decoded, payload)
        summary = "\n".join(pairing.summary_lines(payload))
        self.assertNotIn("example-secret", summary)
        self.assertNotIn("example-secret", pairing.warning_text(True))
        self.assertIn("do not share", pairing.warning_text(True).lower())
        self.assertIn("screenshot", pairing.warning_text(True).lower())
        self.assertIn("watch-remote-authorize", pairing.authorize_hint())

    def test_optional_fields_and_overlay(self) -> None:
        bare = pairing.build_payload(" example-host ", "100.64.0.1", "user", 22)
        self.assertNotIn("secret", bare)
        self.assertEqual(pairing.token_for(bare), BARE)
        edge = pairing.decode_text(
            '{"v":1,"user":"user","port":22,"address":"100.127.255.254","label":"example-host"}'
        )
        self.assertEqual(edge["address"], "100.127.255.254")
        for refused in ("8.8.8.8", "10.0.0.1", "127.0.0.1", "192.168.1.1", "example-host", "100.064.0.1", "100.128.0.1"):
            with self.assertRaises(pairing.PairingError):
                pairing.build_payload("example-host", refused, "user", 22)
        with self.assertRaises(pairing.PairingError):
            pairing.build_payload("example-host", "100.64.0.2", "bad user", 22)
        with self.assertRaises(pairing.PairingError):
            pairing.build_payload("example-host", "100.64.0.2", "user", 22, secret="short")
        with self.assertRaises(pairing.PairingError):
            pairing.decode_text('{"v":2,"label":"example-host","address":"100.64.0.2","user":"user","port":22}')

    def test_address_scan_ignores_public_and_leading_zeros(self) -> None:
        text = "inet 10.0.0.1 netmask inet 100.64.0.2 inet 8.8.8.8 inet 100.064.0.1 inet 100.127.255.254"
        self.assertEqual(pairing.addresses_in(text), ["100.64.0.2", "100.127.255.254"])
        config = "# Port 2222\nPort 22\nMatch User user\n    Port 2200\n"
        self.assertEqual(pairing.port_from_config(config), 22)
        sample = f"256 {FINGERPRINT} example (ED25519)"
        self.assertEqual(pairing.fingerprint_from_ssh_keygen(sample), FINGERPRINT)

    def test_authorize_is_restricted_and_idempotent(self) -> None:
        public = "ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAAIExamplePublicKeyPlaceholderOnly watch-remote@iphone"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".ssh" / "authorized_keys"
            message = pairing.authorize_key(public, path)
            self.assertIn("127.0.0.1:2419", message)
            text = path.read_text(encoding="utf-8")
            self.assertIn('permitopen="127.0.0.1:2419"', text)
            self.assertIn('command="/bin/false"', text)
            self.assertIn("no-pty", text)
            self.assertTrue(pairing.exec_is_refused(text))
            self.assertFalse(pairing.exec_is_refused('restrict,port-forwarding,permitopen="127.0.0.1:2419" ' + public))
            self.assertNotIn("bash", text)
            self.assertIn(public, text)
            self.assertNotIn("PRIVATE", text)
            mode = stat.S_IMODE(path.stat().st_mode)
            self.assertEqual(mode, 0o600)
            dir_mode = stat.S_IMODE(path.parent.stat().st_mode)
            self.assertEqual(dir_mode, 0o700)
            pairing.authorize_key(public, path)
            self.assertEqual(path.read_text(encoding="utf-8").count("AAAAB3NzaC1lZDI1NTE5AAAAIExamplePublicKeyPlaceholderOnly"), 1)
            path.write_text(public + "\n", encoding="utf-8")
            pairing.authorize_key(f"watch-remote-authorize '{public}'", path)
            replaced = path.read_text(encoding="utf-8").strip()
            self.assertTrue(replaced.startswith('restrict,port-forwarding,permitopen="127.0.0.1:2419",command="/bin/false",no-pty '))
            self.assertTrue(pairing.exec_is_refused(replaced))
            self.assertEqual(replaced.count("AAAAB3NzaC1lZDI1NTE5AAAAIExamplePublicKeyPlaceholderOnly"), 1)
        with self.assertRaises(pairing.PairingError):
            pairing.parse_public_key("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n")

    def test_builtin_qr_has_a_finder(self) -> None:
        url = pairing.url_for(
            pairing.build_payload(
                "example-host",
                "100.64.0.2",
                "user",
                22,
                secret="example-secret",
                fingerprint=FINGERPRINT,
            )
        )
        qr = qrcodegen.QrCode.encode_text(url, qrcodegen.QrCode.Ecc.MEDIUM)
        self.assertGreaterEqual(qr.get_size(), 21)
        self.assertTrue(qr.get_module(0, 0))
        rendered = pairing.render_qr(url)
        self.assertIn("█", rendered)
        self.assertNotIn("example-secret", rendered)

    def test_direct_relay_fields_round_trip_without_leaking(self) -> None:
        raw_key = base64.urlsafe_b64encode(b"\x11" * 32).decode("ascii").rstrip("=")
        token = "roomtokenvalue0001"
        relay = "wss://relay.example/v1/room"
        payload = pairing.build_payload(
            "example-host",
            "100.64.0.2",
            "user",
            22,
            secret="example-secret",
            relay=relay,
            token=token,
            e2e=raw_key,
        )
        self.assertEqual(payload["relay"], relay)
        self.assertEqual(payload["token"], token)
        self.assertNotIn("=", payload["e2e"])
        summary = "\n".join(pairing.summary_lines(payload))
        self.assertIn("Direct connection included.", summary)
        self.assertNotIn(token, summary)
        self.assertNotIn(payload["e2e"], summary)
        self.assertNotIn("example-secret", summary)
        self.assertNotIn(relay, summary)
        decoded = pairing.decode_text(pairing.url_for(payload))
        self.assertEqual(decoded["token"], token)
        self.assertEqual(decoded["relay"], relay)
        for refused in ("ws://relay.example/v1/room", "wss://user:pass@relay.example/v1/room", "wss://relay.example/v1/room?token=abc"):
            with self.assertRaises(pairing.PairingError):
                pairing.build_payload("example-host", "100.64.0.2", "user", 22, relay=refused, token=token, e2e=raw_key)
        with self.assertRaises(pairing.PairingError):
            pairing.build_payload("example-host", "100.64.0.2", "user", 22, relay=relay, token="short", e2e=raw_key)
        with tempfile.TemporaryDirectory() as directory:
            path = pairing.write_outbound_file(relay, token, raw_key, Path(directory))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o077, 0)
            saved = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(saved["token"], token)
            import outbound

            loaded = outbound.load_config(path)
            self.assertEqual(loaded["relay"], relay)
            self.assertEqual(loaded["token"], token)
            self.assertEqual(loaded["key"], b"\x11" * 32)

    def test_enroll_ticket_is_single_use_and_not_in_the_summary(self) -> None:
        ticket = "roomtokenvalue0001"
        payload = pairing.build_payload(
            "example-host",
            "100.64.0.2",
            "user",
            22,
            ticket=ticket,
            enroll=2478,
        )
        summary = "\n".join(pairing.summary_lines(payload))
        self.assertIn("This iPhone can authorize itself.", summary)
        self.assertNotIn(ticket, summary)
        public = "ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAAIExamplePublicKeyPlaceholderOnly watch-remote@iphone"
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        with tempfile.TemporaryDirectory() as directory:
            keys = Path(directory) / "authorized_keys"
            result: dict[str, str] = {}
            ready = threading.Event()

            def run() -> None:
                try:
                    result["value"] = enroll.serve_enroll("127.0.0.1", port, ticket, keys, timeout=30, ready=ready)
                except Exception as exc:  # noqa: BLE001 — the assertion below reports it
                    result["error"] = f"{type(exc).__name__}: {exc}"

            worker = threading.Thread(target=run, daemon=True)
            worker.start()
            self.assertTrue(ready.wait(15), "listener did not become ready")
            bad = urllib.request.Request(
                f"http://127.0.0.1:{port}/v1/enroll",
                data=public.encode("utf-8"),
                headers={"Authorization": "Bearer not-the-ticket"},
                method="POST",
            )
            refused = False
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not refused:
                try:
                    urllib.request.urlopen(bad, timeout=10)
                except urllib.error.HTTPError as error:
                    self.assertEqual(error.code, 401)
                    refused = True
                except (urllib.error.URLError, TimeoutError, OSError):
                    time.sleep(0.05)
            self.assertTrue(refused, "bad-ticket 401 was not received")
            good = urllib.request.Request(
                f"http://127.0.0.1:{port}/v1/enroll",
                data=public.encode("utf-8"),
                headers={"Authorization": f"Bearer {ticket}"},
                method="POST",
            )
            with urllib.request.urlopen(good, timeout=10) as response:
                self.assertEqual(response.status, 200)
                self.assertIn(b'"ok":true', response.read())
            body = keys.read_text(encoding="utf-8")
            self.assertIn('permitopen="127.0.0.1:2419"', body)
            self.assertIn('command="/bin/false"', body)
            self.assertIn("no-pty", body)
            self.assertTrue(pairing.exec_is_refused(body))
            self.assertEqual(body.count("ExamplePublicKeyPlaceholderOnly"), 1)
            self.assertNotIn(ticket, body)
            worker.join(timeout=15)
            self.assertNotIn("error", result)
            self.assertEqual(result.get("value"), "enrolled")

    def test_non_ascii_bearer_counts_toward_the_failure_limit(self) -> None:
        ticket = "roomtokenvalue0001"
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        with tempfile.TemporaryDirectory() as directory:
            keys = Path(directory) / "authorized_keys"
            result: dict[str, str] = {}
            ready = threading.Event()

            def run() -> None:
                try:
                    result["value"] = enroll.serve_enroll("127.0.0.1", port, ticket, keys, timeout=20, ready=ready)
                except Exception as exc:  # noqa: BLE001 — the assertion below reports it
                    result["error"] = f"{type(exc).__name__}: {exc}"

            worker = threading.Thread(target=run, daemon=True)
            worker.start()
            self.assertTrue(ready.wait(15), "listener did not become ready")
            for _ in range(enroll.MAX_FAILURES):
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/v1/enroll",
                    data=b"ssh-ed25519 AAAA",
                    headers={"Authorization": "Bearer caf\u00e9"},
                    method="POST",
                )
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request, timeout=10)
                self.assertEqual(caught.exception.code, 401)
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive())
            self.assertNotIn("error", result)
            self.assertEqual(result.get("value"), "refused")
            self.assertFalse(keys.exists())

    def test_stalled_enroll_client_cannot_hold_the_listener(self) -> None:
        self.assertEqual(enroll.SOCKET_TIMEOUT, 10)
        ticket = "roomtokenvalue0001"
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        with tempfile.TemporaryDirectory() as directory:
            keys = Path(directory) / "authorized_keys"
            result: dict[str, str] = {}
            ready = threading.Event()

            def run() -> None:
                result["value"] = enroll.serve_enroll(
                    "127.0.0.1",
                    port,
                    ticket,
                    keys,
                    timeout=8,
                    ready=ready,
                    socket_timeout=1,
                )

            worker = threading.Thread(target=run, daemon=True)
            worker.start()
            self.assertTrue(ready.wait(15), "listener did not become ready")
            stalled = socket.create_connection(("127.0.0.1", port), timeout=5)
            stalled.sendall(b"POST /v1/enroll HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 50\r\n\r\n")
            started = time.monotonic()
            stalled.settimeout(5)
            try:
                stalled.recv(64)
            except OSError:
                pass
            self.assertLess(time.monotonic() - started, 4)
            stalled.close()
            worker.join(timeout=12)
            self.assertFalse(worker.is_alive())
            self.assertEqual(result.get("value"), "expired")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
