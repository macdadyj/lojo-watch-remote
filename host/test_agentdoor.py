#!/usr/bin/env python3
"""The agent door accepts the secret as a header and refuses shell-style exec."""

from __future__ import annotations

import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agentdoor  # noqa: E402
import outbound  # noqa: E402


SECRET = "example-secret"


class AgentDoorTests(unittest.TestCase):
    def test_cwd_resolution_stays_on_the_computer(self) -> None:
        home = Path("/home/user")
        self.assertEqual(agentdoor.resolve_cwd("", home), "/home/user")
        self.assertEqual(agentdoor.resolve_cwd("~", home), "/home/user")
        self.assertEqual(agentdoor.resolve_cwd("~/src", home), "/home/user/src")
        self.assertEqual(agentdoor.resolve_cwd("/work", home), "/work")
        argv = agentdoor.headless_argv("grok", "it's $(rm -rf /)", "/work", "abc")
        self.assertEqual(argv[0], "grok")
        self.assertEqual(argv[2], "it's $(rm -rf /)")
        self.assertIn("--permission-mode", argv)
        self.assertIn("dontAsk", argv)
        self.assertNotIn("GROK_AGENT_SECRET", argv)
        self.assertNotIn("--secret", argv)
        self.assertNotIn("bash", argv)
        os.environ["GROK_AGENT_SECRET"] = SECRET
        try:
            self.assertNotIn("GROK_AGENT_SECRET", agentdoor.child_env())
        finally:
            os.environ.pop("GROK_AGENT_SECRET", None)

    def test_secret_is_a_header_and_exec_is_not_a_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            binary = folder / "grok"
            argv_file = folder / "argv.json"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                f"open({str(argv_file)!r}, 'w').write(json.dumps({{'argv': sys.argv, 'secret': os.environ.get('GROK_AGENT_SECRET')}}))\n"
                "print(json.dumps({'type': 'text', 'data': 'Hello'}), flush=True)\n"
                "print(json.dumps({'type': 'end', 'stopReason': 'end_turn', 'usage': {'input_tokens': 3, 'output_tokens': 4}}), flush=True)\n",
                encoding="utf-8",
            )
            binary.chmod(binary.stat().st_mode | stat.S_IEXEC)
            upstream_port, upstream_listener = self._upstream()
            port = self._port()
            stop = threading.Event()
            ready = threading.Event()
            os.environ["GROK_AGENT_SECRET"] = SECRET
            worker = threading.Thread(
                target=agentdoor.serve,
                args=(SECRET, "127.0.0.1", port, ("127.0.0.1", upstream_port), ready, stop, str(binary)),
                daemon=True,
            )
            worker.start()
            self.assertTrue(ready.wait(5))
            agent: outbound.ACPAgent | None = None
            try:
                self._assert_query_refused(port)
                self._assert_malformed_bearer_refused(port)
                agent = outbound.ACPAgent(SECRET, "127.0.0.1", port)
                agent.open()
                started = agent.start("it's $(rm -rf /)", "/work")
                self.assertTrue(started)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not argv_file.exists():
                    time.sleep(0.05)
                recorded = json.loads(argv_file.read_text(encoding="utf-8"))
                self.assertEqual(recorded["argv"][2], "it's $(rm -rf /)")
                self.assertIsNone(recorded["secret"])
                self.assertNotIn("server-key", json.dumps(recorded))
                self.assertIn(b"Authorization: Bearer example-secret", self.upstream_request)
                self.assertNotIn(b"server-key", self.upstream_request)
                self.assertTrue(self.upstream_request.startswith(b"GET /ws HTTP/1.1"))
            finally:
                if agent is not None and agent.conn is not None:
                    agent.conn.close()
                stop.set()
                worker.join(timeout=3)
                upstream_listener.close()
                os.environ.pop("GROK_AGENT_SECRET", None)

    def _assert_query_refused(self, port: int) -> None:
        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        sock.sendall(
            f"GET /ws?server-key={SECRET} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode()
        )
        data = sock.recv(256)
        sock.close()
        self.assertIn(b"401", data)
        self.assertNotIn(SECRET.encode(), data)

    def _assert_malformed_bearer_refused(self, port: int) -> None:
        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        sock.sendall(
            f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer caf\u00e9\r\n\r\n".encode("latin-1")
        )
        data = sock.recv(256)
        sock.close()
        self.assertIn(b"401", data)

    def _upstream(self) -> tuple[int, socket.socket]:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.listen(1)
        listener.settimeout(8)
        self.upstream_request = b""

        def run() -> None:
            try:
                conn, _ = listener.accept()
            except TimeoutError:
                return
            with conn:
                data = b""
                while b"\r\n\r\n" not in data and len(data) < 8192:
                    chunk = conn.recv(1024)
                    if not chunk:
                        break
                    data += chunk
                self.upstream_request = data
                conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

        threading.Thread(target=run, daemon=True).start()
        return port, listener

    def _port(self) -> int:
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        return port


if __name__ == "__main__":
    unittest.main()
