import Foundation

public struct VoiceTurnContext: Equatable, Sendable {
    public var inConversation: Bool
    public var hostLabel: String
    public var linkTitle: String
    public var sessions: [GrokSession]
    public var computers: [ComputerSummary]
    public var activeComputerID: String
    public var focusedSessionID: String?
    public var pendingAllowSessionID: String?

    public init(
        inConversation: Bool,
        hostLabel: String,
        linkTitle: String,
        sessions: [GrokSession],
        computers: [ComputerSummary],
        activeComputerID: String,
        focusedSessionID: String? = nil,
        pendingAllowSessionID: String? = nil
    ) {
        self.inConversation = inConversation
        self.hostLabel = hostLabel
        self.linkTitle = linkTitle
        self.sessions = sessions
        self.computers = computers
        self.activeComputerID = activeComputerID
        self.focusedSessionID = focusedSessionID
        self.pendingAllowSessionID = pendingAllowSessionID
    }
}

public enum VoiceTurnAction: Equatable, Sendable {
    case none
    case allow(sessionID: String)
    case deny(sessionID: String)
    case stop(sessionID: String)
    case startTask(String)
    case selectComputer(String)
}

public struct VoiceTurnEffect: Equatable, Sendable {
    public var command: VoiceCommand
    public var spoken: String
    public var phase: VoiceDialogue
    public var pendingAllowSessionID: String?
    public var listenAgain: Bool
    public var action: VoiceTurnAction

    public init(
        command: VoiceCommand,
        spoken: String,
        phase: VoiceDialogue,
        pendingAllowSessionID: String?,
        listenAgain: Bool,
        action: VoiceTurnAction
    ) {
        self.command = command
        self.spoken = spoken
        self.phase = phase
        self.pendingAllowSessionID = pendingAllowSessionID
        self.listenAgain = listenAgain
        self.action = action
    }
}

public enum VoiceTurnPlanner {
    public static func effect(for transcript: String, context: VoiceTurnContext) -> VoiceTurnEffect {
        let phase: VoiceDialogue = context.pendingAllowSessionID == nil ? .idle : .awaitingAllowYes
        let command = VoiceDialogueMatcher.interpret(transcript, phase: phase)
        switch command {
        case .requestAllow:
            return requestAllow(context)
        case .confirmAllow:
            return confirmAllow(context)
        case .deny:
            return deny(context)
        case .stop, .stopSession:
            return stop(context, command: command)
        case .listSessions:
            return kept(
                command: command,
                spoken: VoiceAllowScript.sessionsSpeech(context.sessions),
                context: context
            )
        case .status:
            let running = context.sessions.filter { $0.status == .running }.count
            let waiting = context.sessions.filter { $0.permission != nil }.count
            return kept(
                command: command,
                spoken: VoiceAllowScript.statusSpeech(
                    host: context.hostLabel,
                    linkTitle: context.linkTitle,
                    running: running,
                    waiting: waiting
                ),
                context: context
            )
        case .switchComputer(let name):
            return switchComputer(name, context: context)
        case .newTask(let prompt):
            return VoiceTurnEffect(
                command: command,
                spoken: "Sending. \(VoiceAllowScript.shortTask(prompt)).",
                phase: .idle,
                pendingAllowSessionID: nil,
                listenAgain: context.inConversation,
                action: .startTask(prompt)
            )
        case .cancelConfirm:
            return VoiceTurnEffect(
                command: command,
                spoken: "Not allowed.",
                phase: .idle,
                pendingAllowSessionID: nil,
                listenAgain: context.inConversation,
                action: .none
            )
        case .unrecognized:
            return kept(
                command: command,
                spoken: "Say a task, list sessions, status, stop, or allow.",
                context: context
            )
        }
    }

    private static func requestAllow(_ context: VoiceTurnContext) -> VoiceTurnEffect {
        guard let session = focused(context) ?? approval(context), let permission = session.permission else {
            return VoiceTurnEffect(
                command: .requestAllow,
                spoken: "Nothing is waiting for approval.",
                phase: .idle,
                pendingAllowSessionID: nil,
                listenAgain: true,
                action: .none
            )
        }
        return VoiceTurnEffect(
            command: .requestAllow,
            spoken: VoiceAllowScript.readback(title: permission.title, detail: permission.detail),
            phase: .awaitingAllowYes,
            pendingAllowSessionID: session.id,
            listenAgain: true,
            action: .none
        )
    }

    private static func confirmAllow(_ context: VoiceTurnContext) -> VoiceTurnEffect {
        guard let pending = context.pendingAllowSessionID,
              let session = context.sessions.first(where: { $0.id == pending }),
              session.permission != nil else {
            return VoiceTurnEffect(
                command: .confirmAllow,
                spoken: "Nothing is waiting for approval.",
                phase: .idle,
                pendingAllowSessionID: nil,
                listenAgain: context.inConversation,
                action: .none
            )
        }
        return VoiceTurnEffect(
            command: .confirmAllow,
            spoken: "Allowed.",
            phase: .idle,
            pendingAllowSessionID: nil,
            listenAgain: context.inConversation,
            action: .allow(sessionID: session.id)
        )
    }

