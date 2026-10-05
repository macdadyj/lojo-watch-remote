# Watch Remote setup

The GitHub Action generates the Xcode project, runs unit tests, and captures simulator screenshots on every pull request. Those pull requests do not sign or upload, and they keep the full screenshot set. A push to `main`, or a manual run of the **iOS** workflow, uploads to TestFlight from a separate job that does not wait for screenshots. That job still runs the unit tests, then archives. The screenshot job on those runs keeps one iPhone and one Watch. Each job stops after 60 minutes. Cloud signing is not used. The run creates a new iOS Distribution certificate and two App Store profiles through the App Store Connect API, imports them into a temporary keychain, and deletes the profiles and the keychain at the end, whether the upload worked or not. It also revokes the one distribution certificate that run created, and only that one, so certificates do not pile up. It never touches certificates it did not create. If creating the certificate is forbidden, or the account already has the maximum number of distribution certificates, the log prints the API response and stops.

The workflow runs on `macos-26` and selects Xcode 26 (`Xcode_26.6.app`, then `Xcode_26.app`, then `Xcode.app`). If the hosted image uses a different runner name, change `runs-on` in `.github/workflows/ios.yml`.

## What you do in Apple Developer and App Store Connect

1. In Certificates, Identifiers & Profiles, create an explicit App ID `com.lojo.WatchRemote` (iOS).
2. Create an explicit App ID `com.lojo.WatchRemote.watchkitapp` (watchOS) and set its companion app to `com.lojo.WatchRemote`.
3. In App Store Connect, create an app with bundle ID `com.lojo.WatchRemote`. The watch app is part of that record. It is not a second app.
4. Create an App Store Connect API key with the **App Manager** role. Download the `.p8` once. Note the Key ID and the Issuer ID.
5. Add the GitHub Actions secrets. The commands below do not include secret values. Paste each value when `gh` prompts, or pipe it on stdin.

   ```bash
   gh secret set ASC_KEY_ID
   gh secret set ASC_ISSUER_ID
   base64 < AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8
   gh secret set DEVELOPMENT_TEAM
   ```

   `DEVELOPMENT_TEAM` is your Apple team id. It is a GitHub secret, injected when the archive runs, and it is not written in this repository. `ASC_KEY_P8` may be the `.p8` file as base64 (line breaks are fine) or the PEM text beginning with `-----BEGIN PRIVATE KEY-----`. The workflow writes a temp file named `AuthKey_<id>.p8`, uses it only to call the API and to upload, and deletes it. It never prints the key. Creating a distribution certificate needs permission the App Manager role may not have; a forbidden response stops the run so an Admin key can be created. The build number is the GitHub run number plus 100 (run 1 uploads build 101), so it stays above the builds already in TestFlight, and each upload is a new build. A re-run of the same run appends the attempt, for example `105.2`. Both Info.plists set `ITSAppUsesNonExemptEncryption` to false.

6. On the iPhone and the Apple Watch, turn on Developer Mode (Settings → Privacy & Security → Developer Mode) before installing a development build. TestFlight builds do not need Developer Mode.
7. For a development install from Xcode, register the iPhone and the Watch under Devices. TestFlight does not need the devices registered.

## What you do on the iPhone

1. Install the TestFlight build (or run the `WatchRemote` scheme from Xcode onto the phone). The watch app is embedded in the iPhone app.
2. On the computer, run `watch-remote-pair` (see [HOST-SETUP.md](HOST-SETUP.md)). To let the Watch work without the iPhone, pass `--relay-url` with the `wss` address of a relay you host. That setup is in [outbound-relay.md](outbound-relay.md). This repository does not deploy one. On the iPhone, open **Computer**. The **Scan QR code** button is at the top until a computer is paired. The shipped values (`user`, `100.64.0.2`, port `22`, label `example-host`) are placeholders. The phone keeps several computers and the Watch can switch the active one. Demo mode is unchanged. The Watch says **via iPhone** or **direct**, and **Pair on iPhone first** when nothing is paired.
3. On the iPhone, open **Computer** and scan the QR while `watch-remote-pair` is still open. Confirm the computer. The phone creates a key if it needs one and the computer authorizes it. You do not copy a key. **Advanced** still has the authorize command if the 10-minute window expires. The private key stays in the iPhone Keychain. Forwarding is limited to `127.0.0.1:2419`.
4. Connect once. If the pairing code pinned a host key, the phone shows that fingerprint and asks you to confirm it. Trust it only if it matches. A different key is refused.
5. A pairing code that includes the agent secret stores it in the Keychain for that computer. Otherwise, in **Settings**, choose **SSH** and paste the secret. The field clears after save. The secret is sent only inside the SSH tunnel.

Demo mode is the default until you switch to SSH. It does not open a socket and does not read the Keychain for a connection.

The computer is prepared in [HOST-SETUP.md](HOST-SETUP.md). The optional relay is in [relay-api.md](relay-api.md).

## Local generate

```bash
brew install xcodegen
xcodegen generate
```

`xcodegen` runs `scripts/patch-watch-embed.py` so the watch app stays in `Watch` inside the iPhone app (`Embed Watch Content`, not `PlugIns`). The generated `WatchRemote.xcodeproj` is gitignored.
