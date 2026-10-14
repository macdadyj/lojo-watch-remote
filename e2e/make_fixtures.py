#!/usr/bin/env python3
"""Turn real_host_check.py recordings into the replay fixtures CI uses.

    python3 e2e/make_fixtures.py e2e/recordings/<run>

Writes e2e/fixtures/real-<scenario>.json for every scenario that has phone frames. Frames keep
their exact shape; only long lists Grok repeats on every chat (slash commands, model catalog)
are cut to their first entries, and the run's temporary chat folder becomes /work.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PHONE_SCENARIOS = ["turns", "reopen", "background", "relaunch", "crossing", "together"]
LONG_LISTS = {"availableCommands": 2, "availableModels": 1, "availableModes": 1}
TEMP_FOLDER = re.compile(r"/(?:private/)?(?:tmp|var/folders/[^\"/]+/[^\"/]+/T)/watch-remote-e2e-[A-Za-z0-9_]+")
ENCODED_TEMP_FOLDER = re.compile(r"%2F(?:private%2F)?(?:tmp|var%2Ffolders%2F[^\"%]+%2F[^\"%]+%2FT)%2Fwatch-remote-e2e-[A-Za-z0-9_]+")
# Grok's own files (terminal logs under its sessions folder) name the computer's paths.
LOCAL_PATH_KEYS = {"output_file", "outputFile", "logPath"}
FORBIDDEN = ["Bearer ", "BEGIN OPENSSH", "PRIVATE KEY", '"token"']


def shrink(value: object) -> object:
    if isinstance(value, dict):
        shrunk: dict = {}
        for key, item in value.items():
            if key in LOCAL_PATH_KEYS and isinstance(item, str):
                shrunk[key] = "~/.grok/sessions/chat/terminal/call.log"
            elif key in LONG_LISTS and isinstance(item, list):
                shrunk[key] = shrink(item)[: LONG_LISTS[key]]
            else:
                shrunk[key] = shrink(item)
        return shrunk
    if isinstance(value, list):
        return [shrink(item) for item in value]
    if isinstance(value, str):
        return ENCODED_TEMP_FOLDER.sub("%2Fwork", TEMP_FOLDER.sub("/work", value))
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("recordings", help="The --out folder of a real_host_check.py run that passed.")
    parser.add_argument("--out", default=str(HERE / "fixtures"))
    args = parser.parse_args(argv)
    source = Path(args.recordings)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    written = 0
    for name in PHONE_SCENARIOS:
        path = source / f"{name}.json"
        if not path.is_file():
            print(f"no {path}; skipped", file=sys.stderr)
            continue
        body = shrink(json.loads(path.read_text(encoding="utf-8")))
        events = [event for event in body["events"] if event.get("k") in {"in", "out", "ui", "check"}]
        if not any(event.get("k") == "check" for event in events):
            print(f"{path} has no checks (the scenario failed?); skipped", file=sys.stderr)
            continue
        text = json.dumps({"scenario": name, "meta": body["meta"], "events": events}, indent=0, ensure_ascii=False)
        leaked = [needle for needle in FORBIDDEN if needle in text]
        if leaked:
            raise SystemExit(f"{path} contains {leaked}; not writing it")
        target = out / f"real-{name}.json"
        target.write_text(text + "\n", encoding="utf-8")
        written += 1
        print(f"{target} ({len(events)} events, {len(text) // 1024} KB)")
    return 0 if written else 1


if __name__ == "__main__":
    raise SystemExit(main())
