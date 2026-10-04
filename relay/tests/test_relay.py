import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from watchremote_relay.adapters.acp import client_frame, pop_server_frame
from watchremote_relay.adapters.cli import CLIAdapter
from watchremote_relay.adapters.mock import MockAdapter
from watchremote_relay.server import TokenStore, bind_address, build_adapter, configured_bind, main, make_handler


class RelayTests(unittest.TestCase):
    def test_bind_refuses_public_addresses(self):
        self.assertEqual(bind_address("100.64.0.2"), "100.64.0.2")
        self.assertEqual(bind_address("100.127.255.254"), "100.127.255.254")
        self.assertEqual(bind_address("127.0.0.1"), "127.0.0.1")
        for host in ("", "0.0.0.0", "8.8.8.8", "10.1.1.1", "192.168.1.1", "100.63.255.255", "100.128.0.1", "100.064.0.1", "0100.64.0.1", "example-host"):
            with self.assertRaises(SystemExit):
                bind_address(host)
        previous = os.environ.pop("WATCHREMOTE_RELAY_BIND", None)
        try:
            with self.assertRaises(SystemExit):
                configured_bind()
        finally:
            if previous is not None:
                os.environ["WATCHREMOTE_RELAY_BIND"] = previous

    def test_cli_command_has_no_secret_flag(self):
        path = os.path.join(os.path.dirname(__file__), "..", "watchremote_relay", "adapters", "cli.py")
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        self.assertNotIn("--secret", source)
        self.assertNotIn("always-approve", source)
        self.assertNotIn("--yolo", source)
        self.assertIn("dontAsk", source)
        self.assertIn("streaming-json", source)

    def test_websocket_frame_roundtrip(self):
        frame = client_frame(b'{"ok":true}')
        self.assertEqual(frame[0], 0x81)
        self.assertEqual(frame[1] & 0x80, 0x80)
        length = frame[1] & 0x7F
        mask = frame[2:6]
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(frame[6:6 + length]))
        text, rest = pop_server_frame(bytes([0x81, len(payload)]) + payload)
        self.assertEqual(text, '{"ok":true}')
        self.assertEqual(rest, b"")

    def test_mock_http_flow(self):
        adapter = MockAdapter()
        tokens = TokenStore(self._state_path())
        admin = "admin-test-token"
        handler = make_handler(adapter, tokens, admin)
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        base = f"http://127.0.0.1:{port}"
        try:
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(base + "/v1/sessions")
            self.assertEqual(raised.exception.code, 401)
            pair = urllib.request.Request(
                base + "/v1/pair",
                method="POST",
                headers={"Authorization": f"Bearer {admin}"},
            )
            with urllib.request.urlopen(pair) as response:
                token = json.load(response)["token"]
            self.assertTrue(token)
            start = urllib.request.Request(
                base + "/v1/sessions",
                data=json.dumps({"prompt": "Fix the parser", "cwd": "/work"}).encode(),
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(start) as response:
                session = json.load(response)
            self.assertEqual(session["status"], "needsApproval")
            permission = session["permission"]["id"]
            decide = urllib.request.Request(
                base + "/v1/permissions/" + permission,
                data=json.dumps({"allow": False}).encode(),
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                method="POST",
            )
            urllib.request.urlopen(decide).close()
            listed = urllib.request.Request(base + "/v1/sessions", headers={"Authorization": f"Bearer {token}"})
            with urllib.request.urlopen(listed) as response:
                body = json.load(response)
            self.assertEqual(body["sessions"][0]["status"], "stopped")
        finally:
            server.shutdown()
            server.server_close()

    def _state_path(self):
        directory = tempfile.mkdtemp()
        return Path(directory) / "tokens.json"


if __name__ == "__main__":
    unittest.main()
