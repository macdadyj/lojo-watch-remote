import Foundation

/// Hands-free watch speech.
///
/// watchOS does not ship `SFSpeechRecognizer` or `SpeechAnalyzer` / `SpeechTranscriber`
/// (Xcode 26 availability: iOS, macOS, tvOS, visionOS — not watchOS). The system dictation
/// sheet is the only on-watch transcriber, and it always waits for Done.
/// The watch records with `AVAudioEngine`, this type decides when speech ended, and the
/// iPhone transcribes the utterance.
public enum VoiceAudioFormat {
    public static let sampleRate = 16_000
}

public enum VoiceSpeechCopy {
    public static let denied = "Speech recognition is off on the iPhone."
    public static let unavailable = "Speech recognition is unavailable on the iPhone."
    public static let phoneAway = "Hands-free needs the iPhone app open. Tap Done after you speak."
    public static let micDenied = "Allow the microphone in Settings on the Watch."
    public static let micUnavailable = "Microphone is unavailable. Tap Done after you speak."
    public static let waiting = "Allow speech recognition on the iPhone, then speak again."
    public static let missed = "Didn't catch that."
    public static let listeningHint = "Listening. A pause sends what you said."
    public static let handsFreeRule = "Hands-free. A pause sends. Done is not used."
    public static let approvalRule = "Deny and stop send on the first word. Allow waits for yes."
}

public enum VoicePCM {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Linear resample. Matching rates return the input. Empty input or a non-positive rate returns empty.
    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate > 0, outputRate > 0, !samples.isEmpty else { return [] }
        if abs(inputRate - outputRate) < 0.5 { return samples }
        let ratio = outputRate / inputRate
        let count = max(Int((Double(samples.count) * ratio).rounded(.down)), 1)
        var output: [Float] = []
        output.reserveCapacity(count)
        let last = samples.count - 1
        for index in 0..<count {
            let position = Double(index) / ratio
            let left = min(Int(position), last)
            let right = min(left + 1, last)
            let fraction = Float(position - Double(left))
            let mixed = samples[left] * (1 - fraction) + samples[right] * fraction
            output.append(mixed)
        }
        return output
    }

    public static func int16(from samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = min(1, max(-1, sample))
            let scaled = (clamped * 32_767).rounded()
            return Int16(scaled)
        }
    }

    public static func floats(from samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32_767 }
    }

    public static func base64(_ samples: [Int16]) -> String {
        littleEndian(samples).base64EncodedString()
    }

    public static func samples(base64 text: String) -> [Int16]? {
        guard let data = Data(base64Encoded: text) else { return nil }
        return int16LittleEndian(data)
    }

    public static func littleEndian(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func int16LittleEndian(_ data: Data) -> [Int16] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var output: [Int16] = []
            output.reserveCapacity(count)
            for index in 0..<count {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                output.append(Int16(bitPattern: low | high))
            }
            return output
        }
    }
}

public struct VoiceEndpointDetector: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        public var threshold: Float
        public var onset: TimeInterval
        public var silence: TimeInterval
        public var minimumSpeech: TimeInterval
        public var maximumSpeech: TimeInterval

        public init(
            threshold: Float,
            onset: TimeInterval,
            silence: TimeInterval,
            minimumSpeech: TimeInterval,
            maximumSpeech: TimeInterval
        ) {
            self.threshold = threshold
            self.onset = onset
            self.silence = silence
            self.minimumSpeech = minimumSpeech
            self.maximumSpeech = maximumSpeech
        }

        /// Short commands such as yes, no, deny, and stop. A pause of `silence` ends the turn.
        public static let handsFree = Configuration(
            threshold: 0.015,
            onset: 0.08,
            silence: 0.65,
            minimumSpeech: 0.18,
            maximumSpeech: 12
        )
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case speaking
    }

    public enum Reason: Equatable, Sendable {
        case silence
        case maximum
    }

    public enum Signal: Equatable, Sendable {
        case began
        case ended(Reason)
    }

    public var configuration: Configuration
    public private(set) var phase: Phase = .idle
    private var onsetStart: TimeInterval?
    private var speechStart: TimeInterval?
    private var lastLoud: TimeInterval?

    public init(configuration: Configuration = .handsFree) {
        self.configuration = configuration
    }

    /// `time` is seconds from the start of this listen, and it must not go backwards.
    public mutating func observe(rms: Float, at time: TimeInterval) -> Signal? {
        let loud = rms >= configuration.threshold
        switch phase {
        case .idle:
            guard loud else {
                onsetStart = nil
                return nil
            }
            if onsetStart == nil {
                onsetStart = time
            }
            guard let start = onsetStart, time - start >= configuration.onset else { return nil }
            phase = .speaking
            speechStart = start
            lastLoud = time
            onsetStart = nil
            return .began
        case .speaking:
            if loud {
                lastLoud = time
            }
            if let speechStart, time - speechStart >= configuration.maximumSpeech {
                reset()
                return .ended(.maximum)
            }
            if let lastLoud, let speechStart,
               time - lastLoud >= configuration.silence,
               time - speechStart >= configuration.minimumSpeech {
                reset()
                return .ended(.silence)
            }
            return nil
        }
    }

    private mutating func reset() {
        phase = .idle
        onsetStart = nil
        speechStart = nil
        lastLoud = nil
    }
}

