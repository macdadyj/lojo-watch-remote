import Foundation

/// Names of the checked-in speech clips the Watch UI tests inject.
/// The microphone stays off. A clip name maps to the transcript the mock host should hear.
public enum VoiceTestClips {
    public static let pauseTask = "pause-task"
    public static let noPause = "no-pause"
    public static let yes = "yes"
    public static let no = "no"

    public static func transcript(forClip name: String) -> String? {
        switch name {
        case pauseTask:
            return "list sessions"
        case noPause:
            return "keep going without a pause"
        case yes:
            return "yes"
        case no:
            return "no"
        default:
            return nil
        }
    }
}

/// Stand-in for the computer. UI tests never open SSH or the public relay.
public enum VoiceTestHost {
    public static let mode = "mock"

    public static func reply(to transcript: String) -> String {
        switch transcript {
        case "yes":
            return "Allowed."
        case "no":
            return "Denied."
        default:
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Heard nothing."
            }
            return "Heard \(trimmed)"
        }
    }
}

/// Reads a PCM WAV so a test can feed samples without a microphone.
public enum VoiceWAV {
    public static func monoFloats(data: Data) -> [Float]? {
        guard data.count >= 12 else { return nil }
        guard ascii(data, 0, count: 4) == "RIFF", ascii(data, 8, count: 4) == "WAVE" else { return nil }
        var offset = 12
        var audioFormat: UInt16 = 0
        var channels: UInt16 = 0
        var bits: UInt16 = 0
        var sampleRate: UInt32 = 0
        var dataOffset: Int?
        var dataCount: Int?
        while offset + 8 <= data.count {
            let chunkID = ascii(data, offset, count: 4)
            let size = Int(u32(data, offset + 4))
            let start = offset + 8
            if size < 0 || start > data.count || size > data.count - start { return nil }
            if chunkID == "fmt ", size >= 16 {
                audioFormat = u16(data, start)
                channels = u16(data, start + 2)
                sampleRate = u32(data, start + 4)
                bits = u16(data, start + 14)
            } else if chunkID == "data" {
                dataOffset = start
                dataCount = size
            }
            let padded = size + (size % 2)
            offset = start + padded
        }
        guard (audioFormat == 1 || audioFormat == 3), channels > 0, sampleRate > 0 else { return nil }
        guard let dataOffset, let dataCount, dataCount > 0 else { return nil }
        let end = dataOffset + dataCount
        guard end <= data.count else { return nil }
        let bytes = data.subdata(in: dataOffset..<end)
        if audioFormat == 3, bits == 32 {
            return floats32(bytes, channels: Int(channels))
        }
        guard audioFormat == 1, bits == 16 else { return nil }
        return ints16(bytes, channels: Int(channels))
    }

    private static func ascii(_ data: Data, _ offset: Int, count: Int) -> String {
        let slice = data.subdata(in: offset..<(offset + count))
        return String(data: slice, encoding: .ascii) ?? ""
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | (UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for shift in 0..<4 {
            let byte = UInt32(data[data.index(data.startIndex, offsetBy: offset + shift)])
            value |= byte << (UInt32(shift) * 8)
        }
        return value
    }

    private static func ints16(_ data: Data, channels: Int) -> [Float]? {
        let frame = channels * 2
        guard frame > 0, data.count >= frame else { return nil }
        let frames = data.count / frame
        var output: [Float] = []
        output.reserveCapacity(frames)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for frameIndex in 0..<frames {
                let index = frameIndex * frame
                let low = UInt16(base[index])
                let high = UInt16(base[index + 1]) << 8
                let bits = Int16(bitPattern: low | high)
                output.append(Float(bits) / 32768)
            }
        }
        return output.isEmpty ? nil : output
    }

    private static func floats32(_ data: Data, channels: Int) -> [Float]? {
        let frame = channels * 4
        guard frame > 0, data.count >= frame else { return nil }
        let frames = data.count / frame
        var output: [Float] = []
        output.reserveCapacity(frames)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for frameIndex in 0..<frames {
                var bits: UInt32 = 0
                let index = frameIndex * frame
                for shift in 0..<4 {
                    bits |= UInt32(base[index + shift]) << (UInt32(shift) * 8)
                }
                output.append(Float(bitPattern: bits))
            }
        }
        return output.isEmpty ? nil : output
    }
}
