#!/usr/bin/env python3
"""Watch UI checklist an agent can run without a simulator.

XCTest covers the pair-help copy, the pause-to-send route, and the chrome
metrics (`testPairHelpNamesThePublicCommandAndAcceptsAnAliasFromTheCode`,
`testOpenPhoneStaysOnPauseToSendAndSpeakStaysOffTheHistory`). This script
checks the SwiftUI sources still follow that contract, and, when a screenshot
directory is passed, that the CI shots exist.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_SHOTS = (
    "watch-mic.png",
    "watch-voice-chat.png",
    "watch-voice-loop.png",
    "iphone-unpaired-dark.png",
)


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise SystemExit(f"missing {relative}")
    return path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--screenshots", help="Directory of simulator PNGs from capture-screenshots.sh")
    args = parser.parse_args()
    failures: list[str] = []

    help_copy = read("Core/Sources/WatchRemoteCore/PairingPayload.swift")
    voice = read("Core/Sources/WatchRemoteCore/VoiceHandsFree.swift")
    computer = read("App/iOS/Views/ComputerView.swift")
    chrome = read("App/Watch/VoiceChrome.swift")
    chat = read("App/Watch/Voice.swift")
    capture = read("App/Watch/VoiceCapture.swift")
    home = read("App/Watch/WatchViews.swift")

    def need(ok: bool, message: str) -> None:
        if not ok:
            failures.append(message)

    need('headline = "On the computer, run your pair command (see host setup)."' in help_copy, "pair headline")
    need('publicCommand = "watch-remote-pair"' in help_copy, "public command name")
    need("watch-remote-pair-santa" not in help_copy, "pair help must not hardcode a private alias")
    need("gmail" not in help_copy.lower(), "pair help must not contain an email")
    need('accessibilityIdentifier("pair.help")' in computer, "pair.help identifier")
    need("PairingHelpCopy.headline" in computer, "computer screen uses the shared pair copy")
    need("PairingHelpCopy.publicCommand" in computer, "computer screen shows the public script name")

    need("maxSpeakBarHeight: CGFloat = 44" in voice, "speak bar height cap")
    need("case .handsFree" in voice and "case .presentDictation" in voice, "voice routes")
    need('accessibilityIdentifier("voice.speak")' in chrome, "voice.speak identifier")
    need('accessibilityIdentifier("voice.end")' in chrome, "voice.end identifier")
    need("VoiceChromeMetrics.maxSpeakBarHeight" in chrome, "chrome uses the height cap")
    need(".padding(.vertical, 18)" not in chrome, "speak chrome must not use the full-face padding")
    need('accessibilityIdentifier("voice.history")' in chat, "voice.history identifier")
    need("VoiceHomeBar()" in home, "home uses the short speak bar")
    need("VoiceHomeSection" not in home and "VoiceHomeSection" not in chat, "full-face speak section is gone")
    need('accessibilityIdentifier("session.list")' in home, "session list identifier")

    present_hits = []
    for path in (ROOT / "App").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        if "presentTextInputController" in text:
            present_hits.append(str(path.relative_to(ROOT)))
    need(present_hits == ["App/Watch/Voice.swift"], f"dictation sheet only in Voice.swift, found {present_hits}")
    need("func present(_ onText:" in chat and "presentTextInputController" in chat, "dictation stays behind VoiceInput.present")
    need("VoiceListenPolicy.route" in chat, "Speak consults the pause-to-send route")
    need("outputFormat(forBus: 0)" in capture and "inputFormat(forBus: 0)" in capture, "capture tries the hardware input format")
    need("requiresOnDeviceRecognition = false" in read("App/iOS/Services/WatchSpeechRelay.swift"), "on-device recognition is not required")

    if args.screenshots:
        directory = Path(args.screenshots)
        if not directory.is_dir():
            failures.append(f"screenshot directory missing: {directory}")
        else:
            for name in REQUIRED_SHOTS:
                shot = directory / name
                if not shot.is_file() or shot.stat().st_size < 1024:
                    failures.append(f"screenshot missing or empty: {name}")

    print("Watch UI checklist")
    print("- Pair help says to run your pair command and names watch-remote-pair.")
    print("- An operator alias is documented in host setup. The app does not hardcode it.")
    print("- Home Speak is a short bar. Session history stays in the scroll view.")
    print("- Conversation shows history, End, New task, and Yes when an approval is waiting.")
    print("- Pause-to-send is the route when the iPhone app is reachable.")
    print("- The dictation sheet opens only after the iPhone stays unreachable, or when Dictate is tapped.")
    print("- Screenshots: watch-mic.png, watch-voice-chat.png, watch-voice-loop.png, iphone-unpaired-dark.png.")
    if failures:
        print("failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("watch ui checklist: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
