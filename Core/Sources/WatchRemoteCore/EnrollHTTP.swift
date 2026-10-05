import Foundation

/// The bytes for `POST /v1/enroll`. The phone sends these on a plain TCP socket.
/// `URLSession` cleartext is blocked by App Transport Security for 100.64.0.0/10.
public enum EnrollHTTP {
    public struct Response: Equatable, Sendable {
        public var status: Int
        public var body: String
    }

    public static func request(host: String, port: Int, ticket: String, publicKey: String) -> Data? {
        guard (1...65535).contains(port), isHeaderToken(host), isHeaderToken(ticket) else { return nil }
        let body = Data(publicKey.utf8)
        guard (1...2048).contains(body.count) else { return nil }
        let head = [
            "POST /v1/enroll HTTP/1.1",
            "Host: \(host):\(port)",
            "Authorization: Bearer \(ticket)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func response(from data: Data) -> Response? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let split: (headers: Substring, body: Substring)?
        if let range = text.range(of: "\r\n\r\n") {
            split = (text[..<range.lowerBound], text[range.upperBound...])
        } else if let range = text.range(of: "\n\n") {
            split = (text[..<range.lowerBound], text[range.upperBound...])
        } else {
            split = nil
        }
        guard let split else { return nil }
        let statusLine = split.headers.split(whereSeparator: \.isNewline).first ?? ""
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]), (100...599).contains(status) else { return nil }
        return Response(status: status, body: String(split.body))
    }

    private static func isHeaderToken(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        return text.allSatisfy { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            let value = scalar.value
            return value >= 0x21 && value <= 0x7E
        }
    }
}