public enum VoiceHandsFreePolicy {
    /// The utterance is sent when speech ends. The watch does not wait for Done.
    public static func shouldSend(after signal: VoiceEndpointDetector.Signal) -> Bool {
        switch signal {
        case .began:
            return false
        case .ended:
            return true
        }
    }
}

/// Keeps a short pre-roll so the first consonant is not clipped, and emits fixed-size chunks after speech starts.
public struct VoiceCaptureBuffer: Equatable, Sendable {
    public let prerollFrames: Int
    public let chunkFrames: Int
    public private(set) var speaking = false
    private var ring: [Int16] = []
    private var held: [Int16] = []

    public init(prerollFrames: Int = 4_800, chunkFrames: Int = 3_200) {
        self.prerollFrames = prerollFrames
        self.chunkFrames = chunkFrames
    }

    public mutating func append(_ samples: [Int16], hearingSpeech: Bool) -> [[Int16]] {
        guard !samples.isEmpty else { return [] }
        if hearingSpeech {
            if !speaking {
                speaking = true
                held.append(contentsOf: ring)
                ring.removeAll(keepingCapacity: true)
            }
            held.append(contentsOf: samples)
            return drain()
        }
        ring.append(contentsOf: samples)
        if ring.count > prerollFrames {
            ring.removeFirst(ring.count - prerollFrames)
        }
        return []
    }

    public mutating func finish() -> [Int16] {
        let rest = held
        held.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        speaking = false
        return rest
    }

    private mutating func drain() -> [[Int16]] {
        guard chunkFrames > 0 else { return [] }
        var chunks: [[Int16]] = []
        while held.count >= chunkFrames {
            chunks.append(Array(held.prefix(chunkFrames)))
            held.removeFirst(chunkFrames)
        }
        return chunks
    }
}

public struct VoicePacket: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case prepare
        case ready
        case audio
        case transcript
        case failure
    }

    public var kind: Kind
    public var utteranceID: String
    public var sequence: Int
    public var sampleRate: Int
    public var isLast: Bool
    public var text: String
    public var pcmBase64: String

    public init(
        kind: Kind,
        utteranceID: String,
        sequence: Int = 0,
        sampleRate: Int = VoiceAudioFormat.sampleRate,
        isLast: Bool = false,
        text: String = "",
        pcmBase64: String = ""
    ) {
        self.kind = kind
        self.utteranceID = utteranceID
        self.sequence = sequence
        self.sampleRate = sampleRate
        self.isLast = isLast
        self.text = text
        self.pcmBase64 = pcmBase64
    }

    public static func prepare(_ id: String) -> VoicePacket {
        VoicePacket(kind: .prepare, utteranceID: id)
    }

    public static func audio(id: String, sequence: Int, samples: [Int16], isLast: Bool) -> VoicePacket {
        VoicePacket(
            kind: .audio,
            utteranceID: id,
            sequence: sequence,
            isLast: isLast,
            pcmBase64: VoicePCM.base64(samples)
        )
    }
}

public enum VoiceWire {
    public static func encode(_ packet: VoicePacket) -> String? {
        let data = try? JSONEncoder().encode(packet)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ text: String) -> VoicePacket? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VoicePacket.self, from: data)
    }
}

public enum VoiceTranscriptGate {
    /// Partials update the screen. Only a final, non-empty transcript becomes a command.
    public static func commandText(_ text: String, isFinal: Bool) -> String? {
        guard isFinal else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }
}
