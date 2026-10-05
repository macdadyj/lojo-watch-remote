#!/usr/bin/env python3
"""Direct-mode command handling and a live room against the local relay."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import miniws  # noqa: E402
import outbound  # noqa: E402
import relaybox  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
KEY = bytes([0x11]) * 32
TOKEN = "roomtokenvalue0001"


class HandleTests(unittest.TestCase):
    def test_list_start_approve_stop_and_ping(self) -> None:
        agent = outbound.MemoryAgent()
        agent.rows = [{
            "id": "s1",
            "title": "Update the parser",
            "summary": "Wants to edit a file.",
            "status": "needsApproval",
            "permission": {
                "id": "s1:7",
                "sessionID": "s1",
                "rpcID": "7",
                "rpcIDIsNumber": True,
                "title": "Edit a file",
                "detail": "parser",
                "allowOptionID": "allow-once",
                "denyOptionID": "reject-once",
            },
        }]
        listed = outbound.handle(agent, {"op": "list", "id": "1"})
        self.assertEqual(listed["op"], "sessions")
        self.assertEqual(listed["sessions"][0]["status"], "needsApproval")
        self.assertTrue(listed["approvalsAvailable"])
        started = outbound.handle(agent, {"op": "start", "id": "2", "prompt": "Read the build logs", "cwd": "/work"})
        self.assertEqual(started["op"], "started")
        self.assertEqual(agent.started, ["Read the build logs"])
        approved = outbound.handle(agent, {"op": "approve", "id": "3", "sessionID": "s1", "permissionID": "s1:7"})
        self.assertEqual(approved["op"], "ok")
        self.assertEqual(agent.decisions, [("s1", "s1:7", True)])
        denied = outbound.handle(outbound.MemoryAgent(), {"op": "deny", "id": "4", "sessionID": "s1", "permissionID": "s1:7"})
        self.assertEqual(denied["op"], "ok")
        stopped = outbound.handle(agent, {"op": "stop", "id": "5", "sessionID": started["sessionID"]})
        self.assertEqual(stopped["op"], "ok")
        self.assertEqual(agent.rows[0]["status"], "stopped")
        self.assertEqual(outbound.handle(agent, {"op": "ping", "id": "6"})["op"], "pong")
        down = outbound.handle(outbound.AgentDown(), {"op": "list", "id": "7"})
        self.assertIn("not answering", down["message"])

    def test_live_room_round_trip(self) -> None:
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        env = os.environ.copy()
        env["WATCHREMOTE_OUTBOUND_BIND"] = "127.0.0.1"
        env["WATCHREMOTE_OUTBOUND_PORT"] = str(port)
        proc = subprocess.Popen(
            ["node", "relay/outbound/server.mjs"],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            assert proc.stdout is not None
            deadline = time.time() + 5
            while time.time() < deadline:
                line = proc.stdout.readline()
                if '"listening"' in line:
                    break
            else:
                self.fail("relay did not start")
            with tempfile.TemporaryDirectory() as directory:
                counters = Path(directory) / "outbound-counters.json"
                agent = outbound.MemoryAgent()
                config = {
                    "relay": f"ws://127.0.0.1:{port}/v1/room",
                    "token": TOKEN,
                    "key": KEY,
                }
                def serve() -> None:
                    try:
                        outbound.serve_connection(config, agent, counters)
                    except (OSError, miniws.SocketError, relaybox.RelayBoxError):
                        return

                thread = threading.Thread(target=serve, daemon=True)
                thread.start()
                watch = miniws.connect(f"ws://127.0.0.1:{port}/v1/room", timeout=3)
                watch.send_text(json.dumps({"role": "watch", "token": TOKEN}))
                opcode, payload = watch.recv()
                self.assertEqual(opcode, 1)
                self.assertIn(b'"ok":true', payload)
                plain = relaybox.encode_message({"id": "9", "op": "start", "prompt": "Read the build logs"})
                watch.send_binary(relaybox.seal(plain, KEY, relaybox.WATCH_TO_HOST, 1))
                opcode, payload = watch.recv()
                self.assertEqual(opcode, 2)
                opened = relaybox.open_frame(payload, KEY, relaybox.HOST_TO_WATCH, relaybox.ReplayWindow())
                reply = json.loads(opened)
                self.assertEqual(reply["op"], "started")
                self.assertEqual(agent.started, ["Read the build logs"])
                watch.send_binary(relaybox.seal(plain, KEY, relaybox.WATCH_TO_HOST, 1))
                time.sleep(0.3)
                self.assertEqual(agent.started, ["Read the build logs"])
                watch.close()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            if proc.stdout is not None:
                proc.stdout.close()


if __name__ == "__main__":
    unittest.main()
