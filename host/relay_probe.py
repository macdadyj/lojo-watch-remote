#!/usr/bin/env python3
"""Local relay plus an in-memory host for the Watch transport test.

The Watch simulator dials 127.0.0.1. A second port accepts /reset and /bounce
so the test can drop the relay without killing the in-memory host.
Nothing here is the production relay.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import miniws  # noqa: E402
import outbound  # noqa: E402
import relaybox  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
TOKEN = "roomtokenprobe0001"
KEY = bytes([0x22]) * 32
DEFAULT_PORT = 18765
DEFAULT_CONTROL = 18766
SEED = {
    "id": "session-seed",
    "title": "Greeting and Current Weather Inquiry",
    "summary": "Ready.",
    "status": "idle",
    "lines": ["You: earlier", "Grok: Ready."],
}

STATE: dict = {"agent": None, "node": None, "port": DEFAULT_PORT, "counters": None, "wipe": False}
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
    proc = subprocess.Popen(
        ["node", "relay/outbound/server.mjs"],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    assert proc.stdout is not None
    deadline = time.time() + 8
    while time.time() < deadline:
        line = proc.stdout.readline()
        if '"listening"' in line and f'"port":{port}' in line.replace(" ", ""):
            return proc
        if '"listening"' in line and port == 0:
            return proc
    proc.terminate()
    raise SystemExit("relay did not start")


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


def reset_host() -> None:
    with LOCK:
        agent = STATE.get("agent")
        if agent is not None:
            agent.rows = [dict(SEED)]
            agent._queued.clear()
            agent.started.clear()
            agent._push_n = 0
        STATE["wipe"] = True
        stop_node()
        STATE["node"] = start_relay(int(STATE["port"]))


class ControlHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._ok()
            return
        if path == "/reset":
            reset_host()
            self._ok()
            return
        if path == "/drop":
            drop_node()
            self._ok()
            return
        if path == "/resume":
            resume_node()
            self._ok()
            return
        self.send_response(404)
        self.end_headers()

    def _ok(self) -> None:
        body = b'{"ok":true}\n'
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def serve(counters: Path) -> None:
    config = {
        "relay": f"ws://127.0.0.1:{STATE['port']}/v1/room",
        "token": TOKEN,
        "key": KEY,
    }
    agent = STATE["agent"]
    while True:
        if STATE.get("wipe"):
            STATE["wipe"] = False
            if counters.exists():
                counters.unlink()
        try:
            outbound.serve_connection(config, agent, counters)
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
    STATE["agent"] = outbound.MemoryAgent(rows=[dict(SEED)])
    if counters.exists():
        counters.unlink()
    control = ThreadingHTTPServer(("127.0.0.1", args.control_port), ControlHandler)
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
