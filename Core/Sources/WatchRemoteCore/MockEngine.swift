import Foundation

public struct MockEngine: Equatable, Sendable {
    public private(set) var sessions: [GrokSession]

    public init(preview: Bool = false) {
        sessions = preview ? DemoCatalog.sessions() : []
    }

    public init(sessions: [GrokSession]) {
        self.sessions = sessions
    }

    public mutating func start(prompt: String, cwd: String?) -> GrokSession {
        let title = prompt.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let session = GrokSession(
            id: UUID().uuidString.lowercased(),
            title: title.isEmpty ? "New task" : title,
            summary: "Starting on example-host.",
            status: .running,
            updatedAt: Date(),
            cwd: cwd,
            transcript: ChatTranscript.append("You: \(prompt)", to: [])
        )
        sessions.insert(session, at: 0)
        return session
    }

    /// Keeps the same session id. A missing id returns false. Status does not block this.
    public mutating func continueSession(sessionID: String, prompt: String) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        sessions[index].status = .running
        sessions[index].summary = prompt
        sessions[index].updatedAt = Date()
        let lines = sessions[index].transcript ?? []
        sessions[index].transcript = ChatTranscript.append("You: \(prompt)", to: lines)
        return true
    }

    public mutating func rewrite(sessionID: String, title: String?, transcript: [String]) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let title, !title.isEmpty {
            sessions[index].title = title
        }
        sessions[index].transcript = transcript
    }

    /// Copies the visible chat onto the engine without dropping a per-chat auto-approve choice.
    public mutating func adopt(sessionID: String, title: String, transcript: [String], autoApprove: Bool?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if !title.isEmpty {
            sessions[index].title = title
        }
        sessions[index].transcript = transcript
        sessions[index].autoApprove = autoApprove
    }

    public mutating func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
    }

    public mutating func noteLine(sessionID: String, line: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].transcript = ChatTranscript.append(line, to: sessions[index].transcript ?? [])
    }

    /// The turn finished. The chat stays in the list and can take another message.
    public mutating func deliverReply(sessionID: String, reply: String) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let lines = sessions[index].transcript ?? []
        sessions[index].transcript = ChatTranscript.append("Grok: \(reply)", to: lines)
        sessions[index].summary = reply
        sessions[index].status = .idle
        sessions[index].updatedAt = Date()
        sessions[index].permission = nil
        return true
    }

    public mutating func raisePermission(sessionID: String) -> PermissionRequest? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let request = PermissionRequest(
            id: "perm-\(sessionID)",
            sessionID: sessionID,
            rpcID: "11",
            rpcIDIsNumber: true,
            title: "Run the project tests",
            detail: "grok wants to run the test command in this working directory.",
            allowOptionID: "allow-once",
            denyOptionID: "reject-once"
        )
        sessions[index].status = .needsApproval
        sessions[index].permission = request
        sessions[index].summary = "Waiting for you to allow or deny a command."
        return request
    }

    @discardableResult
    public mutating func allow(sessionID: String) -> GrokSession? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        sessions[index].permission = nil
        sessions[index].status = .idle
        sessions[index].summary = "Allowed the command. Tests finished with a short recap."
        sessions[index].updatedAt = Date()
        return sessions[index]
    }

    @discardableResult
    public mutating func deny(sessionID: String) -> GrokSession? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        sessions[index].permission = nil
        sessions[index].status = .stopped
        sessions[index].summary = "Denied. The task stopped before the command ran."
        return sessions[index]
    }

    @discardableResult
    public mutating func stop(sessionID: String) -> GrokSession? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        sessions[index].permission = nil
        sessions[index].status = .stopped
        sessions[index].summary = "Stopped from the watch."
        return sessions[index]
    }
}
