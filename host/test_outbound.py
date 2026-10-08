#!/usr/bin/env python3
"""Direct-mode command handling and a live room against the local relay."""

from __future__ import annotations

import base64
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
    def test_session_rows_unwrap_grok_extension_result(self) -> None:
        rows = outbound.sessions_from({
            "result": {
                "sessions": [{
                    "sessionId": "abc",
                    "title": "Logs",
                    "summary": "Reading",
                    "status": "running",
                }],
            },
        })
        self.assertEqual(rows, [{
            "id": "abc",
            "title": "Logs",
            "summary": "Reading",
            "status": "running",
        }])
        flat = outbound.sessions_from({
            "sessions": [{"sessionId": "def", "title": "Door", "status": "idle"}],
        })
        self.assertEqual(flat[0]["id"], "def")

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

    def test_resume_returns_lines_and_unknown_session_errors(self) -> None:
        agent = outbound.MemoryAgent()
        agent.rows = [{
            "id": "s1",
            "title": "Note the overlay route",
            "summary": "Private overlay.",
            "status": "idle",
            "lines": ["You: note it", "Grok: noted"],
        }]
        restored = outbound.handle(agent, {"op": "resume", "id": "8", "sessionID": "s1"})
        self.assertEqual(restored["op"], "restored")
        self.assertEqual(restored["sessionID"], "s1")
        self.assertEqual(restored["lines"], ["You: note it", "Grok: noted"])
        missing = outbound.handle(agent, {"op": "resume", "id": "9", "sessionID": "gone"})
        self.assertEqual(missing["op"], "error")
        self.assertIn("no longer", missing["message"])
        continued = outbound.handle(agent, {
            "op": "start",
            "id": "10",
            "prompt": "add a line",
            "sessionID": "s1",
        })
        self.assertEqual(continued["op"], "started")
        self.assertEqual(continued["sessionID"], "s1")
        self.assertEqual(agent.rows[0]["status"], "running")
        self.assertEqual(len(agent.started), 1)
        lines = outbound.transcript_lines({
            "messages": [
                {"role": "user", "content": "note the route"},
                {"role": "assistant", "content": [{"type": "text", "text": "noted"}]},
            ],
        })
        self.assertEqual(lines, ["You: note the route", "Grok: noted"])
        self.assertEqual(
            outbound.best_transcript(["Grok Build Mode"], ["You: note it", "Grok: noted"]),
            ["You: note it", "Grok: noted"],
        )
        self.assertEqual(outbound.best_transcript(["Just the title"]), [])

    def test_transcribe_returns_text_and_empty_audio_errors(self) -> None:
        agent = outbound.MemoryAgent()
        heard = outbound.handle(agent, {"op": "transcribe", "id": "u1", "audio": "aGVsbG8="})
        self.assertEqual(heard["op"], "transcript")
        self.assertEqual(heard["id"], "u1")
        self.assertEqual(heard["message"], "list sessions")
        empty = outbound.handle(agent, {"op": "transcribe", "id": "u2", "audio": "  "})
        self.assertEqual(empty["op"], "error")
        self.assertIn("Nothing was recorded", empty["message"])
        missing = outbound.handle(agent, {"op": "transcribe", "id": "u3"})
        self.assertEqual(missing["op"], "error")
        self.assertIn("Nothing was recorded", missing["message"])
        down = outbound.handle(outbound.AgentDown(), {"op": "transcribe", "id": "u4", "audio": "aGVsbG8="})
        self.assertEqual(down["op"], "error")
        self.assertIn("not answering", down["message"])

        pcm = b"\x00\x00" * 8
        audio = base64.b64encode(pcm).decode("ascii")
        seen: dict[str, bytes] = {}

        def run(argv, **kwargs):
            self.assertFalse(kwargs.get("shell"))
            self.assertEqual(argv[0], "/usr/bin/fake-stt")
            self.assertEqual(len(argv), 2)
            data = Path(argv[1]).read_bytes()
            self.assertTrue(data.startswith(b"RIFF"))
            seen["wav"] = data
            return subprocess.CompletedProcess(argv, 0, stdout="yes\n", stderr="")

        text = outbound.transcribe_audio(
            audio,
            environ={"WATCHREMOTE_STT_COMMAND": "/usr/bin/fake-stt"},
            which=lambda _name: None,
            run=run,
        )
        self.assertEqual(text, "yes")
        self.assertGreater(len(seen["wav"]), 44)

        def run_whisper(argv, **kwargs):
            self.assertFalse(kwargs.get("shell"))
            self.assertEqual(argv[0], "/usr/bin/whisper")
            self.assertEqual(argv[argv.index("--model") + 1], "tiny")
            self.assertEqual(argv[argv.index("--output_format") + 1], "txt")
            out = Path(argv[argv.index("--output_dir") + 1]) / "utterance.txt"
            out.write_text("list sessions\n", encoding="utf-8")
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        whispered = outbound.transcribe_audio(
            audio,
            environ={},
            which=lambda _name: "/usr/bin/whisper",
            run=run_whisper,
        )
        self.assertEqual(whispered, "list sessions")

        with self.assertRaises(RuntimeError) as missing_tool:
            outbound.transcribe_audio(audio, environ={}, which=lambda _name: None, run=run)
        self.assertIn("No transcriber is configured on this computer.", str(missing_tool.exception))
        with self.assertRaises(RuntimeError) as blank:
            outbound.transcribe_audio("  ", environ={"WATCHREMOTE_STT_COMMAND": "/usr/bin/fake-stt"}, run=run)
        self.assertIn("Nothing was recorded", str(blank.exception))

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
