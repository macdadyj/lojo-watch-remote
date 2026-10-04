# Morning review

Public branch `cursor/watch-remote-55d3`. Nothing here was merged. TestFlight was not started from this session.

## What changed

- The watch app stays under `Watch/WatchRemoteWatch.app`. The archive check refuses `PlugIns/*.app`.
- The public tree uses placeholders (`user`, `100.64.0.2`, port `22`, label `example-host`). The team id is not in git. Real values are entered on Computer, or in gitignored `Config/Local.xcconfig`.
- Overlay checks reject leading-zero IPv4 text so a socket cannot treat it as octal. SSH dials the canonical dotted form.
- A dropped SSH channel is not reused. Allow and Deny update the row only after the approval is written. Watch commands are queued when the iPhone is not reachable. Returning to the iPhone app reconnects SSH.
- If `grok agent serve` is down, the phone falls back to headless `grok -p` with `--permission-mode dontAsk` and says approvals are unavailable. Demo mode sends nothing.
- Watch Allow, Deny, and Stop play haptics. A new approval plays a notification haptic. The iPhone Allow and Deny buttons do the same.
- Buttons sit in the scroll view, with the system navigation bar left visible. Empty, connecting, offline, pairing, error, and long-text screens are launch fixtures for screenshots.
- The iPhone display name is **Watch Remote for Grok**. The Watch home-screen name stays **Watch Remote** so it fits the icon. Store text is in `metadata/en-US/`.
- Watch light mode is a light page with dark text. The compose screen shows the whole task, then Start.
- Allow and Deny wait until the SSH flush succeeds before the card changes. If the agent channel drops, the next task uses headless mode.
- A live Smart Stack complication is not in this build. It needs an App Group entitlement, and that entitlement needs the Apple team at signing time.
- Design, security, and reliability reviews signed off on this tree. They did not ask for a history rewrite as a code change.

## What to test on the phone

1. Install the TestFlight build you upload from the green SHA below.
2. Confirm the home-screen name is Watch Remote for Grok, and the Watch app is Watch Remote.
3. Leave the app in Demo. Sessions, an approval, and New task should work with no network.
4. On Computer, replace the placeholder with your overlay address, user, and port. Save should refuse a public address, a hostname, and an address with a leading zero.
5. Generate a key. Copy the authorize command and run it on the computer. The private key should not appear.
6. Trust the host key on first connect, then connect again and confirm it does not ask.
7. With `grok agent serve` on `127.0.0.1:2419`, start a task from the Watch and Allow it. You should feel a haptic.
8. Stop the agent server, start another task, and confirm the Watch says tasks cannot ask for approval.
9. Switch away from the iPhone app and back. The SSH session should reconnect.
10. Force-quit the iPhone app. The Watch should say the iPhone app is closed, and a Start tap should keep the prompt.

## Known issues

- Git history before the scrub commit still contains the old host placeholder, username, and team id. Rewriting that history needs a force-push. The current tree does not contain them. Left for you to decide.
- Build 26 from `a77039c` is the TestFlight build that uploaded. The workflow run was cancelled afterwards because screenshots and the archive shared a 40-minute job. Upload now has its own job. Manual runs take a short screenshot set. The limit is 60 minutes. Pull requests still take the full screenshot set and do not upload.
- The next manual run creates another Apple Distribution certificate and does not revoke the ones already there. Apple allows a small number of active distribution certificates.
- A Smart Stack complication is still not in the app. It would be a third bundle id and would need its own App Store profile. The archive only provisions the iPhone app and the watch app. Adding the widget before that App ID exists would fail the next upload.
- The upload that failed was rejected because the watch app was in `PlugIns/`. This branch embeds it under `Watch/`. That layout is checked in CI on the simulator app. The archive check runs only when you start the TestFlight workflow.
- CI screenshots are the design check available from this environment. There is no local iOS Simulator here.
- The Smart Stack widget is not included, for the signing reason above.

## Commits from this overnight pass

- `90c7c4829f839e246591ff6d09921d5ba6c6cc42` — approval reliability, Watch states, store text
- `aa6114e1ed667e093567a28d2eb2595fb3d5d7a7` — approval counted only after the flush
- `699d5bb2ec2f5271f48e236cc9a6ceb129eb8097` — light Watch page and the full compose task. iOS workflow [earlier run](https://github.com/macdadyj/lojo-watch-remote) passed.
- The following commit splits TestFlight into its own job, shortens screenshots on manual runs, and raises the job limit to 60 minutes. Pull requests still take the full screenshot set.

## Ready SHA

Use the tip of `cursor/watch-remote-55d3` after the iOS workflow on that commit is green. Do not dispatch TestFlight while that workflow is still running. Archive stays skipped on pull requests, so the upload still has to be the manual run.
