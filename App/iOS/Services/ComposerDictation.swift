import AVFoundation
import Foundation
import Speech
import WatchRemoteCore

/// Gives the keyboard back to system dictation whenever this app is not recording.
enum ComposerSpeech {
    static func releaseIdleSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// On-device transcription into a text field. System keyboard dictation stays available
/// because the audio session is active only while this button is listening.
@MainActor
final class ComposerDictation: ObservableObject {
    @Published private(set) var listening = false
    /// Shown under the button when dictation cannot start, instead of failing silently.
    @Published private(set) var problem: String?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?
    private var typed = ""
    private var scripted: Task<Void, Never>?

    static let deniedText = "Allow Microphone and Speech Recognition for WatchRemote in Settings."
    static let unavailableText = "Speech recognition is not available right now."
    static let micText = "The microphone did not start. Try again."

    /// UI tests cannot speak into the simulator, so they hand the words in at launch.
    private static var scriptedWords: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-WatchRemoteDictation"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return ProcessInfo.processInfo.environment["WATCHREMOTE_DICTATION"]
    }

    /// Starts or stops listening. Spoken words are added after `typed`, never in place of it.
    func toggle(appendingTo typed: String, _ onUpdate: @escaping (String) -> Void) {
        if listening {
            stop()
            return
        }
        problem = nil
        self.typed = typed
        self.onUpdate = onUpdate
        if let words = Self.scriptedWords {
            playScript(words)
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.onUpdate != nil else { return }
                guard status == .authorized else {
                    self.fail(Self.deniedText)
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard self.onUpdate != nil else { return }
                        guard granted else {
                            self.fail(Self.deniedText)
                            return
                        }
                        self.begin(attempt: 0)
                    }
                }
            }
        }
    }

    func stop() {
        scripted?.cancel()
        scripted = nil
        haltCapture()
        onUpdate = nil
        listening = false
        ComposerSpeech.releaseIdleSession()
    }

    private func fail(_ message: String) {
        stop()
        problem = message
    }

    private func deliver(_ spoken: String) {
        guard !spoken.isEmpty else { return }
        onUpdate?(DictationText.merge(typed: typed, spoken: spoken))
    }

    private func playScript(_ words: String) {
        listening = true
        scripted = Task { [weak self] in
            let parts = words.split(separator: " ")
            for count in 1...max(parts.count, 1) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled, self.listening else { return }
                self.deliver(parts.prefix(count).joined(separator: " "))
            }
            self?.stop()
        }
    }

    private func haltCapture() {
        task?.cancel()
        task = nil
        let engine = engine
        let request = request
        self.engine = nil
        self.request = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
    }

    /// Right after the permission prompt, or while a sheet is still animating in, the input
    /// node can report a zero sample rate. A short retry gets a live microphone.
    private func begin(attempt: Int) {
        let update = onUpdate
        haltCapture()
        onUpdate = update
        guard let recognizer, recognizer.isAvailable else {
            fail(Self.unavailableText)
            return
        }
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        var tapped = false
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CocoaError(.featureUnsupported)
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapped = true
            engine.prepare()
            try engine.start()
        } catch {
            if tapped {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            guard attempt < 3 else {
                fail(Self.micText)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.onUpdate != nil, !self.listening else { return }
                self.begin(attempt: attempt + 1)
            }
            return
        }
        self.engine = engine
        self.request = request
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString ?? ""
            let finished = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.deliver(spoken)
                if finished {
                    self.stop()
                }
            }
        }
    }
}
