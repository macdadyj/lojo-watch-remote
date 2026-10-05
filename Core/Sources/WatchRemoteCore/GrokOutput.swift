import Foundation

public enum GrokOutput {
    public static func parseStreamingLine(_ line: String) -> StreamEvent? {
        let trimmed = stripANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "text":
            return .text(stringField(object, "data") ?? "")
        case "thought":
            return .thought(stringField(object, "data") ?? "")
        case "tool_call":
            return .tool(title: stringField(object, "title") ?? stringField(object, "toolName") ?? "Tool")
        case "tool_call_update":
            return .toolUpdate(status: stringField(object, "status") ?? "")
        case "usage":
            return .usage(summary: usageLine(object["usage"]))
        case "end":
            return .end(
                sessionID: stringField(object, "sessionId"),
                stopReason: stringField(object, "stopReason") ?? "end_turn",
                usage: usageLine(object["usage"])
            )
        case "error":
            return .error(stringField(object, "message") ?? "The task failed.")
        case "plan", "available_commands":
            return .ignored
        default:
            return .ignored
        }
    }

    public static func parseSessionsList(_ text: String) -> [GrokSession] {
        let cleaned = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        if cleaned.hasPrefix("{") || cleaned.hasPrefix("[") {
            return parseSessionsJSON(cleaned)
        }
        return cleaned.split(whereSeparator: \.isNewline).compactMap(parseSessionsRow)
    }

    public static func stopReason(in text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let reason = result["stopReason"] as? String,
              !reason.isEmpty else { return "end_turn" }
        return reason
    }

    public static func parseUsage(_ text: String) -> String? {
        let cleaned = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let line = usageLine(object), !line.isEmpty { return line }
        if let object = object as? [String: Any] {
            if let session = object["session"], let line = usageLine(session), !line.isEmpty { return line }
            if let result = object["result"] as? [String: Any] {
                if let line = usageLine(result), !line.isEmpty { return line }
                if let usage = result["usage"], let line = usageLine(usage), !line.isEmpty { return line }
            }
        }
        return nil
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func parseSessionsJSON(_ text: String) -> [GrokSession] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [Any]
        if let array = json as? [Any] {
            rows = array
        } else if let object = json as? [String: Any], let array = object["sessions"] as? [Any] {
            rows = array
        } else {
            return []
        }
        return rows.compactMap(session(from:))
    }

    private static func session(from row: Any) -> GrokSession? {
        guard let object = row as? [String: Any] else { return nil }
        let id = stringField(object, "id") ?? stringField(object, "sessionId") ?? stringField(object, "session_id")
        guard let id, !id.isEmpty else { return nil }
        let title = stringField(object, "title")
            ?? stringField(object, "generated_title")
            ?? stringField(object, "name")
            ?? "Session"
        let summary = stringField(object, "summary")
            ?? stringField(object, "last_turn_summary")
            ?? stringField(object, "lastOutput")
            ?? ""
        let status = status(from: stringField(object, "status") ?? stringField(object, "source"))
        return GrokSession(
            id: id,
            title: title,
            summary: summary,
            status: status,
            cwd: stringField(object, "cwd")
        )
    }

    private static func parseSessionsRow(_ line: Substring) -> GrokSession? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let match = text.range(of: uuidPattern, options: .regularExpression) else { return nil }
        let id = String(text[match])
        let remainder = text[match.upperBound...].trimmingCharacters(in: .whitespaces)
        let status = status(from: remainder)
        let summary = remainder.isEmpty ? "Session \(id.prefix(8))" : remainder
        return GrokSession(id: id, title: summary, summary: summary, status: status)
    }

    private static let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    static func status(from text: String?) -> SessionStatus {
        let folded = (text ?? "").lowercased()
        if folded.contains("approv") || folded.contains("permission") || folded.contains("waiting") {
            return .needsApproval
        }
        if folded.contains("run") || folded.contains("active") || folded.contains("busy") { return .running }
        if folded.contains("fail") || folded.contains("error") { return .failed }
        if folded.contains("stop") || folded.contains("cancel") { return .stopped }
        if folded.contains("idle") || folded.contains("done") || folded.contains("end") { return .idle }
        return .idle
    }

    private static func stringField(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? String, !value.isEmpty { return value }
        if let value = object[key] as? NSNumber { return value.stringValue }
        return nil
    }

    private static func usageLine(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        let input = number(object, "input_tokens") ?? number(object, "inputTokens")
        let output = number(object, "output_tokens") ?? number(object, "outputTokens")
        var parts: [String] = []
        if let input { parts.append("\(input) in") }
        if let output { parts.append("\(output) out") }
        if let cost = object["total_cost_usd"] as? Double {
            parts.append(String(format: "$%.4f", cost))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func number(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? Int { return String(value) }
        if let value = object[key] as? Double { return String(Int(value)) }
        if let value = object[key] as? NSNumber { return value.stringValue }
        return nil
    }
}

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case thought(String)
    case tool(title: String)
    case toolUpdate(status: String)
    case usage(summary: String?)
    case end(sessionID: String?, stopReason: String, usage: String?)
    case error(String)
    case ignored
}
