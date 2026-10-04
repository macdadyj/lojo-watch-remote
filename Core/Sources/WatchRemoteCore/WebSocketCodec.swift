import Foundation

public struct WebSocketFrame: Equatable, Sendable {
    public enum Opcode: Int, Sendable {
        case continuation = 0
        case text = 1
        case binary = 2
        case close = 8
        case ping = 9
        case pong = 10
    }

    public var opcode: Opcode
    public var payload: Data

    public init(opcode: Opcode, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }
}

/// Minimal RFC 6455 codec. Client frames are masked. Server frames are not.
public struct WebSocketFramer {
    private var buffer = Data()

    public init() {}

    public static func upgradeRequest(host: String, path: String, webSocketKey: String) -> Data {
        let text = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(webSocketKey)",
            "Sec-WebSocket-Version: 13",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(text.utf8)
    }

    public static func acceptsUpgrade(_ header: String) -> Bool {
        let folded = header.lowercased()
        return folded.contains("101") && folded.contains("upgrade") && folded.contains("websocket")
    }

    public static func encodeClientText(_ text: String, mask: [UInt8]) -> Data {
        encode(opcode: .text, payload: Data(text.utf8), mask: mask)
    }

    public static func encodeClientPong(_ payload: Data, mask: [UInt8]) -> Data {
        encode(opcode: .pong, payload: payload, mask: mask)
    }

    public mutating func append(_ data: Data) -> [WebSocketFrame] {
        buffer.append(data)
        var frames: [WebSocketFrame] = []
        while let frame = nextFrame() {
            frames.append(frame)
        }
        return frames
    }

    public static func percentEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private mutating func nextFrame() -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let opcodeByte = buffer[buffer.startIndex] & 0x0f
        let lengthMarker = Int(buffer[buffer.index(after: buffer.startIndex)] & 0x7f)
        var offset = 2
        let length: Int
        if lengthMarker == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            offset = 4
        } else if lengthMarker == 127 {
            guard buffer.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 2..<10 {
                value = (value << 8) | UInt64(buffer[buffer.startIndex + index])
            }
            guard value <= UInt64(Int.max) else { return nil }
            length = Int(value)
            offset = 10
        } else {
            length = lengthMarker
        }
        guard buffer.count >= offset + length else { return nil }
        let payload = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + length))
        buffer.removeFirst(offset + length)
        guard let opcode = WebSocketFrame.Opcode(rawValue: Int(opcodeByte)) else {
            return WebSocketFrame(opcode: .binary, payload: payload)
        }
        return WebSocketFrame(opcode: opcode, payload: payload)
    }

    private static func encode(opcode: WebSocketFrame.Opcode, payload: Data, mask: [UInt8]) -> Data {
        precondition(mask.count == 4)
        var frame = Data()
        frame.append(0x80 | UInt8(opcode.rawValue))
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((count >> 8) & 0xff))
            frame.append(UInt8(count & 0xff))
        } else {
            frame.append(0x80 | 127)
            var remaining = count
            var bytes = [UInt8](repeating: 0, count: 8)
            for index in stride(from: 7, through: 0, by: -1) {
                bytes[index] = UInt8(remaining & 0xff)
                remaining >>= 8
            }
            frame.append(contentsOf: bytes)
        }
        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }
        return frame
    }
}

public enum RelayPin {
    public static func matches(certificateSHA256 digest: Data, pinnedHex: String) -> Bool {
        let expected = pinnedHex.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected.count == actual.count else { return false }
        return expected == actual
    }

    public static func authorizationHeader(token: String) -> String {
        "Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
