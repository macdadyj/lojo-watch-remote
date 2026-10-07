# Watch voice

## Before

Tapping Speak or the approval microphone opened the system dictation sheet. Each utterance waited for Done. A follow-up opened the sheet again. Allow on a task was a tap, or two dictation sheets (allow, Done, yes, Done).

## After

Tap Speak once. The Watch records with `AVAudioEngine` and decides the utterance ended after about 1.5 seconds below the silence threshold (`VoiceEndpointDetector`). A listen also ends at 12 seconds so it cannot hang. When the iPhone app is reachable, the Watch sends 16 kHz audio there and the iPhone transcribes with `SFSpeechRecognizer`. When the iPhone is away and the Watch has a direct pairing, the same recording goes to the computer over the relay. The Watch acts, speaks, and listens again.

Spoken allow still waits for a second word (yes or confirm). Deny and stop send on the first word. The on-screen Allow, Deny, Stop, and Yes buttons remain for when speech misses.

## Why a TestFlight build still opened the dictation sheet

The pause-to-send path records on the Watch and transcribes on the iPhone. Three faults in that path presented `presentTextInputController` (the system sheet, which always needs Done) even when the iPhone app was open:

- `AVAudioSession` category `.playAndRecord` can fail on watchOS, and `outputFormat(forBus:)` can report a 0 Hz sample rate. Either one was treated as “microphone failed” and opened the sheet immediately.
- `WCSession.isReachable` is often false for a moment after the Watch app becomes frontmost, even with the iPhone app open. The old check did not wait, so Speak went straight to the sheet.
- `SFSpeechRecognizer` errors such as “No speech detected” (`kAFAssistantErrorDomain` 1110), and `requiresOnDeviceRecognition` when the on-device asset is missing, were sent back as a hard failure. The Watch opened the sheet instead of listening again.

A build installed before this path existed still uses the sheet, because that Watch binary’s Speak button calls the dictation controller. The Watch app is inside the iPhone archive. After the new TestFlight build is installed, open Watch Remote on the Watch once. The home screen shows a short **Speak** control and the words **Pause sends**. A microphone that covers the session list is the previous binary.

## Why recognition is on the iPhone

Checked against Apple’s Speech documentation and WWDC25 session 277 (“Bring advanced speech-to-text to your app with SpeechAnalyzer”):

- `SFSpeechRecognizer` is available on iOS, macOS, and tvOS. It is not available on watchOS.
- `SpeechAnalyzer` and `SpeechTranscriber` are the iOS 26 speech API. WWDC25 describes them for the platforms that gained that model. They are not available on watchOS. `DictationTranscriber` is likewise absent from watchOS.
- There is no separate watchOS conversation API that returns text without the system dictation sheet.
- The Watch can record with `AVAudioEngine`. Silence detection is local. It does not produce text.
- The system dictation sheet (`TextFieldLink` / `presentTextInputController`) is the only on-watch transcriber. It always requires Done. It opens only when the Watch has no direct pairing and the iPhone stays unreachable, or when the microphone cannot be used and nothing else can take the audio. A paired computer transcribes through `WATCHREMOTE_STT_COMMAND` or a local `whisper` binary. If neither is configured, the Watch says "No transcriber is configured on this computer." and offers **Dictate**. A reachable iPhone does not open the sheet.

## Automated checks

Unit tests cover the silence detector, the “send when speech ends” rule, the audio packet codec, and the spoken allow / yes / deny / stop script. They do not open a microphone.

```bash
xcodegen generate
```

Then run the `WatchRemote` scheme tests on an iPhone simulator, the same way the iOS workflow does. `testHandsFreeSilenceSendsWithoutDoneAndSpokenApprovalsStayTwoStep`, `testOpenPhoneStaysOnPauseToSendAndSpeakStaysOffTheHistory`, and `testPairHelpNamesThePublicCommandAndAcceptsAnAliasFromTheCode` are the checks. CI runs them with the rest of `WatchRemoteTests`.

```bash
scripts/watch-ui-checklist.sh
```

That script checks the pair-help copy, the short Speak bar, and that the dictation sheet is not the Speak button. After screenshots exist, `scripts/watch-ui-checklist.sh --screenshots build/screenshots` checks the PNGs. CI uploads them as the `screenshots` artifact.

`scripts/watch-ui-test.sh` is the watchOS simulator chain. It boots one 41/42 mm-class Watch and one 45/49 mm-class Watch. The scaffold taps home, a past session, Speak, and I'm done. `WatchPhoneOffUITests` repeats that conversation with the iPhone simulated off, including a clip with no pause, yes and no, a missing chat, and the unpaired dictation fallback. The microphone stays off. Debug clips from `Fixtures/speech` are loaded only for those launches. `scripts/watch_ui_vision.py` then scores the shots for text size, contrast, clipping, and Speak-bar overlap. An LLM score runs only when `WATCH_UI_VISION_API_KEY` is set. Screenshots are the `watch-ui-screenshots` artifact (`small/` and `large/`, names such as `phone-off-home.png`). TestFlight does not start until this job passes. See [WATCH-UI-TESTS.md](WATCH-UI-TESTS.md).

## Simulator

The Watch simulator has no microphone, so it cannot run the live loop. Two scripted screens keep the microphone off:

```bash
xcrun simctl launch booted com.lojo.WatchRemote.watchkitapp \
  -WatchRemoteScreen voice-chat -WatchRemoteAppearance dark
xcrun simctl launch booted com.lojo.WatchRemote.watchkitapp \
  -WatchRemoteScreen voice-loop -WatchRemoteAppearance dark
```

`voice-chat` shows a short history, Yes, New task, and a one-line Speak / I'm done bar. `voice-loop` shows the scripted turns in that same chrome, including that a pause sends and Done is not used. I'm done stops the mic, sends what was captured, and leaves the chat open. Pull requests capture `watch-voice-chat.png`, `watch-voice-loop.png`, and `watch-mic.png` (session list with the short Speak bar). `scripts/watch-ui-checklist.sh` checks the copy and the chrome, and checks those PNGs when a screenshot directory is passed.

## Once on a Watch and iPhone

The live microphone cannot be checked in CI.

1. Install the build. Open Watch Remote on the iPhone and leave it reachable.
2. On the Watch, tap Speak. The first time, allow the microphone on the Watch and speech recognition on the iPhone. Those prompts should not come back on the next utterance.
3. Say “list sessions”, then pause about a second and a half. The Watch should answer without a Done tap, then listen again.
4. With a task waiting for approval, say “allow”, pause, and after the read-back say “yes”. It should approve without tapping Allow.
5. On another approval, say “deny” once. It should deny without a second confirm.
6. While a task is running, say “stop”. It should stop.
7. With the iPhone app still open, tap Speak. The conversation stays on screen (history, I'm done, New task). It should not open the keyboard. Say a phrase and pause. Done is not part of that turn. I'm done is the stop control, not End.
8. Force-quit the iPhone app and tap Speak. With a direct pairing, pause-to-send still works: the Watch records, detects silence, and the computer transcribes. Set up that transcriber with the steps in [outbound-relay.md](outbound-relay.md). The dictation sheet opens only when there is no pairing, or the microphone cannot be used. That sheet still needs Done.
9. While it is listening, tap I'm done before the pause. The microphone stops, what you already said is sent, and the chat stays open so you can speak again. The session is not ended.
10. Tap a past chat. Its messages show, and Speak stays on that chat. A chat the computer no longer has shows "That chat is no longer on this computer."
