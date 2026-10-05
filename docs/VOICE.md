# Watch voice

## Before

Tapping Speak or the approval microphone opened the system dictation sheet. Each utterance waited for Done. A follow-up opened the sheet again. Allow on a task was a tap, or two dictation sheets (allow, Done, yes, Done).

## After

Tap Speak once. The Watch records with `AVAudioEngine` and decides the utterance ended after about 0.65 seconds below the silence threshold (`VoiceEndpointDetector`). It sends 16 kHz audio to the iPhone. The iPhone transcribes with `SFSpeechRecognizer` and returns the text. The Watch acts, speaks, and listens again.

Spoken allow still waits for a second word (yes or confirm). Deny and stop send on the first word. The on-screen Allow, Deny, Stop, and Yes buttons remain for when speech misses.

## Why recognition is on the iPhone

Checked against the Xcode 26 Speech SDK:

- `SFSpeechRecognizer` is available on iOS, macOS, and tvOS. It is not available on watchOS.
- `SpeechAnalyzer` and `SpeechTranscriber` (the iOS 26 speech API) are available on iOS, macOS, tvOS, and visionOS. Apple’s WWDC25 session says `SpeechTranscriber` is not available on watchOS.
- The Watch can record with `AVAudioEngine`. That is the silence detector. It does not produce text.
- The system dictation sheet (`TextFieldLink` / `presentTextInputController`) is the only on-watch transcriber. It always requires Done, so it is only the fallback when the iPhone app is not reachable.

## Automated checks

Unit tests cover the silence detector, the “send when speech ends” rule, the audio packet codec, and the spoken allow / yes / deny / stop script. They do not open a microphone.

```bash
xcodegen generate
```

Then run the `WatchRemote` scheme tests on an iPhone simulator, the same way the iOS workflow does. `testHandsFreeSilenceSendsWithoutDoneAndSpokenApprovalsStayTwoStep` is the check. CI runs it with the rest of `WatchRemoteTests`.

## Simulator

The Watch simulator has no microphone, so it cannot run the live loop. Launch the scripted voice loop instead. It shows what a conversation would say, including that a pause sends and Done is not used.

```bash
xcrun simctl launch booted com.lojo.WatchRemote.watchkitapp \
  -WatchRemoteScreen voice-loop -WatchRemoteAppearance dark
```

Pull requests capture that screen as `watch-voice-loop.png`. The microphone stays off.

## Once on a Watch and iPhone

The live microphone cannot be checked in CI.

1. Install the build. Open Watch Remote on the iPhone and leave it reachable.
2. On the Watch, tap Speak. The first time, allow the microphone on the Watch and speech recognition on the iPhone. Those prompts should not come back on the next utterance.
3. Say “list sessions”, then pause. The Watch should answer without a Done tap, then listen again.
4. With a task waiting for approval, say “allow”, pause, and after the read-back say “yes”. It should approve without tapping Allow.
5. On another approval, say “deny” once. It should deny without a second confirm.
6. While a task is running, say “stop”. It should stop.
7. Force-quit the iPhone app, tap Speak, and confirm the Watch explains that hands-free needs the iPhone and opens the dictation sheet. That sheet still needs Done.
8. Tap End. The microphone should stop. Raising the wrist should not approve anything by itself.
