import Foundation

public enum ConnectionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case ssh
    case relay
    case demo

    public var title: String {
        switch self {
        case .ssh: return "SSH"
        case .relay: return "Relay"
        case .demo: return "Demo"
        }
    }
}

public enum LinkState: String, Codable, Equatable, Sendable {
    case demo
    case connected
    case connecting
    case offline
    case needsPairing
    case phoneAway

    public var title: String {
        switch self {
        case .demo: return "Demo"
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .offline: return "Not connected"
        case .needsPairing: return "Needs pairing"
        case .phoneAway: return "iPhone app closed"
        }
    }
}

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case running
    case needsApproval
    case idle
    case stopped
    case failed
    case unknown

    public var title: String {
        switch self {
        case .running: return "Running"
        case .needsApproval: return "Needs approval"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

public struct PermissionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    /// JSON-RPC id, kept as text so a numeric id is not confused with a string id.
    public var rpcID: String
    public var rpcIDIsNumber: Bool
    public var title: String
    public var detail: String
    public var allowOptionID: String?
    public var denyOptionID: String?

    public init(
        id: String,
        sessionID: String,
        rpcID: String,
        rpcIDIsNumber: Bool,
        title: String,
        detail: String,
        allowOptionID: String?,
        denyOptionID: String?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.rpcID = rpcID
        self.rpcIDIsNumber = rpcIDIsNumber
        self.title = title
        self.detail = detail
        self.allowOptionID = allowOptionID
        self.denyOptionID = denyOptionID
    }
}

public struct GrokSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var status: SessionStatus
    public var updatedAt: Date?
    public var cwd: String?
    public var permission: PermissionRequest?
    /// Lines from `session/load`. Omitted from older snapshots.
    public var transcript: [String]?
    /// Nil inherits the phone setting. True or false is this chat only.
    public var autoApprove: Bool?

    public init(
        id: String,
        title: String,
        summary: String,
        status: SessionStatus,
        updatedAt: Date? = nil,
        cwd: String? = nil,
        permission: PermissionRequest? = nil,
        transcript: [String]? = nil,
        autoApprove: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.permission = permission
        self.transcript = transcript
        self.autoApprove = autoApprove
    }
}

public struct ComputerSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct PhoneSnapshot: Codable, Equatable, Sendable {
    public var mode: ConnectionMode
    public var link: LinkState
    public var sessions: [GrokSession]
    public var banner: String?
    public var approvalsAvailable: Bool
    public var hostLabel: String
    public var computers: [ComputerSummary]
    public var activeComputerID: String
    /// The active computer has a direct relay pairing the Watch can use on its own.
    public var directReady: Bool
    /// Phone setting. Off until the user turns it on. Older snapshots omit it.
    public var autoApproveTools: Bool

    public init(
        mode: ConnectionMode,
        link: LinkState,
        sessions: [GrokSession],
        banner: String?,
        approvalsAvailable: Bool,
        hostLabel: String,
        computers: [ComputerSummary] = [],
        activeComputerID: String = "",
        directReady: Bool = false,
        autoApproveTools: Bool = false
    ) {
        self.mode = mode
        self.link = link
        self.sessions = sessions
        self.banner = banner
        self.approvalsAvailable = approvalsAvailable
        self.hostLabel = hostLabel
        self.computers = computers
        self.activeComputerID = activeComputerID
        self.directReady = directReady
        self.autoApproveTools = autoApproveTools
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case link
        case sessions
        case banner
        case approvalsAvailable
        case hostLabel
        case computers
        case activeComputerID
        case directReady
        case autoApproveTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(ConnectionMode.self, forKey: .mode)
        link = try container.decode(LinkState.self, forKey: .link)
        sessions = try container.decode([GrokSession].self, forKey: .sessions)
        banner = try container.decodeIfPresent(String.self, forKey: .banner)
        approvalsAvailable = try container.decode(Bool.self, forKey: .approvalsAvailable)
        hostLabel = try container.decode(String.self, forKey: .hostLabel)
        computers = try container.decodeIfPresent([ComputerSummary].self, forKey: .computers) ?? []
        activeComputerID = try container.decodeIfPresent(String.self, forKey: .activeComputerID) ?? ""
        directReady = try container.decodeIfPresent(Bool.self, forKey: .directReady) ?? false
        autoApproveTools = try container.decodeIfPresent(Bool.self, forKey: .autoApproveTools) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(link, forKey: .link)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(banner, forKey: .banner)
        try container.encode(approvalsAvailable, forKey: .approvalsAvailable)
        try container.encode(hostLabel, forKey: .hostLabel)
        try container.encode(computers, forKey: .computers)
        try container.encode(activeComputerID, forKey: .activeComputerID)
        try container.encode(directReady, forKey: .directReady)
        try container.encode(autoApproveTools, forKey: .autoApproveTools)
    }

