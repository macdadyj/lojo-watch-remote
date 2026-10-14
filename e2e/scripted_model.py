#!/usr/bin/env python3
"""OpenAI-compatible chat endpoint with a fixed script, for running the real Grok Build agent offline.

Grok Build (`grok agent serve`) owns everything the phone and the Watch see: sessions, the ACP
stream, tool calls, permission requests, session/load replay, and the session list. Only the model's
words come from here. That keeps CI and the VM on the real agent protocol without an xAI account.

Each user prompt gets a preamble, ``SCRIPTED_TOOL_ROUNDS`` real ``run_terminal_command`` calls, and a
final answer that quotes the prompt, so a client can tell which turn a reply belongs to.
``SCRIPTED_SLOW_ROUND`` makes one round sleep ``SCRIPTED_SLOW_SECONDS`` with no output, longer than
any idle timer on the path.
"""

from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FINAL_MARK = "Final answer for:"


def tool_rounds() -> int:
    return max(0, int(os.environ.get("SCRIPTED_TOOL_ROUNDS", "3")))


def slow_round() -> int:
    return int(os.environ.get("SCRIPTED_SLOW_ROUND", "-1"))


def slow_seconds() -> int:
    return max(0, int(os.environ.get("SCRIPTED_SLOW_SECONDS", "35")))


def user_query(messages: list) -> str:
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        text = content if isinstance(content, str) else " ".join(
            str(part.get("text") or "") for part in content or [] if isinstance(part, dict)
        )
        if "<user_query>" in text:
            return text.split("<user_query>", 1)[1].split("</user_query>", 1)[0].strip()
    return ""


def rounds_since_query(messages: list) -> int:
    count = 0
    for message in reversed(messages):
        role = message.get("role")
        if role == "user" and "<user_query>" in json.dumps(message.get("content")):
            break
        if role == "assistant" and message.get("tool_calls"):
            count += 1
    return count


def plan(body: dict) -> dict:
    messages = body.get("messages") or []
    choice = body.get("tool_choice")
    if isinstance(choice, dict) and (choice.get("function") or {}).get("name") == "session_title":
        query = user_query(messages) or "Chat"
        title = " ".join(query.replace("?", "").split()[:7])
        return {"tool": ("session_title", {"session_title": title}), "text": []}
    query = user_query(messages)
    done = rounds_since_query(messages)
    total = tool_rounds()
    if done < total:
        text = [f"I'll check that for you: {query}. ", "Pulling a few readings first."] if done == 0 else []
        pause = slow_seconds() if done == slow_round() else 1
        label = "".join(char for char in query[:60] if char.isalnum() or char == " ").strip()
        # Writing a file keeps this out of Grok's read-only allowlist, so each round asks for permission.
        command = f"sleep {pause}; echo 'reading {done + 1} of {total} for {label}' | tee -a /tmp/watchremote-e2e-readings.txt"
        return {"text": text, "tool": ("run_terminal_command", {"command": command, "description": f"Reading {done + 1}"})}
    return {"text": [f"{FINAL_MARK} {query}. ", "Today it is 74°F and sunny ", "with a light south wind."], "tool": None}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: object) -> None:
        return

    def do_GET(self) -> None:
        body = json.dumps({"object": "list", "data": [{"id": "scripted", "object": "model", "created": 0, "owned_by": "e2e"}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        script = plan(body)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        model = str(body.get("model") or "scripted")
        first = True
        for piece in script["text"]:
            delta: dict = {"content": piece}
            if first:
                delta["role"] = "assistant"
                first = False
            self._chunk(model, delta, None)
            time.sleep(0.05)
        if script["tool"] is not None:
            name, arguments = script["tool"]
            call = {"index": 0, "id": f"call_{int(time.time() * 1000)}", "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)}}
            delta = {"tool_calls": [call]}
            if first:
                delta["role"] = "assistant"
            self._chunk(model, delta, None)
            self._chunk(model, {}, "tool_calls")
        else:
            self._chunk(model, {}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def _chunk(self, model: str, delta: dict, finish: str | None) -> None:
        payload = {
            "id": "chatcmpl-scripted",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
        if finish is not None:
            payload["usage"] = {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}
        self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
        self.wfile.flush()


def main(argv: list[str]) -> int:
    port = int(argv[1]) if len(argv) > 1 else 18080
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
