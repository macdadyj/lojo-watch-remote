import AVFoundation
import SwiftUI
import WatchRemoteCore

enum VoicePreview {
    static let task = "Summarize the open changes"
}

@MainActor
final class VoicePreferences: ObservableObject {
    static let shared = VoicePreferences()

    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.set(autoSend, forKey: Keys.autoSend) }
    }

    @Published var readAloud: Bool {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: Keys.readAloud)
            if !readAloud {
                VoiceSpeaker.shared.stop()
            }
        }
    }

    private init() {
        autoSend = UserDefaults.standard.bool(forKey: Keys.autoSend)
        readAloud = UserDefaults.standard.bool(forKey: Keys.readAloud)
    }

    private enum Keys {
        static let autoSend = "watch.voice.autoSend"
        static let readAloud = "watch.voice.readAloud"
    }
}

/// Siri runs before the Watch model exists. The model takes the task when it comes up.
@MainActor
enum VoiceHandoff {
    static var handler: ((String) -> Void)?
    private static let key = "watch.voice.pendingTask"

    @discardableResult
    static func submit(_ raw: String) -> Bool {
        guard case .send(let prompt) = VoiceTaskPolicy.disposition(transcript: raw, autoSend: true) else {
            return false
        }
        if let handler {
            handler(prompt)
        } else {
            UserDefaults.standard.set(prompt, forKey: key)
        }
        return true
    }

    static func takePending() -> String? {
        let stored = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }
}

@MainActor
final class VoiceSpeaker {
    static let shared = VoiceSpeaker()
    private var synthesizer: AVSpeechSynthesizer?
    private var lastKey: String?

    func speakIfNeeded(previous: PhoneSnapshot, current: PhoneSnapshot, enabled: Bool) {
        guard enabled else { return }
        let includeNew = previous.mode == current.mode
        guard let result = VoiceResultPicker.latestResult(
            previous: previous.sessions,
            current: current.sessions,
            includeNew: includeNew
        ) else { return }
        say(sessionID: result.sessionID, text: result.text)
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
    }

    private func say(sessionID: String, text: String) {
        let key = sessionID + "\n" + text
        guard key != lastKey else { return }
        lastKey = key
        let speaker = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = speaker
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        speaker.speak(utterance)
    }
}

struct VoiceHomeSection: View {
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var preferences = VoicePreferences.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextFieldLink(prompt: Text("New task")) {
                VStack(spacing: 2) {
                    Image(systemName: "mic.fill")
                        .font(.title.weight(.bold))
                    Text("Speak")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LojoTheme.brandGradient)
                )
            } onSubmit: { text in
                model.acceptDictation(text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictate a task")
            .accessibilityHint("Starts dictation and sends the text as a new task to the active computer.")

            Toggle(isOn: $preferences.autoSend) {
                Text("Auto-send")
                    .font(.caption2)
            }
            .accessibilityHint("Sends a dictated task without asking. Off until you turn it on.")

            Toggle(isOn: $preferences.readAloud) {
                Text("Read results aloud")
                    .font(.caption2)
            }
            .accessibilityHint("Speaks the latest finished result. Off until you turn it on.")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background {
            insetFill.ignoresSafeArea(edges: .bottom)
        }
    }

    private var insetFill: Color {
        switch scheme {
        case .light:
            return Color(red: 0.95, green: 0.95, blue: 0.96)
        case .dark:
            return .black
        @unknown default:
            return .black
        }
    }
}

struct VoiceConfirmView: View {
    var transcript: String
    var isPreview: Bool
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send this task?")
                    .font(.headline)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .padding(.top, 12)
                Text(transcript)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Task")
                    .accessibilityValue(transcript)
                Button("Send") { send() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .accessibilityHint("Sends the task to the active computer")
                Button("Cancel") { cancel() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                if !isPreview, let banner = model.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("New task")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
    }

    private func send() {
        guard !isPreview else { return }
        let text = transcript
        model.pendingDictation = nil
        if model.start(text) {
            WatchFeedback.success()
        }
    }

    private func cancel() {
        guard !isPreview else { return }
        model.pendingDictation = nil
    }
}

struct VoiceApprovalMic: View {
    var session: GrokSession
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            TextFieldLink(prompt: Text("Allow, deny, or stop")) {
                Label("Voice", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { text in
                model.acceptApprovalVoice(text, session: session)
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .accessibilityLabel("Voice command")
            .accessibilityHint("Say allow, deny, or stop. Allow waits for a tap.")

            if model.pendingAllowSessionID == session.id {
                Button("Tap to allow") {
                    WatchFeedback.success()
                    model.confirmPendingAllow(session)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityLabel("Tap to allow")
                .accessibilityHint("Confirms the spoken allow")
            }

            if model.voiceNoteSessionID == session.id, let note = model.voiceNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension WatchModel {
    func acceptDictation(_ transcript: String) {
        switch VoiceTaskPolicy.disposition(transcript: transcript, autoSend: VoicePreferences.shared.autoSend) {
        case .ignore:
            return
        case .confirm(let prompt):
            pendingDictation = prompt
            WatchFeedback.click()
        case .send(let prompt):
            pendingDictation = nil
            if start(prompt) {
                WatchFeedback.success()
            }
        }
    }

    /// Siri already named the task. Send it on the iPhone path or the direct relay, whichever is up.
    func submitSpokenTask(_ transcript: String) {
        guard forcedScreen == nil else { return }
        switch VoiceTaskPolicy.disposition(transcript: transcript, autoSend: true) {
        case .ignore:
            return
        case .confirm(let prompt), .send(let prompt):
            heldVoiceTask = prompt
            flushHeldVoiceTask(announcingFailure: false)
        }
    }

    func flushHeldVoiceTask(announcingFailure: Bool = true) {
        guard forcedScreen == nil, let prompt = heldVoiceTask else { return }
        if start(prompt, announcingFailure: announcingFailure) {
            heldVoiceTask = nil
            WatchFeedback.success()
        }
    }

    func acceptApprovalVoice(_ transcript: String, session: GrokSession) {
        switch VoiceCommandMatcher.approvalEffect(for: transcript) {
        case .confirmAllow:
            pendingAllowSessionID = session.id
            voiceNote = nil
            voiceNoteSessionID = nil
            WatchFeedback.notification()
        case .deny:
            pendingAllowSessionID = nil
            voiceNote = nil
            voiceNoteSessionID = nil
            WatchFeedback.failure()
            deny(session)
        case .stop:
            pendingAllowSessionID = nil
            voiceNote = nil
            voiceNoteSessionID = nil
            WatchFeedback.click()
            stop(session)
        case .unrecognized:
            voiceNoteSessionID = session.id
            voiceNote = "Say allow, deny, or stop."
        }
    }

    func confirmPendingAllow(_ session: GrokSession) {
        guard pendingAllowSessionID == session.id else { return }
        pendingAllowSessionID = nil
        voiceNote = nil
        voiceNoteSessionID = nil
        allow(session)
    }
}
