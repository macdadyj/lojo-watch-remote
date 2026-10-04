import Foundation

public struct MockEngine: Equatable, Sendable {
    public private(set) var sessions: [GrokSession]

    public init(preview: Bool = false) {
        sessions = preview ? DemoCatalog.sessions() : []
    }

    public mutating func start(prompt: String, cwd: String?) -> GrokSession {
        let title = prompt.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let session = GrokSession(
            id: UUID().uuidString.lowercased(),
            title: title.isEmpty ? "New task" : title,
            summary: "Starting on example-host.",
            status: .running,
            updatedAt: Date(),
            cwd: cwd
        )
        sessions.insert(session, at: 0)
        return session
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