    /// WatchConnectivity application context is small. Keep the payload short.
    public func trimmed(limit: Int = 12, summaryLimit: Int = 160) -> PhoneSnapshot {
        var copy = self
        copy.sessions = Array(sessions.prefix(limit)).map { session in
            var item = session
            item.summary = Self.clip(session.summary, limit: summaryLimit)
            if var permission = item.permission {
                permission.detail = Self.clip(permission.detail, limit: summaryLimit)
                item.permission = permission
            }
            if let transcript = item.transcript {
                item.transcript = Array(transcript.suffix(8)).map { Self.clip($0, limit: 160) }
            }
            return item
        }
        if let banner {
            copy.banner = Self.clip(banner, limit: 180)
        }
        copy.computers = Array(computers.prefix(12)).map { computer in
            ComputerSummary(id: computer.id, label: Self.clip(computer.label, limit: 40))
        }
        return copy
    }

    public static func clip(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

public struct PhoneCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case refresh
        case start
        case approve
        case deny
        case stop
        case selectComputer
        case resume
        /// The Watch asked the iPhone to open the pairing screen.
        case showPairing
        /// `enabled` is the Auto-approve tools switch.
        case setAutoApprove
    }

    public var kind: Kind
    public var prompt: String?
    public var sessionID: String?
    public var permissionID: String?
    public var cwd: String?
    public var computerID: String?
    public var enabled: Bool?

    public init(
        kind: Kind,
        prompt: String? = nil,
        sessionID: String? = nil,
        permissionID: String? = nil,
        cwd: String? = nil,
        computerID: String? = nil,
        enabled: Bool? = nil
    ) {
        self.kind = kind
        self.prompt = prompt
        self.sessionID = sessionID
        self.permissionID = permissionID
        self.cwd = cwd
        self.computerID = computerID
        self.enabled = enabled
    }
}

public enum LinkCodec {
    public static func encodeSnapshot(_ snapshot: PhoneSnapshot) -> String? {
        let data = try? JSONEncoder().encode(snapshot.trimmed())
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decodeSnapshot(_ text: String) -> PhoneSnapshot? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhoneSnapshot.self, from: data)
    }

    public static func encodeCommand(_ command: PhoneCommand) -> String? {
        let data = try? JSONEncoder().encode(command)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decodeCommand(_ text: String) -> PhoneCommand? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PhoneCommand.self, from: data)
    }
}

public enum DemoCatalog {
    public static let runningID = "0199aaaa-0000-7000-8000-000000000001"
    public static let approvalID = "0199aaaa-0000-7000-8000-000000000002"
    public static let idleID = "0199aaaa-0000-7000-8000-000000000003"
    public static let longID = "0199aaaa-0000-7000-8000-000000000005"

    public static func sessions() -> [GrokSession] {
        [
            GrokSession(
                id: runningID,
                title: "Read the build logs",
                summary: "Looking through the latest test output.",
                status: .running
            ),
            GrokSession(
                id: approvalID,
                title: "Update the parser",
                summary: "Wants to edit SessionsListParser before continuing.",
                status: .needsApproval,
                permission: PermissionRequest(
                    id: "perm-demo",
                    sessionID: approvalID,
                    rpcID: "7",
                    rpcIDIsNumber: true,
                    title: "Edit SessionsListParser.swift",
                    detail: "Apply the streaming-json row parser.",
                    allowOptionID: "allow-once",
                    denyOptionID: "reject-once"
                )
            ),
            GrokSession(
                id: idleID,
                title: "Note the overlay route",
                summary: "The computer is reachable only on the private overlay.",
                status: .idle,
                transcript: [
                    "You: Where does this computer live?",
                    ChatTranscript.toolCard("Execute curl -fsS https://example.invalid/weather"),
                    ChatTranscript.toolCard("Web search: maps"),
                    ChatTranscript.toolCard("Tool"),
                    "Grok: The computer is reachable only on the private overlay.",
                ]
            ),
            longChat(),
        ]
    }

