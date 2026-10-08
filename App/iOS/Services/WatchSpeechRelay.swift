import AVFoundation
import Foundation
import Speech
import WatchConnectivity
import WatchRemoteCore

/// Transcribes a watch utterance. `SpeechAnalyzer` is not available on watchOS, so recognition runs here.
final class WatchSpeechRelay {
    static let shared = WatchSpeechRelay()

    private let queue = DispatchQueue(label: "watch.speech.relay")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var active: ActiveUtterance?

    private final class ActiveUtterance {
        let id: String
        let request: SFSpeechAudioBufferRecognitionRequest
        let format: AVAudioFormat
        var task: SFSpeechRecognitionTask?
        var latest = ""
        var sentPartial = ""
        var lastPartial: Date?
        var ending = false
        var finished = false

        init(id: String, request: SFSpeechAudioBufferRecognitionRequest, format: AVAudioFormat) {
            self.id = id
            self.request = request
            self.format = format
        }
    }

    func accept(_ text: String) {
        guard let packet = VoiceWire.decode(text) else { return }
        switch packet.kind {
        case .prepare:
            DispatchQueue.main.async { [weak self] in
                self?.prepare(packet)
            }
        case .audio:
            queue.async { [weak self] in
                self?.append(packet)
            }
        case .ready, .transcript, .failure:
            return
        }
    }

    private func prepare(_ packet: VoicePacket) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized:
                self.sendReady(packet.utteranceID)
            case .denied, .restricted, .notDetermined:
                self.send(VoicePacket(kind: .failure, utteranceID: packet.utteranceID, text: VoiceSpeechCopy.denied))
            @unknown default:
                self.send(VoicePacket(kind: .failure, utteranceID: packet.utteranceID, text: VoiceSpeechCopy.denied))
            }
        }
    }

    private func sendReady(_ id: String) {
        guard let recognizer, recognizer.isAvailable else {
            send(VoicePacket(kind: .failure, utteranceID: id, text: VoiceSpeechCopy.unavailable))
            return
        }
        let mode = recognizer.supportsOnDeviceRecognition ? "on-device" : "network"
        send(VoicePacket(kind: .ready, utteranceID: id, text: mode))
    }

    private func append(_ packet: VoicePacket) {
        if active?.id != packet.utteranceID {
            finishActive(text: active?.latest ?? "", sendTranscript: false)
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(packet.sampleRate),
                channels: 1,
                interleaved: false
            ), packet.sampleRate > 0, let recognizer, recognizer.isAvailable else {
                send(VoicePacket(kind: .failure, utteranceID: packet.utteranceID, text: VoiceSpeechCopy.unavailable))
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Prefer on-device when the model is installed. Requiring it fails the task
            // when the asset is missing, and that failure used to open the Watch dictation sheet.
            request.requiresOnDeviceRecognition = false
            let created = ActiveUtterance(id: packet.utteranceID, request: request, format: format)
            active = created
            created.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.queue.async {
                    self?.consume(id: packet.utteranceID, result: result, error: error)
                }
            }
        }
        guard let active, active.id == packet.utteranceID, !active.finished else { return }
        if let samples = VoicePCM.samples(base64: packet.pcmBase64), !samples.isEmpty {
            append(VoicePCM.floats(from: samples), to: active)
        }
        guard packet.isLast else { return }
        active.ending = true
        active.request.endAudio()
        let id = active.id
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, let active = self.active, active.id == id else { return }
            self.finishActive(text: active.latest, sendTranscript: true)
        }
    }

    private func append(_ samples: [Float], to active: ActiveUtterance) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: active.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        active.request.append(buffer)
    }

    private func consume(id: String, result: SFSpeechRecognitionResult?, error: Error?) {
        guard let active, active.id == id, !active.finished else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            active.latest = text
            if result.isFinal {
                finishActive(text: text, sendTranscript: true)
                return
            }
            let now = Date()
            let due = active.lastPartial.map { now.timeIntervalSince($0) >= 0.35 } ?? true
            if due, text != active.sentPartial, !text.isEmpty {
                active.lastPartial = now
                active.sentPartial = text
                send(VoicePacket(kind: .transcript, utteranceID: id, isLast: false, text: text))
            }
            return
        }
        if let error {
            let ns = error as NSError
            let missed = VoiceFailureClassifier.kind(domain: ns.domain, code: ns.code) == .missed
            if missed || active.ending || !active.latest.isEmpty {
                finishActive(text: active.latest, sendTranscript: true)
            } else {
                let id = active.id
                finishActive(text: "", sendTranscript: false)
                send(VoicePacket(kind: .failure, utteranceID: id, text: VoiceSpeechCopy.unavailable))
            }
        }
    }

    private func finishActive(text: String, sendTranscript: Bool) {
        guard let current = active, !current.finished else { return }
        current.finished = true
        current.task?.cancel()
        let id = current.id
        active = nil
        DispatchQueue.main.async {
            ComposerSpeech.releaseIdleSession()
        }
        guard sendTranscript else { return }
        send(VoicePacket(kind: .transcript, utteranceID: id, isLast: true, text: text))
    }

    private func send(_ packet: VoicePacket) {
        guard WCSession.isSupported(), let text = VoiceWire.encode(packet) else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["voice": text], replyHandler: nil) { _ in }
    }
}
