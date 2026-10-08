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

public struct ToolStep: Equatable, Sendable {
    public var summary: String
    public var detail: String

    public init(summary: String, detail: String) {
        self.summary = summary
        self.detail = detail
    }
}

public enum ChatBlock: Equatable, Identifiable, Sendable {
    case user(id: Int, text: String)
    case assistant(id: Int, text: String)
    case tools(id: Int, steps: [ToolStep], running: Bool)
    case note(id: Int, text: String)

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _), .tools(let id, _, _), .note(let id, _):
            return id
        }
    }
}

public enum ChatTranscript {
    public static let autoApprovedPrefix = "Auto-approved:"
    public static let toolPrefix = "Tool:"

    public static func lastMessage(summary: String, transcript: [String]?) -> String {
        let lines = (transcript ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let last = lines.reversed().first(where: { isConversation($0) }) {
            return spokenText(last)
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

    /// Status and keychain failures stay off the transcript. They are not chat messages.
    public static func isStatusNoise(_ line: String) -> Bool {
        let folded = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if folded.isEmpty { return true }
        if folded == "on-device speech" || folded == "speech on iphone" { return true }
        if folded == "sending" || folded.hasPrefix("sending.") || folded.hasPrefix("sending ") { return true }
        if folded.hasPrefix("keychain error") { return true }
        if folded == "listening" || folded == "hearing you" || folded == "restoring" || folded == "restored" { return true }
        return false
    }

    public static func isConversation(_ line: String) -> Bool {
        !isToolCard(line) && !isNote(line) && !isStatusNoise(line)
    }

    public static func spokenText(_ line: String) -> String {
        if line.hasPrefix("You:") {
            return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("Grok:") {
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short label for a tool row. The raw command stays in the expanded detail.
    public static func toolSummary(_ title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = name.lowercased()
        if name.isEmpty || folded == "tool" { return "Used a tool" }
        if folded.contains("web search") || folded.contains("search the web") { return "Searched the web" }
        if folded.contains("grep") || folded.contains("glob") || folded.contains("search files") { return "Searched files" }
        if folded.contains("curl") || folded.contains("execute") || folded.contains("python")
            || folded.contains("bash") || folded.contains("shell") || folded.hasPrefix("ran ") {
            return "Ran a command"
        }
        if folded.contains("|") { return "Used a tool" }
        if name.count <= 28, !folded.contains("http"), !name.contains("\n") { return name }
        return "Used a tool"
    }

    public static func toolDetail(_ title: String, limit: Int = 160) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > limit, limit > 1 else { return name }
        return String(name.prefix(limit - 1)) + "…"
    }

    public static func toolGroupTitle(count: Int) -> String {
        let noun = count == 1 ? "step" : "steps"
        return "Worked · \(count) \(noun)"
    }

    public static func blocks(from lines: [String], toolsRunning: Bool) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var steps: [ToolStep] = []
        var nextID = 0
        func flush() {
            guard !steps.isEmpty else { return }
            blocks.append(ChatBlock.tools(id: nextID, steps: steps, running: false))
            nextID += 1
            steps = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isStatusNoise(trimmed) { continue }
            if isToolCard(trimmed) || isNote(trimmed) {
                let raw = toolRawTitle(trimmed)
                steps.append(ToolStep(summary: toolSummary(raw), detail: toolDetail(raw)))
                continue
            }
            flush()
            if trimmed.hasPrefix("You:") {
                blocks.append(.user(id: nextID, text: spokenText(trimmed)))
            } else {
                blocks.append(.assistant(id: nextID, text: spokenText(trimmed)))
            }
            nextID += 1
        }
        flush()
        guard toolsRunning, let last = blocks.indices.last else { return blocks }
        if case .tools(let id, let grouped, _) = blocks[last] {
            blocks[last] = .tools(id: id, steps: grouped, running: true)
        }
        return blocks
    }

    private static func toolRawTitle(_ line: String) -> String {
        if line.hasPrefix(toolPrefix) {
            return String(line.dropFirst(toolPrefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix(autoApprovedPrefix) {
            return String(line.dropFirst(autoApprovedPrefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return line
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
