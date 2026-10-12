#!/usr/bin/env python3
"""The Watch's relay path end to end: HTTPS long-poll → real relay → real host → fake Grok Build."""

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

import fake_grok  # noqa: E402
import miniws  # noqa: E402
import outbound  # noqa: E402
import relaybox  # noqa: E402
from watch_poll import HttpWatch, reply_in  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
KEY = bytes([0x33]) * 32
TOKEN = "roomtokenwatchpath01"
SECRET = "fake-agent-secret-for-tests"


def free_port() -> int:
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def start_relay(port: int) -> subprocess.Popen:
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
    assert proc.stdout is not None
    deadline = time.time() + 10
    while time.time() < deadline:
        if '"listening"' in proc.stdout.readline():
            return proc
    proc.kill()
    raise RuntimeError("relay did not start")


def stop(proc: subprocess.Popen | None) -> None:
    if proc is None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
    if proc.stdout is not None:
        proc.stdout.close()


class WatchPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        folder = Path(self.dir.name)
        (folder / "agent-secret").write_text(SECRET, encoding="utf-8")
        self.fake = fake_grok.FakeGrok(SECRET, chunk_delay=0.02)
        self.agent_port = self.fake.listen(0)
        self.env = {"GROK_AGENT_SECRET_FILE": str(folder / "agent-secret"), "GROK_AGENT_PORT": str(self.agent_port)}
        self.saved_env = {key: os.environ.get(key) for key in self.env}
        os.environ.update(self.env)
        self.relay_port = free_port()
        self.relay = start_relay(self.relay_port)
        self.counters = folder / "outbound-counters.json"
        self.running = True
        config = {"relay": f"ws://127.0.0.1:{self.relay_port}/v1/room", "token": TOKEN, "key": KEY}

        self.slot = outbound.AgentSlot(self.counters)

        def serve() -> None:
            while self.running:
                try:
                    outbound.serve_connection(config, None, self.counters, self.slot)
                except (OSError, miniws.SocketError, relaybox.RelayBoxError, json.JSONDecodeError):
                    time.sleep(0.2)

        self.thread = threading.Thread(target=serve, daemon=True)
        self.thread.start()
        self.watch = HttpWatch(f"http://127.0.0.1:{self.relay_port}", TOKEN, KEY)
        deadline = time.time() + 10
        while time.time() < deadline:
            self.watch.poll()
            if self.watch.host_online:
                break
            time.sleep(0.1)
        self.assertTrue(self.watch.host_online, "host never joined the room")

    def tearDown(self) -> None:
        self.running = False
        stop(self.relay)
        self.thread.join(timeout=5)
        self.slot.close()
        self.fake.close()
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.dir.cleanup()

    def ask(self, op: str, **fields: object) -> dict:
        ident = self.watch.send(op, **fields)
        return self.watch.wait_for(lambda message: message.get("id") == ident)

    def started(self, ident: str) -> str:
        reply = self.watch.wait_for(lambda message: message.get("id") == ident)
        self.assertEqual(reply.get("op"), "started", reply)
        return str(reply["sessionID"])

    def test_new_chat_gets_a_reply(self) -> None:
        begun = time.time()
        session_id = self.started(self.watch.send("start", prompt="Can you hear me", autoApprove=True))
        update = self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I can hear you."), timeout=10)
        self.assertLess(time.time() - begun, 10)
        row = next(row for row in update["sessions"] if row["id"] == session_id)
        self.assertEqual(row["transcript"], ["You: Can you hear me", "Grok: I can hear you."])

    def test_reopened_chat_continues_in_the_same_session_without_duplicates(self) -> None:
        restored = self.ask("resume", sessionID="session-seed")
        self.assertEqual(restored["lines"], ["You: earlier", "Grok: Ready."])
        again = self.ask("resume", sessionID="session-seed")
        self.assertEqual(again["lines"], ["You: earlier", "Grok: Ready."])
        session_id = self.started(self.watch.send("start", prompt="Reopen the chat", sessionID="session-seed"))
        self.assertEqual(session_id, "session-seed")
        update = self.watch.wait_for(lambda message: reply_in(message, "session-seed", "Grok: Reopened."))
        row = next(row for row in update["sessions"] if row["id"] == "session-seed")
        self.assertEqual(row["transcript"], ["You: earlier", "Grok: Ready.", "You: Reopen the chat", "Grok: Reopened."])
        self.assertEqual(self.fake.state()["loads"], ["session-seed"])

    def test_tool_approval_waits_for_the_watch_when_auto_approve_is_off(self) -> None:
        self.watch.send("ping", autoApprove=False)
        session_id = self.started(self.watch.send("start", prompt="Read the notes file"))
        waiting = self.watch.wait_for(
            lambda message: message.get("op") == "update"
            and any(row.get("id") == session_id and row.get("permission") for row in message.get("sessions") or [])
        )
        row = next(row for row in waiting["sessions"] if row["id"] == session_id)
        self.assertEqual(row["status"], "needsApproval")
        ok = self.ask("approve", sessionID=session_id, permissionID=row["permission"]["id"])
        self.assertEqual(ok["op"], "ok")
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I read notes.txt. It says hello."))
        self.assertEqual(self.fake.state()["decisions"], [{"sessionId": session_id, "outcome": "allow-once"}])

    def test_auto_approve_lets_tools_run_without_the_watch(self) -> None:
        self.watch.send("ping", autoApprove=True)
        session_id = self.started(self.watch.send("start", prompt="Read the notes file"))
        update = self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I read notes.txt. It says hello."))
        row = next(row for row in update["sessions"] if row["id"] == session_id)
        self.assertIn("Auto-approved: Read notes.txt", row["transcript"])
        self.assertEqual(self.fake.state()["decisions"], [{"sessionId": session_id, "outcome": "allow-once"}])

    def test_per_chat_auto_approve_overrides_the_default(self) -> None:
        self.watch.send("ping", autoApprove=True)
        session_id = self.started(self.watch.send("start", prompt="Read the notes file", autoApprove=False))
        self.watch.wait_for(
            lambda message: message.get("op") == "update"
            and any(row.get("id") == session_id and row.get("permission") for row in message.get("sessions") or [])
        )
        self.watch.send("ping", sessionID=session_id, autoApprove=True)
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I read notes.txt. It says hello."))

    def test_relay_restart_recovers(self) -> None:
        stop(self.relay)
        self.relay = start_relay(self.relay_port)
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                self.watch.poll()
            except OSError:
                pass
            if self.watch.host_online:
                break
            time.sleep(0.2)
        self.assertTrue(self.watch.host_online)
        session_id = self.started(self.watch.send("start", prompt="Again"))
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: Heard again."))
        self.assertEqual(self.fake.state()["connections"], 1, "a relay restart must not reopen the agent")

    def test_a_send_right_after_a_relay_restart_is_answered(self) -> None:
        session_id = self.started(self.watch.send("start", prompt="Can you hear me"))
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I can hear you."))
        stop(self.relay)
        self.relay = start_relay(self.relay_port)
        self.watch.inbox.clear()
        self.watch.send("start", prompt="Again", sessionID=session_id)
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: Heard again."), timeout=15)

    def test_agent_restart_recovers(self) -> None:
        self.started(self.watch.send("start", prompt="Can you hear me"))
        self.fake.drop_clients()
        deadline = time.time() + 20
        while True:
            ident = self.watch.send("start", prompt="Again")
            reply = self.watch.wait_for(lambda message: message.get("id") == ident)
            if reply.get("op") == "started":
                break
            self.assertIn("not answering", reply.get("message", ""))
            self.assertLess(time.time(), deadline, "the host never reconnected to the agent")
            time.sleep(1)
        self.watch.wait_for(lambda message: reply_in(message, reply["sessionID"], "Grok: Heard again."))

    def test_a_watch_that_lost_its_counter_is_still_heard(self) -> None:
        self.started(self.watch.send("start", prompt="Can you hear me"))
        fresh = HttpWatch(f"http://127.0.0.1:{self.relay_port}", TOKEN, KEY)
        fresh.after = self.watch.after
        fresh.epoch = self.watch.epoch
        ident = fresh.send("list")
        listed = fresh.wait_for(lambda message: message.get("id") == ident)
        self.assertEqual(listed["op"], "sessions")

    def test_a_long_used_grok_does_not_knock_the_computer_off_the_relay(self) -> None:
        self.fake.reset(heavy=True)
        listed = self.ask("list")
        self.assertEqual(listed["op"], "sessions", listed)
        self.assertEqual(listed["sessions"][0]["id"], "session-seed")
        self.assertLessEqual(len(listed["sessions"]), outbound.WATCH_SESSIONS)
        restored = self.ask("resume", sessionID="session-seed")
        self.assertEqual(restored["op"], "restored", restored)
        self.assertEqual(restored["lines"][-2:], ["You: earlier", "Grok: Ready."])
        self.assertLessEqual(len(restored["lines"]), outbound.RESTORE_LINES)
        again = self.ask("list")
        self.assertEqual(again["op"], "sessions", again)
        session_id = self.started(self.watch.send("start", prompt="Reopen the chat", sessionID="session-seed"))
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: Reopened."))
        self.assertTrue(self.watch.host_online)

    def test_a_reply_that_lands_while_the_watch_sleeps_is_there_on_wake(self) -> None:
        self.fake.reset(heavy=True)
        self.fake.slow_seconds = 2.0
        self.ask("resume", sessionID="session-seed")
        session_id = self.started(self.watch.send("start", prompt="Take your time", sessionID="session-seed"))
        time.sleep(self.fake.slow_seconds + 3)
        self.watch.inbox.clear()
        self.assertEqual(self.ask("list")["op"], "sessions")
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: Thanks for waiting."), timeout=5)

    def test_a_host_that_reconnects_pushes_what_the_watch_missed(self) -> None:
        session_id = self.started(self.watch.send("start", prompt="Can you hear me"))
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I can hear you."))
        stop(self.relay)
        self.relay = start_relay(self.relay_port)
        self.watch.inbox.clear()
        self.watch.wait_for(lambda message: reply_in(message, session_id, "Grok: I can hear you."), timeout=15)


