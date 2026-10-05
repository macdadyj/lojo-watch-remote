#!/usr/bin/env bash
# Fails if the tree contains private host details or account identifiers.
# Placeholders such as example-host, user, 100.64.0.2, and relay.example are allowed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

python3 - <<'PY'
import re
import sys
from pathlib import Path

root = Path(".")
skip = {".git", "build", ".build", "DerivedData"}
allowed_overlay = {"100.64.0.0", "100.64.0.1", "100.64.0.2", "100.127.255.254"}
email = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(gmail|icloud|me)\.com", re.I)
# Built from pieces so this file does not contain the machine name it looks for.
blocked_host = re.compile(r"\b" + "san" + "ta" + r"\b", re.I)
team = re.compile(r"DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})(?![A-Z0-9])")
ipv4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
bad = []

def overlay_bad(text: str) -> str | None:
    for match in ipv4.findall(text):
        parts = match.split(".")
        try:
            numbers = [int(part) for part in parts]
        except ValueError:
            continue
        if any(number > 255 for number in numbers):
            continue
        # 100.064.0.1 is a rejected non-canonical literal in tests, not an address.
        if any(len(part) > 1 and part.startswith("0") for part in parts):
            continue
        if numbers[0] == 100 and 64 <= numbers[1] <= 127 and match not in allowed_overlay:
            return match
    return None

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if any(part in skip for part in path.parts):
        continue
    if path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".p8"}:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    rel = str(path)
    if email.search(text):
        bad.append(f"{rel}: email address")
    if blocked_host.search(text):
        bad.append(f"{rel}: machine name")
    for found_team in team.findall(text):
        if found_team != "YOURTEAMID":
            bad.append(f"{rel}: team id")
            break
    found = overlay_bad(text)
    if found:
        bad.append(f"{rel}: overlay address {found}")

if bad:
    print("privacy scan failed:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
print("privacy scan: ok")
PY