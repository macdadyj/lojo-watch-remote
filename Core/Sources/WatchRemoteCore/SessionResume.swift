import Foundation

/// Turns a `session/load` result into lines the Watch can show.
/// The list check uses `_x.ai/session/list` before this runs.
public enum SessionResume {
    public static let missingMessage = "That chat is no longer on this computer."
    public static let unsupportedMessage = "This connection cannot reopen that chat."

    public static func displayLines(title: String, summary: String, transcript: [String]) -> [String] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = transcript
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            var lines = Array(cleaned.suffix(24))
            if !trimmedTitle.isEmpty, !lines.contains(trimmedTitle) {
                lines.insert(trimmedTitle, at: 0)
            }
            return lines
        }
        var lines: [String] = []
        if !trimmedTitle.isEmpty {
            lines.append(trimmedTitle)
        }
        if !trimmedSummary.isEmpty, trimmedSummary != trimmedTitle {
            lines.append(trimmedSummary)
        }
        if lines.isEmpty {
            lines.append("Session")
        }
        return lines
    }

    /// Spoken lines from a JSON-RPC `session/load` body. Empty when the payload has none.
    public static func transcriptLines(inLoadJSON text: String) -> [String] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return Array(lines(in: json).prefix(8))
    }

    private static func lines(in json: Any) -> [String] {
        var root = json
        if let object = json as? [String: Any], let result = object["result"] {
            root = result
        }
        return messageRows(in: root).compactMap(line(from:))
    }

    private static func messageRows(in root: Any) -> [Any] {
        if let rows = root as? [Any] {
            return rows
        }
        guard let object = root as? [String: Any] else { return [] }
        for key in ["messages", "conversation", "transcript", "history"] {
            if let rows = object[key] as? [Any] {
                return rows
            }
            if let nested = object[key] as? [String: Any], let rows = nested["messages"] as? [Any] {
                return rows
            }
        }
        if let rows = object["content"] as? [Any] {
            return rows
        }
        return []
    }

    private static func line(from value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let object = value as? [String: Any] else { return nil }
        let role = (object["role"] as? String ?? object["type"] as? String ?? "").lowercased()
        let body = textBody(object["content"]) ?? textBody(object["text"]) ?? textBody(object["message"]) ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch role {
        case "user", "human":
            return "You: \(trimmed)"
        case "assistant", "agent", "model":
            return "Grok: \(trimmed)"
        case "", "text", "message":
            return trimmed
        default:
            return "\(role): \(trimmed)"
        }
    }

    private static func textBody(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let rows = value as? [Any] {
            let parts = rows.compactMap { textBody($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String, !text.isEmpty {
                return text
            }
            return textBody(object["content"])
        }
        return nil
    }
}