class HostUnitTests(unittest.TestCase):
    def test_updates_are_coalesced(self) -> None:
        agent = outbound.ACPAgent("secret")
        agent.rows = [{"id": "s", "title": "T", "summary": "", "status": "running", "lines": ["You: hi"]}]
        agent.pending_push = True
        self.assertIsNotNone(agent.take_update(now=100.0))
        agent.pending_push = True
        self.assertIsNone(agent.take_update(now=100.2))
        self.assertAlmostEqual(agent.push_due_in(now=100.2) or 0, 0.3, places=3)
        self.assertIsNotNone(agent.take_update(now=100.6))
        agent.pending_push = True
        agent.urgent = True
        self.assertIsNotNone(agent.take_update(now=100.61))

    def test_watch_rows_fit_in_one_relay_frame(self) -> None:
        rows = [
            {"id": f"s{index}", "title": "T", "summary": "", "status": "idle", "lines": [f"Grok: {'x' * 3000}"] * 200}
            for index in range(30)
        ]
        trimmed = outbound.watch_rows(rows, {"s0"})
        self.assertLessEqual(len(trimmed), outbound.WATCH_SESSIONS)
        self.assertLessEqual(len(json.dumps(trimmed)), outbound.WATCH_BUDGET)
        self.assertTrue(all("lines" not in row for row in trimmed))
        self.assertTrue(all(len(line) <= outbound.LINE_LIMIT for row in trimmed for line in row["transcript"]))

    def test_every_reply_fits_in_one_relay_frame(self) -> None:
        rows = [
            {"id": f"s{index}", "title": "T" * 400, "summary": "x" * 160, "status": "idle", "lines": ["Grok: " + "y" * 1500] * 300}
            for index in range(1500)
        ]
        for message in (
            {"op": "sessions", "id": "w1", "sessions": rows},
            {"op": "update", "sessions": rows},
            {"op": "restored", "id": "w2", "sessionID": "s0", "lines": rows[0]["lines"] * 4},
        ):
            fitted = outbound.fit_for_watch(message)
            self.assertEqual(fitted["op"], message["op"])
            self.assertLessEqual(len(relaybox.encode_message(fitted)), outbound.FRAME_BUDGET)
        small = {"op": "ok", "id": "w3"}
        self.assertIs(outbound.fit_for_watch(small), small)
        huge = {"op": "transcribed", "id": "w4", "text": "z" * (outbound.FRAME_BUDGET * 2)}
        self.assertEqual(outbound.fit_for_watch(huge), {"op": "error", "id": "w4", "message": outbound.TOO_LARGE})

    def test_a_reconnected_host_pushes_its_rows_at_once(self) -> None:
        agent = outbound.ACPAgent("secret")
        agent.request_push()
        self.assertIsNone(agent.take_update(now=100.0), "nothing to push before Grok listed any chat")
        agent.rows = [{"id": "s", "title": "T", "summary": "", "status": "idle", "lines": ["Grok: hi"]}]
        agent.last_push = 100.0
        agent.request_push()
        update = agent.take_update(now=100.01)
        self.assertIsNotNone(update)
        self.assertEqual(update["sessions"][0]["transcript"], ["Grok: hi"])

    def test_counters_follow_the_clock(self) -> None:
        self.assertEqual(outbound.next_counter(0, now_ms=1_700_000_000_000), 1_700_000_000_000)
        self.assertEqual(outbound.next_counter(1_700_000_000_005, now_ms=1_700_000_000_000), 1_700_000_000_006)

    def test_approval_policy_persists_default_and_chats(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "approvals.json"
            policy = outbound.ApprovalPolicy(path)
            self.assertFalse(policy.allows("a"))
            self.assertTrue(policy.note({"autoApprove": True}))
            self.assertTrue(policy.note({"autoApprove": False, "sessionID": "b"}))
            again = outbound.ApprovalPolicy(path)
            self.assertTrue(again.allows("a"))
            self.assertFalse(again.allows("b"))
            self.assertFalse(again.note({"op": "ping"}))

    def test_a_permission_request_does_not_crash_the_host(self) -> None:
        agent = outbound.ACPAgent("secret")
        agent.rows = [{"id": "s", "title": "T", "summary": "", "status": "running", "lines": []}]
        agent._ingest(json.dumps({
            "jsonrpc": "2.0",
            "id": 7,
            "method": "session/request_permission",
            "params": {
                "sessionId": "s",
                "toolCall": {"title": "Run tests"},
                "options": [{"optionId": "ok", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}],
            },
        }))
        self.assertEqual(agent.rows[0]["status"], "needsApproval")
        self.assertEqual(agent.rows[0]["permission"]["title"], "Run tests")
        self.assertIn("s:7", agent.permissions)


if __name__ == "__main__":
    unittest.main()
