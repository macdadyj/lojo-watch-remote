import AVFoundation
import Combine
import WatchRemoteCore

/// The iPhone's copy of "read replies aloud". Off until turned on, and remembered.
@MainActor
final class PhoneSpeechPreference: ObservableObject {
    static let shared = PhoneSpeechPreference()

    @Published var readReplies: Bool {
        didSet {
            UserDefaults.standard.set(readReplies, forKey: Self.key)
            if !readReplies {
                PhoneReplySpeaker.shared.stop()
            }
        }
    }

    private static let key = "phone.speakReplies"

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.key) == nil {
            readReplies = ReplySpeech.phoneDefault
        } else {
            readReplies = defaults.bool(forKey: Self.key)
        }
    }
}

/// Speaks one finished Grok reply. A repeat of the same line is skipped.
@MainActor
final class PhoneReplySpeaker {
    static let shared = PhoneReplySpeaker()
    private let synthesizer = AVSpeechSynthesizer()
    private var lastKey = ""

    func speak(_ text: String, dedupeKey: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dedupeKey != lastKey else { return }
        lastKey = dedupeKey
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        lastKey = ""
        synthesizer.stopSpeaking(at: .immediate)
    }
}
