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
    need("case .handsFree" in voice and "case .handsFreeHost" in voice and "case .presentDictation" in voice, "voice routes")
    need("silence: 1.5" in voice, "trailing silence default")
    need("maximumSpeech: 12" in voice, "listen duration cap")
    need("No transcriber is configured on this computer." in voice, "no transcriber copy")
    need('accessibilityIdentifier("voice.speak")' in chrome, "voice.speak identifier")
    need('accessibilityIdentifier("voice.done")' in chrome, "voice.done identifier")
    need('accessibilityIdentifier("voice.action")' in chrome, "voice.action identifier")
    need("Action Button" in read("Core/Sources/WatchRemoteCore/ListenControl.swift"), "action button copy")
    need("I'm done" in chrome, "I'm done control")
    need("endVoiceConversation()" not in chrome, "end conversation button is gone")
    need("stopTalking" in chat, "I'm done sends without leaving the chat")
    need("finishEarly" in capture, "stop flushes captured audio")
    need("VoiceChromeMetrics.maxSpeakBarHeight" in chrome, "chrome uses the height cap")
    need(".padding(.vertical, 18)" not in chrome, "speak chrome must not use the full-face padding")
    need('accessibilityIdentifier("voice.history")' in chat, "voice.history identifier")
    need("VoiceHomeBar()" in home, "home uses the short speak bar")
    need("VoiceHomeSection" not in home and "VoiceHomeSection" not in chat, "full-face speak section is gone")
    need('accessibilityIdentifier("session.list")' in home, "session list identifier")
    need('accessibilityIdentifier("session.row.\\(session.id)")' in home, "session row identifier")
    need('accessibilityIdentifier("session.detail")' in home, "session detail identifier")
    need("openHistory" in home and "openHistory" in chat, "session rows resume a chat")
    need(
        "That chat is no longer on this computer." in read("Core/Sources/WatchRemoteCore/SessionResume.swift"),
        "missing session copy",
    )
    need("case resume" in read("Core/Sources/WatchRemoteCore/Models.swift"), "resume command")
    store = read("App/iOS/Services/RemoteStore.swift")
    need("SessionResume.missingMessage" in store, "phone surfaces a missing session")
    need("loadSessionRaw" in read("App/iOS/Services/LiveLink.swift"), "resume loads the session")
    need('"_x.ai/session/list"' in read("Core/Sources/WatchRemoteCore/ACPCodec.swift"), "underscore list method")
    need("op: .resume" in read("App/Watch/DirectSession.swift"), "direct resume op")
    need("func transcribe" in read("App/Watch/DirectSession.swift"), "direct transcribe")
    need("case .handsFreeHost" in chat, "watch handles the host listen route")
    need('op == "resume"' in read("host/outbound.py"), "host resume handler")
    outbound = read("host/outbound.py")
    need('op == "transcribe"' in outbound, "host transcribe handler")
    need("No transcriber is configured on this computer." in outbound, "host no transcriber copy")
    need("-WatchRemoteUITest" in read("App/Watch/WatchApp.swift"), "ui test launch flag")
    need("-WatchRemoteRelayProbe" in read("App/Watch/WatchApp.swift"), "relay probe launch flag")
    need("-WatchRemotePhoneProbe" in read("App/Watch/WatchApp.swift"), "phone probe launch flag")
    need("WatchTransportDiagnostics" in read("Core/Sources/WatchRemoteCore/ListenControl.swift"), "transport diagnostics line")
    need('accessibilityIdentifier("voice.diagnostics")' in home, "home diagnostics identifier")
    need('accessibilityIdentifier("voice.diagnostics")' in chat, "chat diagnostics identifier")
    need("for_watch" in outbound, "host copies lines onto the watch transcript")
    need("session-seed" in read("host/relay_probe.py"), "reopened chat fixture on the local relay")
    need("-WatchRemoteEchoProbe" in read("App/iOS/Services/RemoteStore.swift"), "phone echo probe")
    need((ROOT / "App/WatchUITests/WatchTransportUITests.swift").is_file(), "watch transport ui test")
    need("WATCHREMOTE_REPO_ROOT" in read("scripts/watch-ui-test.sh"), "watch ui test exports the repo root")
    need("-WatchRemotePhoneOff" in read("App/Watch/WatchApp.swift"), "phone off launch flag")
    phone_off = read("App/WatchUITests/WatchPhoneOffUITests.swift")
    need("-WatchRemotePhoneOff" in phone_off, "phone off ui tests")
    need("That chat is no longer on this computer." in phone_off, "missing chat case")
    need("Heard list sessions" in phone_off, "mock host reply case")
    outbound_unit = read("host/watch-remote-outbound.service")
    need("WATCHREMOTE_STT_COMMAND=%h/.local/bin/watch-remote-stt" in outbound_unit, "outbound service runs the transcriber")
    need("stt.env" in outbound_unit, "optional stt env file")
    need("WatchAudioInjection" in read("App/Watch/AudioInjection.swift"), "audio injection hook")
    need((ROOT / "App/WatchUITests/WatchScaffoldUITests.swift").is_file(), "watch ui test scaffold")
    need((ROOT / "scripts/watch-ui-test.sh").is_file(), "watch ui test script")
    need((ROOT / "scripts/watch_ui_vision.py").is_file(), "watch ui vision scorer")
    idle = "0199aaaa-0000-7000-8000-000000000003"
    need(idle in read("Core/Sources/WatchRemoteCore/Models.swift"), "demo idle session id")
    need(idle in read("App/WatchUITests/WatchScaffoldUITests.swift"), "ui test taps the demo idle session")

    present_hits = []
    for path in (ROOT / "App").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        if "presentTextInputController" in text:
            present_hits.append(str(path.relative_to(ROOT)))
    need(present_hits == ["App/Watch/Voice.swift"], f"dictation sheet only in Voice.swift, found {present_hits}")
    need("func present(_ onText:" in chat and "presentTextInputController" in chat, "dictation stays behind VoiceInput.present")
    need("VoiceListenPolicy.route" in chat, "Speak consults the listen route")
    direct = read("App/Watch/DirectSession.swift")
    notice = read("Core/Sources/WatchRemoteCore/ListenControl.swift")
    need("RelayUserNotice" in direct, "direct session uses relay notices")
    need("This relay did not accept this pairing." not in direct, "reject sentence is not hardcoded on send failure")
    need("pairingRejectedText" in notice, "reject sentence lives with the auth classifier")
    need("WKExtendedRuntimeSession" in read("App/Watch/ListenRuntime.swift"), "extended runtime for wrist down")
    need("ToggleListenIntent" in read("App/Watch/AskGrokIntent.swift"), "action button intent")
    need("simulateWristDown" in read("App/Watch/ListenSession.swift"), "wrist down simulation")
    need("holdThroughWristDown" in read("App/Watch/Voice.swift"), "scene background does not stop the listen")
    need("case .showPairing" in read("App/iOS/Services/RemoteStore.swift"), "watch can open the iPhone pair screen")
    manual = read("App/WatchUITests/WatchManualListenUITests.swift")
    need("voice.action" in manual, "action button ui test")
    need("voice.wrist" in manual, "wrist down ui test")
    need("This relay did not accept this pairing." in manual, "ui test watches the reject banner")
    need("-WatchRemoteMaxListen" in manual, "duration cap ui test")
    need(
        "testPairingRejectBannerIsOnlyEmittedForANonOkAuthPayload" in read("App/Tests/WatchRemoteCoreTests.swift"),
        "pairing reject unit test",
    )
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
    print("- Conversation shows history, I'm done, New task, and Yes when an approval is waiting.")
    print("- Manual listen is the default. Pause sends is optional. The iPhone transcribes when it is reachable.")
    print("- A paired computer transcribes when the iPhone is away. Dictation is the last resort.")
    print("- Screenshots: watch-mic.png, watch-voice-chat.png, watch-voice-loop.png, iphone-unpaired-dark.png.")
    print("- scripts/watch-ui-test.sh runs the scaffold, phone-off, and manual listen cases on both Watch sizes.")
    print("- Pixel scoring checks text size, contrast, clipping, and that the Speak bar does not cover replies.")
    if failures:
        print("failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("watch ui checklist: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
