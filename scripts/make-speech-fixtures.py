#!/usr/bin/env python3
"""Write the speech clips the Watch UI tests inject.

On macOS, `say` records the phrase and this script appends trailing silence
for the pause clip. Anywhere else, it writes a short tone so the WAV hook
still has bytes to decode. Clips stay in Fixtures/speech and are copied into
Debug watch builds only.
"""

from __future__ import annotations

import argparse
import math
import shutil
import struct
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Fixtures" / "speech"
RATE = 16_000

CLIPS = (
    ("yes", "yes", 0.0),
    ("no", "no", 0.0),
    ("pause-task", "List sessions.", 1.6),
    ("no-pause", "Keep going without a pause.", 0.0),
)


def write_pcm(path: Path, samples: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        frames = b"".join(struct.pack("<h", max(-32767, min(32767, sample))) for sample in samples)
        handle.writeframes(frames)


def tone(seconds: float, frequency: float) -> list[int]:
    count = max(int(RATE * seconds), 1)
    samples = []
    for index in range(count):
        value = 0.35 * math.sin(2 * math.pi * frequency * index / RATE)
        samples.append(int(value * 32767))
    return samples


def silence(seconds: float) -> list[int]:
    return [0] * int(RATE * seconds)


def synthesize(name: str, trailing: float) -> list[int]:
    frequency = {"yes": 440.0, "no": 330.0, "pause-task": 523.0, "no-pause": 392.0}[name]
    spoken = 0.45 if name in {"yes", "no"} else 1.1
    return tone(spoken, frequency) + silence(trailing)


def say_clip(phrase: str, trailing: float, path: Path) -> bool:
    say = shutil.which("say")
    afconvert = shutil.which("afconvert")
    if not say or not afconvert:
        return False
    aiff = path.with_suffix(".aiff")
    spoken = path.with_name(path.stem + "-spoken.wav")
    try:
        subprocess.run([say, "-o", str(aiff), phrase], check=True)
        subprocess.run(
            [afconvert, "-f", "WAVE", "-d", f"LEI16@{RATE}", str(aiff), str(spoken)],
            check=True,
        )
        with wave.open(str(spoken), "rb") as handle:
            if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getframerate() != RATE:
                return False
            raw = handle.readframes(handle.getnframes())
        samples = list(struct.unpack("<" + "h" * (len(raw) // 2), raw))
        samples.extend(silence(trailing))
        write_pcm(path, samples)
        return True
    except (subprocess.CalledProcessError, wave.Error, struct.error):
        return False
    finally:
        aiff.unlink(missing_ok=True)
        spoken.unlink(missing_ok=True)


def check() -> int:
    failures = []
    for name, _phrase, trailing in CLIPS:
        path = OUT / f"{name}.wav"
        if not path.is_file() or path.stat().st_size < 44:
            failures.append(f"missing {path.name}")
            continue
        with wave.open(str(path), "rb") as handle:
            if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getframerate() != RATE:
                failures.append(f"{path.name} is not 16 kHz mono pcm")
                continue
            frames = handle.getnframes()
        if frames < RATE // 4:
            failures.append(f"{path.name} is too short")
        if name == "pause-task" and frames < int(RATE * (0.4 + trailing)):
            failures.append(f"{path.name} is missing trailing silence")
    if failures:
        print("speech fixtures failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("speech fixtures: ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--tone", action="store_true", help="Skip say even when it is installed")
    args = parser.parse_args()
    if args.check:
        return check()
    for name, phrase, trailing in CLIPS:
        path = OUT / f"{name}.wav"
        if not args.tone and say_clip(phrase, trailing, path):
            print(f"said {path.name}")
            continue
        write_pcm(path, synthesize(name, trailing))
        print(f"toned {path.name}")
    return check()


if __name__ == "__main__":
    raise SystemExit(main())
