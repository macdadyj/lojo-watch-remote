# Watch UI tests

The `watch-ui` job in `.github/workflows/ios.yml` runs on every pull request, every push to `main`, and every manual run. TestFlight upload waits for it. The phone screenshot job does not gate the upload.

## What the scaffold does

`scripts/watch-ui-test.sh` picks one 41/42 mm-class simulator and one 45/49 mm-class simulator, plus an iPhone to pair with. `WatchScaffoldUITests` then:

1. Launches `com.lojo.WatchRemote.watchkitapp` with `-WatchRemoteUITest` and `-WatchRemoteInjectClip pause-task`.
2. Checks the session list is on screen.
3. Taps the idle demo session and checks that chat reopened with its title and summary. A tap that does not open the chat fails.
4. Taps Speak on that open chat and checks the status says Listening. The restored title stays on screen.
5. Taps I'm done and checks the chat stays open, the captured line is sent, and Speak is still there.

That launch does not open the microphone, SSH, or the relay. `WatchAudioInjection` reads `Fixtures/speech/pause-task.wav` from the Debug app bundle. Release archives skip that copy. `VoiceTestHost` is the mock reply table the later cases will drive.

Screenshots are uploaded as the `watch-ui-screenshots` artifact (`small/` and `large/`).

## Readability

`scripts/watch_ui_vision.py` scores the Watch PNGs after the taps. `simulator-*.png` is the whole watch case from `simctl` and is not scored. The XCTest attachments are the screen, and `manifest.json` keeps their names (`scaffold-home`, `scaffold-listening`, and the rest).

- Text lines shorter than 10 px fail.
- Median contrast under 3.0 fails.
- Text pixels on the side edges fail as clipping.
- On home, voice, and listening shots, reply text that runs into the bottom Speak bar fails.

`scripts/watch_ui_vision.py --self-test` builds tiny synthetic shots and checks those failures. The iOS screenshot job scores `watch-*.png` the same way.

If the repository secret `WATCH_UI_VISION_API_KEY` is set, the script also sends up to six shots to an OpenAI-compatible vision endpoint (`WATCH_UI_VISION_URL`, default `https://api.openai.com/v1/chat/completions`, model `WATCH_UI_VISION_MODEL` or `gpt-4o-mini`). When the secret is absent, that step logs `llm vision: skipped` and the pixel checks still gate the job.

## Local

```bash
python3 scripts/make-speech-fixtures.py
python3 scripts/watch_ui_devices.py --self-test
scripts/watch-ui-test.sh --self-test
brew install xcodegen
xcodegen generate
scripts/watch-ui-test.sh
```

`make-speech-fixtures.py` uses `say` on macOS when it is installed, and writes a tone otherwise. `--check` only reads the files.

## History restore

Tapping a session row calls `openHistory`. The phone lists with `_x.ai/session/list`, then `session/load`, and publishes the transcript. The direct host answers `resume` the same way. A session that is not in the list shows "That chat is no longer on this computer." The UI test uses the demo catalog, so it does not open the network. A later voice turn in that chat prompts the restored session instead of creating a new one.

## I'm done

The conversation bar's stop control is **I'm done**. It stops the microphone immediately, sends the audio captured so far (or the injected clip's transcript in the UI test), and leaves the chat open. It does not end the session.

## Phone off

`WatchPhoneOffUITests` launches with `-WatchRemotePhoneOff`. The iPhone is treated as unreachable. A direct pairing is present unless the launch also passes `-WatchRemoteHostMissing`. The microphone stays off. I'm done sends the injected clip, and `VoiceTestHost` supplies the reply.

| | Launch | What it checks |
| --- | --- | --- |
| a | phone off | Home shows `direct`, Pause sends, and Speak. The dictation copy is absent. Shot `phone-off-home`. |
| b | phone off | The idle demo chat opens with its title and summary. Shot `phone-off-restored`. |
| c | phone off, `pause-task` | Speak shows Listening, not dictation, and the restored title stays. Shot `phone-off-listening`. |
| d | phone off, `pause-task` | I'm done sends `You: list sessions`, the mock host says `Heard list sessions`, and Speak returns. Shot `phone-off-done`. |
| e | phone off, `no-pause` | I'm done sends the clip even though it has no trailing silence. Shot `phone-off-no-pause`. |
| f | phone off, `yes` then `no` | The approval chat stays open. The mock host says Allowed, then Denied. Shots `phone-off-yes` and `phone-off-no`. |
| g | host missing, then `-WatchRemoteMissingSession` | Speak shows the dictation fallback and Dictate. An unknown session says "That chat is no longer on this computer." Shots `phone-off-unpaired` and `phone-off-missing`. |

The system dictation sheet is not presented in the simulator. Case g checks the fallback copy and the Dictate button. Opening that sheet still needs a Watch. The computer-side transcriber is whisper.cpp via `watch-remote-outbound`, documented in [outbound-relay.md](outbound-relay.md).