    private static func deny(_ context: VoiceTurnContext) -> VoiceTurnEffect {
        let session = focused(context) ?? approval(context) ?? stoppable(context)
        guard let session else {
            return VoiceTurnEffect(
                command: .deny,
                spoken: "Nothing is waiting.",
                phase: .idle,
                pendingAllowSessionID: nil,
                listenAgain: context.inConversation,
                action: .none
            )
        }
        return VoiceTurnEffect(
            command: .deny,
            spoken: "Denied.",
            phase: .idle,
            pendingAllowSessionID: nil,
            listenAgain: context.inConversation,
            action: .deny(sessionID: session.id)
        )
    }

    private static func stop(_ context: VoiceTurnContext, command: VoiceCommand) -> VoiceTurnEffect {
        let session: GrokSession?
        if let focused = focused(context) {
            session = focused
        } else {
            session = stoppable(context)
        }
        guard let session else {
            return VoiceTurnEffect(
                command: command,
                spoken: "Nothing is running.",
                phase: .idle,
                pendingAllowSessionID: nil,
                listenAgain: context.inConversation,
                action: .none
            )
        }
        return VoiceTurnEffect(
            command: command,
            spoken: "Stopping \(session.title).",
            phase: .idle,
            pendingAllowSessionID: nil,
            listenAgain: context.inConversation,
            action: .stop(sessionID: session.id)
        )
    }

    private static func switchComputer(_ name: String?, context: VoiceTurnContext) -> VoiceTurnEffect {
        let base = VoiceTurnEffect(
            command: .switchComputer(name),
            spoken: "",
            phase: phase(context),
            pendingAllowSessionID: context.pendingAllowSessionID,
            listenAgain: context.inConversation,
            action: .none
        )
        let computers = context.computers
        guard !computers.isEmpty else {
            var effect = base
            effect.spoken = "No saved computers."
            return effect
        }
        let labels = computers.map(\.label).joined(separator: ", ")
        guard let name, !name.isEmpty else {
            var effect = base
            effect.spoken = "Say switch to \(labels)."
            effect.listenAgain = true
            return effect
        }
        guard let label = VoiceAllowScript.matchingLabel(spoken: name, labels: computers.map(\.label)),
              let match = computers.first(where: { $0.label == label }) else {
            var effect = base
            effect.spoken = "Say switch to \(labels)."
            effect.listenAgain = true
            return effect
        }
        if match.id == context.activeComputerID {
            var effect = base
            effect.spoken = "Already using \(match.label)."
            return effect
        }
        var effect = base
        effect.spoken = "Switching to \(match.label)."
        effect.action = .selectComputer(match.id)
        return effect
    }

    private static func kept(command: VoiceCommand, spoken: String, context: VoiceTurnContext) -> VoiceTurnEffect {
        VoiceTurnEffect(
            command: command,
            spoken: spoken,
            phase: phase(context),
            pendingAllowSessionID: context.pendingAllowSessionID,
            listenAgain: context.inConversation,
            action: .none
        )
    }

    private static func phase(_ context: VoiceTurnContext) -> VoiceDialogue {
        context.pendingAllowSessionID == nil ? .idle : .awaitingAllowYes
    }

    private static func focused(_ context: VoiceTurnContext) -> GrokSession? {
        guard let id = context.focusedSessionID else { return nil }
        return context.sessions.first { $0.id == id }
    }

    private static func approval(_ context: VoiceTurnContext) -> GrokSession? {
        if let id = context.pendingAllowSessionID,
           let session = context.sessions.first(where: { $0.id == id }),
           session.permission != nil {
            return session
        }
        return context.sessions.first { $0.permission != nil }
    }

    private static func stoppable(_ context: VoiceTurnContext) -> GrokSession? {
        if let id = context.pendingAllowSessionID,
           let session = context.sessions.first(where: { $0.id == id }) {
            return session
        }
        return context.sessions.first { $0.status == .needsApproval || $0.status == .running }
    }
}

public enum VoiceLoopHarness {
    public static let transcripts = ["list sessions", "allow", "yes", "deny", "stop"]

    /// Scripted conversation for the simulator and unit tests. The microphone stays off.
    public static func lines(sessions: [GrokSession], hostLabel: String, linkTitle: String) -> [String] {
        var context = VoiceTurnContext(
            inConversation: true,
            hostLabel: hostLabel,
            linkTitle: linkTitle,
            sessions: sessions,
            computers: [],
            activeComputerID: ""
        )
        var lines = [
            VoiceSpeechCopy.handsFreeRule,
            VoiceSpeechCopy.approvalRule,
            "Silence \(silenceText) after speech sends the turn.",
        ]
        for transcript in transcripts {
            let effect = VoiceTurnPlanner.effect(for: transcript, context: context)
            context.pendingAllowSessionID = effect.pendingAllowSessionID
            lines.append("“\(transcript)” → \(effect.spoken)")
        }
        return lines
    }

    private static var silenceText: String {
        let tenths = Int((VoiceEndpointDetector.Configuration.handsFree.silence * 100).rounded())
        return "\(tenths / 100).\(tenths % 100)s"
    }
}