    /// Enough lines that the first message is off screen on a phone.
    private static func longChat() -> GrokSession {
        var lines = ["You: oldest note in this chat"]
        for index in 1...32 {
            lines.append("Grok: Earlier reply \(index).")
        }
        lines.append("You: Still with me?")
        lines.append("Grok: Yes. The latest line is this one.")
        return GrokSession(
            id: longID,
            title: "A long chat",
            summary: "Yes. The latest line is this one.",
            status: .idle,
            transcript: lines
        )
    }

    public static func snapshot() -> PhoneSnapshot {
        PhoneSnapshot(
            mode: .demo,
            link: .demo,
            sessions: sessions(),
            banner: nil,
            approvalsAvailable: true,
            hostLabel: "example-host"
        )
    }

    /// Screenshot fixtures. Names that are not fixtures return nil.
    public static func preview(named screen: String) -> PhoneSnapshot? {
        switch screen {
        case "empty":
            return PhoneSnapshot(
                mode: .demo,
                link: .demo,
                sessions: [],
                banner: nil,
                approvalsAvailable: true,
                hostLabel: "example-host"
            )
        case "loading":
            return PhoneSnapshot(
                mode: .ssh,
                link: .connecting,
                sessions: [],
                banner: nil,
                approvalsAvailable: false,
                hostLabel: "example-host"
            )
        case "offline":
            return PhoneSnapshot(
                mode: .ssh,
                link: .offline,
                sessions: [],
                banner: "The computer is not connected.",
                approvalsAvailable: false,
                hostLabel: "example-host"
            )
        case "error":
            return PhoneSnapshot(
                mode: .ssh,
                link: .offline,
                sessions: [
                    GrokSession(
                        id: "0199aaaa-0000-7000-8000-000000000004",
                        title: "Read the build logs",
                        summary: "The agent server did not answer.",
                        status: .failed
                    ),
                ],
                banner: "The agent server did not answer.",
                approvalsAvailable: false,
                hostLabel: "example-host"
            )
        case "pairing":
            return PhoneSnapshot(
                mode: .ssh,
                link: .needsPairing,
                sessions: [],
                banner: "Generate a key on the iPhone, then authorize it on the computer.",
                approvalsAvailable: false,
                hostLabel: "example-host"
            )
        case "direct", "via":
            return PhoneSnapshot(
                mode: .ssh,
                link: .connected,
                sessions: sessions(),
                banner: nil,
                approvalsAvailable: true,
                hostLabel: "example-host",
                directReady: true
            )
        case "watch-unpaired":
            return PhoneSnapshot(
                mode: .ssh,
                link: .needsPairing,
                sessions: [],
                banner: "Pair on iPhone first.",
                approvalsAvailable: false,
                hostLabel: "example-host"
            )
        case "long":
            return PhoneSnapshot(
                mode: .demo,
                link: .demo,
                sessions: [
                    GrokSession(
                        id: approvalID,
                        title: "Rewrite the session list parser so long titles stay readable",
                        summary: "The streaming-json row parser should keep the full permission detail visible when the type size is large and the title wraps.",
                        status: .needsApproval,
                        permission: PermissionRequest(
                            id: "perm-long",
                            sessionID: approvalID,
                            rpcID: "7",
                            rpcIDIsNumber: true,
                            title: "Edit the parser that turns streaming-json rows into session cards",
                            detail: "Apply the change in the working tree, then show the diff before anything is written.",
                            allowOptionID: "allow-once",
                            denyOptionID: "reject-once"
                        )
                    ),
                ],
                banner: nil,
                approvalsAvailable: true,
                hostLabel: "example-host"
            )
        default:
            return nil
        }
    }
}
