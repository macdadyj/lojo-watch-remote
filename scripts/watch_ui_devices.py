#!/usr/bin/env python3
"""Choose one 41/42 mm-class Watch and one 45/49 mm-class Watch from simctl JSON."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any


def size_class(name: str) -> str | None:
    if "Apple Watch" not in name:
        return None
    match = re.search(r"(\d+)\s*mm", name)
    if not match:
        return None
    mm = int(match.group(1))
    if mm <= 42:
        return "small"
    if mm >= 45:
        return "large"
    return None


def runtime_rank(runtime: str) -> tuple[int, ...]:
    numbers = [int(piece) for piece in re.findall(r"\d+", runtime)]
    return tuple(numbers)


def pick(data: dict[str, Any]) -> dict[str, tuple[str, str]]:
    """Return small, large, and phone as (udid, name)."""
    watches: dict[str, tuple[tuple[int, ...], int, str, str]] = {}
    phone: tuple[tuple[int, ...], str, str] | None = None
    for runtime, devices in data.get("devices", {}).items():
        rank = runtime_rank(runtime)
        for device in devices:
            if not device.get("isAvailable", True):
                continue
            name = device.get("name", "")
            udid = device.get("udid", "")
            if not udid:
                continue
            if "watchOS" in runtime:
                kind = size_class(name)
                if kind is None:
                    continue
                match = re.search(r"(\d+)\s*mm", name)
                mm = int(match.group(1)) if match else 0
                # Prefer the class center: 42 mm, then 49 mm, then 45 mm.
                if kind == "small":
                    closeness = -abs(mm - 42)
                elif mm >= 49:
                    closeness = 100 - abs(mm - 49)
                else:
                    closeness = -abs(mm - 45)
                current = watches.get(kind)
                candidate = (rank, closeness, udid, name)
                if current is None or candidate[:2] > current[:2]:
                    watches[kind] = candidate
            elif "iOS" in runtime and name.startswith("iPhone"):
                candidate_phone = (rank, udid, name)
                if phone is None or candidate_phone[0] >= phone[0]:
                    phone = candidate_phone
    chosen: dict[str, tuple[str, str]] = {}
    for kind in ("small", "large"):
        if kind not in watches:
            continue
        _, _, udid, name = watches[kind]
        chosen[kind] = (udid, name)
    if phone is not None:
        chosen["phone"] = (phone[1], phone[2])
    return chosen


def self_test() -> int:
    sample = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
                {"name": "Apple Watch SE (40mm)", "udid": "se-40", "isAvailable": True},
                {"name": "Apple Watch Series 11 (42mm)", "udid": "s11-42", "isAvailable": True},
                {"name": "Apple Watch Series 10 (46mm)", "udid": "s10-46", "isAvailable": True},
                {"name": "Apple Watch Ultra 2 (49mm)", "udid": "ultra-49", "isAvailable": True},
                {"name": "Apple Watch Series 6 (44mm)", "udid": "s6-44", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-10-0": [
                {"name": "Apple Watch Series 9 (41mm)", "udid": "old-41", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 17", "udid": "phone-17", "isAvailable": True},
                {"name": "iPad Pro", "udid": "ipad", "isAvailable": True},
            ],
        }
    }
    chosen = pick(sample)
    failures = []
    if chosen.get("small") != ("s11-42", "Apple Watch Series 11 (42mm)"):
        failures.append(f"small {chosen.get('small')}")
    if chosen.get("large") != ("ultra-49", "Apple Watch Ultra 2 (49mm)"):
        failures.append(f"large {chosen.get('large')}")
    if chosen.get("phone") != ("phone-17", "iPhone 17"):
        failures.append(f"phone {chosen.get('phone')}")
    if size_class("Apple Watch Series 6 (44mm)") is not None:
        failures.append("44 mm should not match either class")
    if size_class("iPhone 17") is not None:
        failures.append("iPhone is not a watch class")
    only_large = pick(
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
                    {"name": "Apple Watch Series 10 (46mm)", "udid": "s10-46", "isAvailable": True},
                ]
            }
        }
    )
    if "small" in only_large or only_large.get("large") != ("s10-46", "Apple Watch Series 10 (46mm)"):
        failures.append(f"46 mm large {only_large}")
    if failures:
        print("watch ui device picker failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("watch ui device picker: ok")
    return 0


def load_simctl() -> dict[str, Any]:
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
    return json.loads(raw)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    chosen = pick(load_simctl())
    missing = [kind for kind in ("small", "large", "phone") if kind not in chosen]
    if missing:
        print("missing simulator class: " + ", ".join(missing), file=sys.stderr)
        print("available:", file=sys.stderr)
        subprocess.run(["xcrun", "simctl", "list", "devices", "available"], check=False)
        return 1
    for kind in ("small", "large", "phone"):
        udid, name = chosen[kind]
        print(f"{kind}\t{udid}\t{name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
