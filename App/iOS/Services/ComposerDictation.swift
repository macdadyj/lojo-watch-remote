import AVFoundation
import Foundation
import Speech

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
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?

    func toggle(_ onUpdate: @escaping (String) -> Void) {
        if listening {
            stop()
            return
        }
        self.onUpdate = onUpdate
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.stop()
                    return
                }
                self.begin()
            }
        }
    }

    func stop() {
        haltCapture()
        onUpdate = nil
        listening = false
        ComposerSpeech.releaseIdleSession()
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

    private func begin() {
        let update = onUpdate
        haltCapture()
        onUpdate = update
        guard let recognizer, recognizer.isAvailable else {
            stop()
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
                ComposerSpeech.releaseIdleSession()
                return
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
            ComposerSpeech.releaseIdleSession()
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
                if !spoken.isEmpty {
                    self.onUpdate?(spoken)
                }
                if finished {
                    self.stop()
                }
            }
        }
    }
}
