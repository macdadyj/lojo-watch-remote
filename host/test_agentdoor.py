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
    def test_bare_list_method_is_rewritten_before_grok_sees_it(self) -> None:
        raw = json.dumps({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "x.ai/session/list",
            "params": {},
        }).encode()
        rewritten = agentdoor._rewrite_outbound(1, raw)
        self.assertIsNotNone(rewritten)
        obj = json.loads(rewritten or b"{}")
        self.assertEqual(obj["method"], "_x.ai/session/list")
        self.assertEqual(obj["id"], 2)
        already = json.dumps({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "_x.ai/session/list",
            "params": {},
        }).encode()
        self.assertIsNone(agentdoor._rewrite_outbound(1, already))
        cwd = json.dumps({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "session/new",
            "params": {"cwd": "~/src", "mcpServers": []},
        }).encode()
        resolved = json.loads(agentdoor._rewrite_outbound(1, cwd) or b"{}")
        self.assertEqual(resolved["params"]["cwd"], agentdoor.resolve_cwd("~/src"))
        self.assertEqual(resolved["method"], "session/new")

    def test_headless_door_answers_both_list_spellings(self) -> None:
        for method in ("x.ai/session/list", "_x.ai/session/list"):
            left, right = socket.socketpair()
            left.settimeout(2)
            try:
                agentdoor._handle(right, "grok", {}, {}, {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": method,
                    "params": {},
                })
                frame = left.recv(4096)
            finally:
                left.close()
                right.close()
            parsed = agentdoor._parse(frame)
            self.assertIsNotNone(parsed, method)
            assert parsed is not None
            opcode, payload, _size = parsed
            self.assertEqual(opcode, 1)
            body = json.loads(payload)
            self.assertEqual(body["id"], 4)
            self.assertEqual(body["result"]["sessions"], [])
            self.assertNotIn("Method not found", payload.decode())

    def test_headless_load_rejects_an_unknown_session(self) -> None:
        left, right = socket.socketpair()
        left.settimeout(2)
        sessions: dict = {}

        def body() -> dict:
            parsed = agentdoor._parse(left.recv(4096))
            self.assertIsNotNone(parsed)
            assert parsed is not None
            return json.loads(parsed[1])

        try:
            agentdoor._handle(right, "grok", sessions, {}, {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "session/new",
                "params": {"cwd": "/work", "mcpServers": []},
            })
            session_id = body()["result"]["sessionId"]
            agentdoor._handle(right, "grok", sessions, {}, {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "session/load",
                "params": {"sessionId": session_id, "cwd": "/work", "mcpServers": []},
            })
            self.assertEqual(body()["result"]["sessionId"], session_id)
            agentdoor._handle(right, "grok", sessions, {}, {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "session/load",
                "params": {"sessionId": "missing", "cwd": "/work", "mcpServers": []},
            })
            rejected = body()
        finally:
            left.close()
            right.close()
        self.assertIn("no longer", rejected["error"]["message"])
        self.assertNotIn("missing", sessions)

    def test_headless_load_replays_stored_lines_before_the_result(self) -> None:
        left, right = socket.socketpair()
        left.settimeout(2)
        sessions: dict = {}

        buffer = b""

        def take(count: int) -> list[dict]:
            nonlocal buffer
            found: list[dict] = []
            while len(found) < count:
                chunk = left.recv(4096)
                self.assertTrue(chunk)
                buffer += chunk
                while True:
                    parsed = agentdoor._parse(buffer)
                    if parsed is None:
                        break
                    _opcode, payload, size = parsed
                    buffer = buffer[size:]
                    found.append(json.loads(payload))
            return found

        try:
            agentdoor._handle(right, "grok", sessions, {}, {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "session/new",
                "params": {"cwd": "/work", "mcpServers": []},
            })
            created = take(1)
            session_id = created[0]["result"]["sessionId"]
            sessions[session_id].lines = ["You: note the route", "Grok: noted"]
            agentdoor._handle(right, "grok", sessions, {}, {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "session/load",
                "params": {"sessionId": session_id, "cwd": "/work", "mcpServers": []},
            })
            loaded = take(3)
        finally:
            left.close()
            right.close()
        self.assertEqual(loaded[0]["method"], "session/update")
        self.assertEqual(loaded[0]["params"]["update"]["sessionUpdate"], "user_message_chunk")
        self.assertEqual(loaded[0]["params"]["update"]["content"]["text"], "note the route")
        self.assertEqual(loaded[1]["method"], "session/update")
        self.assertEqual(loaded[1]["params"]["update"]["content"]["text"], "noted")
        self.assertEqual(loaded[2]["result"]["sessionId"], session_id)

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
