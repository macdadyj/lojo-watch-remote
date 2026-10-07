import SwiftUI
import WatchRemoteCore

extension WatchModel {
    var listenModeTitle: String {
        ListenEndpoint.title(pauseSends: VoicePreferences.shared.pauseSends)
    }

    var isManualListenActive: Bool {
        capture.isRunning || capture.isSuspended || systemPausedListen
            || voiceStatus == "Listening" || voiceStatus == "Hearing you"
    }

    /// Action Button and the on-screen Action Button control. Speak starts. A second press sends.
    func toggleFromActionButton() {
        if voiceStatus == "Sending" || voiceStatus == "Speaking" {
            return
        }
        if isManualListenActive {
            stopTalking()
            return
        }
        beginHandsFreeVoice()
    }

    func applyListenChrome() {
        let pause = VoicePreferences.shared.pauseSends
        voiceStatus = "Listening"
        let hints = [
            "",
            VoiceSpeechCopy.listeningHint,
            ListenEndpoint.manualHint,
            VoiceSpeechCopy.waitingForPhone,
            ListenEndpoint.waitingManual,
        ]
        if hints.contains(voiceLine) {
            voiceLine = ListenEndpoint.hint(pauseSends: pause)
        }
    }

    func retainRuntime() {
        guard !uiTest else { return }
        ListenRuntime.shared.begin { [weak self] in
            guard let self, !self.appIsActive else { return }
            self.pauseListenKeepingAudio()
        }
    }

    /// Wrist down, dimming, and background do not end the chat or the relay.
    /// A running extended session keeps the microphone. Otherwise the samples stay put.
    func holdThroughWristDown() {
        guard isManualListenActive else { return }
        if ListenRuntime.shared.isRunning && capture.isRunning {
            return
        }
        pauseListenKeepingAudio()
    }

    func pauseListenKeepingAudio() {
        guard capture.isRunning || capture.isSuspended else {
            if voiceStatus == "Listening" || voiceStatus == "Hearing you" {
                systemPausedListen = true
            }
            return
        }
        if capture.isRunning {
            capture.suspendKeepingAudio()
        }
        systemPausedListen = true
    }

    func resumeAfterWristUp() {
        guard systemPausedListen || capture.isSuspended else { return }
        guard voiceModeActive || isManualListenActive else {
            systemPausedListen = false
            return
        }
        systemPausedListen = false
        voiceStatus = "Listening"
        if capture.isSuspended {
            capture.resume()
        }
    }

    /// Pause mode listens again. Manual mode waits for Speak or the Action Button.
    func relinquishListen(status: String) {
        if VoicePreferences.shared.pauseSends {
            voiceStatus = status == "Paused" ? "Listening" : status
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.armListener()
            }
            return
        }
        ListenRuntime.shared.end()
        voiceStatus = status == "Listening" ? "Sent" : status
    }

    func scheduleUICap() {
        guard uiTest, uiMaxListen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.voiceStatus == "Listening" else { return }
            self.stopTalking()
        }
    }

    func simulateWristDown() {
        guard uiTest else { return }
        wristDown = true
        appIsActive = false
        holdThroughWristDown()
        let send = RelayUserNotice.banner(for: .dataSendFailed, displayOff: true)
        let suspended = RelayUserNotice.banner(for: .suspended, displayOff: true)
        let shown = send ?? suspended
        if shown == RelayUserNotice.pairingRejectedText {
            banner = shown
        } else if banner == RelayUserNotice.pairingRejectedText {
            banner = nil
        }
    }

    func simulateWristUp() {
        guard uiTest else { return }
        wristDown = false
        appIsActive = true
        if banner == RelayUserNotice.reconnectingText || banner == RelayUserNotice.pairingRejectedText {
            banner = banner == RelayUserNotice.pairingRejectedText ? banner : nil
        }
        resumeAfterWristUp()
    }
}

struct ListenTestHooks: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        if model.uiShowHooks {
            Button(model.wristDown ? "Wrist up" : "Wrist down") {
                if model.wristDown {
                    model.simulateWristUp()
                } else {
                    model.simulateWristDown()
                }
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .accessibilityIdentifier("voice.wrist")
        }
    }
}
