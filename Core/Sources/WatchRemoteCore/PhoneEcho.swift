import Foundation

/// The iPhone half of the Watch transport test: every prompt is answered with "I can hear you."
///
/// The Watch uses it in process when the simulator's WatchConnectivity does not deliver, so the
/// Watch's own phone path (routing, new-chat detection, reply bubbles) is still exercised.
public struct PhoneEcho: Sendable {
    public static let reply = "I can hear you."
    public static let seedID = "echo-1"

    public private(set) var sessions: [GrokSession]
    private var created = 0

    public init() {
        sessions = [
            GrokSession(
                id: Self.seedID,
                title: "Greeting and Current Weather Inquiry",
                summary: "Ready.",
                status: .idle,
                transcript: ["You: earlier", "Grok: Ready."]
            ),
        ]
    }

    public var snapshot: PhoneSnapshot {
        PhoneSnapshot(mode: .ssh, link: .connected, sessions: sessions, banner: nil, approvalsAvailable: true, hostLabel: "example-host")
    }

    /// Records a start command's prompt. Returns the session that will answer, or nil when nothing will.
    public mutating func accept(_ command: PhoneCommand) -> String? {
        guard command.kind == .start else { return nil }
        let prompt = (command.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let id: String
        if let existing = command.sessionID, sessions.contains(where: { $0.id == existing }) {
            id = existing
        } else {
            created += 1
            id = "echo-new-\(created)"
            sessions.insert(GrokSession(id: id, title: prompt, summary: "Starting.", status: .running, transcript: []), at: 0)
        }
        edit(id) { session in
            session.transcript = (session.transcript ?? []) + ["You: \(prompt)"]
            session.status = .running
        }
        return id
    }

    public mutating func answer(_ id: String) {
        edit(id) { session in
            session.transcript = (session.transcript ?? []) + ["Grok: \(Self.reply)"]
            session.status = .idle
            session.summary = Self.reply
        }
    }

    private mutating func edit(_ id: String, _ change: (inout GrokSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
    }
}
