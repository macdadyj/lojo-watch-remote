#!/usr/bin/env python3
"""Local stack for the Watch transport UI test: real relay, real outbound host, fake Grok Build.

The Watch simulator long-polls 127.0.0.1 exactly as a real Watch long-polls the deployed relay.
Behind the relay, `outbound.py` runs unmodified and talks ACP to `fake_grok.py`, which answers
with canned sentences and asks for permission before it "reads a file".

A second port takes test controls:
  /reset   fresh Grok sessions, fresh approvals, fresh counters, relay restarted
  /drop    stop the relay process (the host and Grok keep running)
  /resume  start the relay again
  /state   JSON of what Grok saw: sessions, prompts with their session ids, permission decisions
Nothing here is the production relay or a real model.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fake_grok  # noqa: E402
import miniws  # noqa: E402
import outbound  # noqa: E402
import relaybox  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
TOKEN = "roomtokenprobe0001"
KEY = bytes([0x22]) * 32
SECRET = "fake-agent-secret-for-the-watch-probe"
DEFAULT_PORT = 18765
DEFAULT_CONTROL = 18766

STATE: dict = {"node": None, "port": DEFAULT_PORT, "counters": None, "wipe": False, "fake": None, "slot": None}
LOCK = threading.Lock()


def pairing_key() -> str:
    return base64.urlsafe_b64encode(KEY).decode("ascii").rstrip("=")


def write_meta(path: Path, port: int, counters: Path, control: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = {
        "relayURL": f"ws://127.0.0.1:{port}/v1/room",
        "token": TOKEN,
        "key": pairing_key(),
        "counters": str(counters),
        "port": port,
        "control": control,
        "pid": os.getpid(),
    }
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(body), encoding="utf-8")
    os.replace(temporary, path)


def start_relay(port: int) -> subprocess.Popen:
    env = os.environ.copy()
    env["WATCHREMOTE_OUTBOUND_BIND"] = "127.0.0.1"
    env["WATCHREMOTE_OUTBOUND_PORT"] = str(port)
    print(f"relay-spawning port={port}", flush=True)
    proc = subprocess.Popen(
        ["node", "relay/outbound/server.mjs"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert proc.stdout is not None
    seen: list[str] = []
    deadline = time.time() + 20
    while time.time() < deadline:
        line = proc.stdout.readline()
        if line == "" and proc.poll() is not None:
            detail = "".join(seen)[-400:]
            raise SystemExit(f"relay exited early: {detail}")
        if not line:
            continue
        seen.append(line)
        print(line, end="", flush=True)
        compact = line.replace(" ", "")
        if '"listening"' in line and (f'"port":{port}' in compact or port == 0):
            threading.Thread(target=drain, args=(proc,), daemon=True).start()
            return proc
    proc.terminate()
    detail = "".join(seen)[-400:]
    raise SystemExit(f"relay did not start: {detail}")


def drain(proc: subprocess.Popen) -> None:
    """Keeps the relay's log pipe empty so a chatty relay cannot block on a full pipe."""
    assert proc.stdout is not None
    for line in proc.stdout:
        print(line, end="", flush=True)


def stop_node() -> None:
    proc = STATE.get("node")
    if proc is None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
    STATE["node"] = None


def drop_node() -> None:
    with LOCK:
        stop_node()


def resume_node() -> None:
    with LOCK:
        proc = STATE.get("node")
        if proc is not None and proc.poll() is None:
            return
        STATE["node"] = start_relay(int(STATE["port"]))


def reset_all() -> None:
    with LOCK:
        stop_node()
        STATE["fake"].reset()
        slot = STATE["slot"]
        slot.close()
        slot.agent = None
        slot.next_open = 0.0
        if slot.approvals is not None:
            slot.approvals.default = False
            slot.approvals.chats.clear()
            if slot.approvals.path is not None and slot.approvals.path.exists():
                slot.approvals.path.unlink()
        STATE["wipe"] = True
        STATE["node"] = start_relay(int(STATE["port"]))


class ControlHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._json({"ok": True})
        elif path == "/reset":
            reset_all()
            self._json({"ok": True})
        elif path == "/drop":
            drop_node()
            self._json({"ok": True})
        elif path == "/resume":
            resume_node()
            self._json({"ok": True})
        elif path == "/state":
            self._json({"ok": True, **STATE["fake"].state()})
        else:
            self.send_response(404)
            self.end_headers()

    def _json(self, body: dict) -> None:
        data = (json.dumps(body) + "\n").encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def serve(counters: Path) -> None:
    config = {
        "relay": f"ws://127.0.0.1:{STATE['port']}/v1/room",
        "token": TOKEN,
        "key": KEY,
    }
    while True:
        with LOCK:
            if STATE.get("wipe"):
                STATE["wipe"] = False
                if counters.exists():
                    counters.unlink()
        try:
            outbound.serve_connection(config, None, counters, STATE["slot"])
        except (OSError, miniws.SocketError, relaybox.RelayBoxError, json.JSONDecodeError):
            time.sleep(0.2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pairing-file", required=True)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--control-port", type=int, default=DEFAULT_CONTROL)
    parser.add_argument("--counters", default="")
    args = parser.parse_args()
    pairing = Path(args.pairing_file)
    counters = Path(args.counters) if args.counters else pairing.with_suffix(".counters.json")
    STATE["port"] = args.port
    STATE["counters"] = counters
    if counters.exists():
        counters.unlink()

    secrets = tempfile.TemporaryDirectory()
    secret_file = Path(secrets.name) / "agent-secret"
    secret_file.write_text(SECRET, encoding="utf-8")
    fake = fake_grok.FakeGrok(SECRET, chunk_delay=0.05)
    agent_port = fake.listen(0)
    os.environ["GROK_AGENT_SECRET_FILE"] = str(secret_file)
    os.environ["GROK_AGENT_PORT"] = str(agent_port)
    STATE["fake"] = fake
    STATE["slot"] = outbound.AgentSlot(counters)
    print(f"fake-grok port={agent_port}", flush=True)

    print("probe-starting", flush=True)
    try:
        control = ThreadingHTTPServer(("127.0.0.1", args.control_port), ControlHandler)
    except OSError as error:
        print(f"probe control bind failed: {error}", flush=True)
        return 1
    threading.Thread(target=control.serve_forever, daemon=True).start()
    STATE["node"] = start_relay(args.port)
    write_meta(pairing, args.port, counters, args.control_port)

    def stop(signum, frame) -> None:
        del signum, frame
        stop_node()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"probe-ready port={args.port}", flush=True)
    try:
        serve(counters)
    finally:
        stop_node()
        control.shutdown()
        STATE["slot"].close()
        fake.close()
        secrets.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
