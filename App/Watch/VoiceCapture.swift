import AVFoundation
import Foundation
import WatchConnectivity
import WatchRemoteCore

/// Records one utterance on the Watch and sends 16 kHz chunks to the iPhone.
/// Speech recognition stays on the iPhone: `SFSpeechRecognizer` is not in the watchOS SDK.
/// Call `start`, `stop`, and `requestPermission` on the main queue. The input tap hops back to main.
final class WatchVoiceCapture {
    var onPacket: ((VoicePacket) -> Void)?
    var onBegan: ((String) -> Void)?
    var onEnded: ((String) -> Void)?
    var onEmpty: (() -> Void)?
    var onPhase: ((String) -> Void)?
    var onFailed: (() -> Void)?

    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var startedAt: TimeInterval = 0
    private var detector = VoiceEndpointDetector()
    private var buffer = VoiceCaptureBuffer()
    private var utteranceID: String?
    private var sequence = 0

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            done(true)
        case .denied:
            done(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    done(granted)
                }
            }
        @unknown default:
            done(false)
        }
    }

    func start() {
        stop()
        detector = VoiceEndpointDetector()
        buffer = VoiceCaptureBuffer()
        utteranceID = nil
        sequence = 0
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                onFailed?()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcm, _ in
                let samples = Self.channelFloats(pcm)
                let rate = format.sampleRate
                DispatchQueue.main.async {
                    self?.ingest(samples, sampleRate: rate)
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            self.engine = engine
            isRunning = true
            startedAt = Date().timeIntervalSinceReferenceDate
            onPhase?("Listening")
        } catch {
            stop()
            onFailed?()
        }
    }

    func stop() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func ingest(_ samples: [Float], sampleRate: Double) {
        guard isRunning else { return }
        let now = Date().timeIntervalSinceReferenceDate - startedAt
        let wasSpeaking = detector.phase == .speaking
        let signal = detector.observe(rms: VoicePCM.rms(samples), at: now)
        if case .began = signal {
            let id = UUID().uuidString
            utteranceID = id
            sequence = 0
            onPhase?("Hearing you")
            onBegan?(id)
        }
        let hearing = wasSpeaking || detector.phase == .speaking
        let pcm = VoicePCM.int16(from: VoicePCM.resample(samples, from: sampleRate, to: Double(VoiceAudioFormat.sampleRate)))
        if let id = utteranceID {
            for chunk in buffer.append(pcm, hearingSpeech: hearing) {
                emit(id: id, samples: chunk, isLast: false)
            }
        } else {
            _ = buffer.append(pcm, hearingSpeech: false)
        }
        guard case .ended = signal else { return }
        let id = utteranceID
        let rest = buffer.finish()
        let sent = sequence
        stop()
        guard let id, !(rest.isEmpty && sent == 0) else {
            onEmpty?()
            return
        }
        emit(id: id, samples: rest, isLast: true)
        onEnded?(id)
    }

    private func emit(id: String, samples: [Int16], isLast: Bool) {
        if samples.isEmpty && !isLast { return }
        let packet = VoicePacket.audio(id: id, sequence: sequence, samples: samples, isLast: isLast)
        sequence += 1
        onPacket?(packet)
    }

    private static func channelFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        if let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: count))
        }
        if let channel = buffer.int16ChannelData {
            return (0..<count).map { Float(channel[0][$0]) / 32_767 }
        }
        return []
    }
}

enum WatchVoiceLink {
    @discardableResult
    static func send(_ packet: VoicePacket) -> Bool {
        guard WCSession.isSupported(), let text = VoiceWire.encode(packet) else { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return false }
        session.sendMessage(["voice": text], replyHandler: nil) { _ in }
        return true
    }
}

enum VoiceInbox {
    static var handler: ((String) -> Void)?
}
