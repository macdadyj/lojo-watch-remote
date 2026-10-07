import Foundation

/// A chat stays open in every status. Idle is a badge, not a lock.
public enum ChatAccess {
    public static func canOpen(_ status: SessionStatus) -> Bool {
        switch status {
        case .running, .needsApproval, .idle, .stopped, .failed, .unknown:
            return true
        }
    }

    public static func canCompose(_ status: SessionStatus) -> Bool {
        switch status {
        case .running, .needsApproval, .idle, .stopped, .failed, .unknown:
            return true
        }
    }
}

/// No idle timeout on the client. Only an explicit end closes a chat or a link.
public enum SessionKeepalive {
    public static let idleTimeout: TimeInterval? = nil
    /// Heartbeat interval. This keeps the socket up. It does not expire a chat.
    public static let heartbeatInterval: TimeInterval = 25

    public static func remainsLive(elapsed: TimeInterval, userEnded: Bool) -> Bool {
        if userEnded { return false }
        return elapsed >= 0
    }
}

public struct ApprovalPreference: Equatable, Sendable {
    public var globalAutoApprove: Bool
    public var sessionOverride: Bool?

    public init(globalAutoApprove: Bool, sessionOverride: Bool? = nil) {
        self.globalAutoApprove = globalAutoApprove
        self.sessionOverride = sessionOverride
    }

    public var autoApproves: Bool {
        sessionOverride ?? globalAutoApprove
    }
}

public struct ChatListEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var lastMessage: String
    public var updatedAt: Date?
    public var status: SessionStatus

    public init(id: String, title: String, lastMessage: String, updatedAt: Date?, status: SessionStatus) {
        self.id = id
        self.title = title
        self.lastMessage = lastMessage
        self.updatedAt = updatedAt
        self.status = status
    }
}

public enum ChatTranscript {
    public static let autoApprovedPrefix = "Auto-approved:"
    public static let toolPrefix = "Tool:"

    public static func lastMessage(summary: String, transcript: [String]?) -> String {
        let lines = (transcript ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let last = lines.last {
            return last
        }
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summaryText.isEmpty ? "Empty chat" : summaryText
    }

    public static func entry(for session: GrokSession) -> ChatListEntry {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatListEntry(
            id: session.id,
            title: title.isEmpty ? "Chat" : title,
            lastMessage: lastMessage(summary: session.summary, transcript: session.transcript),
            updatedAt: session.updatedAt,
            status: session.status
        )
    }

    public static func append(_ line: String, to lines: [String]) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines }
        return lines + [trimmed]
    }

    public static func autoApproved(_ title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "\(autoApprovedPrefix) tool" : "\(autoApprovedPrefix) \(name)"
    }

    public static func toolCard(_ title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(toolPrefix) \(name.isEmpty ? "tool" : name)"
    }

    public static func isToolCard(_ line: String) -> Bool {
        line.hasPrefix(toolPrefix)
    }

    public static func isNote(_ line: String) -> Bool {
        line.hasPrefix(autoApprovedPrefix)
    }

    /// Grows the latest assistant line while a reply streams. A new chunk starts a line.
    public static func streamingAssistant(_ chunk: String, in lines: [String]) -> [String] {
        guard !chunk.isEmpty else { return lines }
        var copy = lines
        if let last = copy.last, last.hasPrefix("Grok:") {
            copy[copy.count - 1] = String((last + chunk).prefix(4000))
            return copy
        }
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines }
        copy.append("Grok: \(trimmed)")
        return copy
    }

    /// Prior lines travel with a follow-up when the backend session has to be opened again.
    public static func followUp(history: [String], message: String, limit: Int = 1600) -> String {
        let ask = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = history
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(8)
            .joined(separator: "\n")
        let body = prior.isEmpty ? ask : "Earlier in this chat:\n\(prior)\n\n\(ask)"
        guard body.count > limit, limit > 0 else { return body }
        return String(body.suffix(limit))
    }
}
