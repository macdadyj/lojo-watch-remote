import Foundation

public enum VoiceAction: Equatable, Sendable {
    case allow
    case deny
    case stop
}

/// What a spoken approval command is allowed to do.
/// Allow never sends on its own: the person still has to tap.
public enum VoiceApprovalEffect: Equatable, Sendable {
    case confirmAllow
    case deny
    case stop
    case unrecognized
}

public enum VoiceTaskDisposition: Equatable, Sendable {
    case ignore
    case confirm(String)
    case send(String)
}

public struct VoiceResult: Equatable, Sendable {
    public var sessionID: String
    public var text: String

    public init(sessionID: String, text: String) {
        self.sessionID = sessionID
        self.text = text
    }
}

public enum VoiceCommandMatcher {
    public static func approvalEffect(for transcript: String) -> VoiceApprovalEffect {
        switch action(in: transcript) {
        case .allow:
            return .confirmAllow
        case .deny:
            return .deny
        case .stop:
            return .stop
        case nil:
            return .unrecognized
        }
    }

    public static func action(in transcript: String) -> VoiceAction? {
        let phrase = stripPolite(normalize(transcript))
        guard !phrase.isEmpty else { return nil }
        return phrases[phrase]
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var cleaned = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == " " {
                cleaned.append(Character(scalar))
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func stripPolite(_ phrase: String) -> String {
        var words = phrase.split(separator: " ").map(String.init)
        while words.first == "please" {
            words.removeFirst()
        }
        while words.last == "please" {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Whole utterances only. A longer sentence that merely contains one of these words is not a command.
    private static let phrases: [String: VoiceAction] = {
        var map: [String: VoiceAction] = [:]
        let allow = [
            "allow", "allow it", "allow this", "allow that", "allow once",
            "allow this action", "allow the action",
            "approve", "approve it", "approve this", "approve that", "approve once", "approved",
            "yes", "yes allow", "yes approve", "yes please",
            "accept", "accept it", "go ahead", "okay", "ok",
        ]
        let deny = [
            "deny", "deny it", "deny this", "deny that", "deny once", "denied",
            "reject", "reject it", "reject this", "refuse", "refuse it",
            "no", "no thanks",
            "don't allow", "dont allow", "do not allow",
            "don't approve", "dont approve", "do not approve",
        ]
        let stop = [
            "stop", "stop it", "stop this", "stop that", "stop the task", "stop task", "stopped",
            "halt", "halt it", "halt the task",
            "cancel", "cancel it", "cancel that", "cancel the task",
            "end", "end it", "end the task",
        ]
        for phrase in allow { map[phrase] = .allow }
        for phrase in deny { map[phrase] = .deny }
        for phrase in stop { map[phrase] = .stop }
        return map
    }()
}

public enum VoiceTaskPolicy {
    /// Empty dictation is ignored. Auto-send skips the Send/Cancel step. The words are a task, not an approval command.
    public static func disposition(transcript: String, autoSend: Bool) -> VoiceTaskDisposition {
        guard let prompt = normalizedTask(transcript) else { return .ignore }
        if autoSend {
            return .send(prompt)
        }
        return .confirm(prompt)
    }

    public static func normalizedTask(_ transcript: String) -> String? {
        let collapsed = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }
}

public enum VoiceResultPicker {
    /// The newest finished summary that changed. Running lines and approval prompts are not results.
    /// The first snapshot (empty previous) is history, not a new result.
    public static func latestResult(
        previous: [GrokSession],
        current: [GrokSession],
        includeNew: Bool
    ) -> VoiceResult? {
        guard !previous.isEmpty else { return nil }
        let prior = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let candidates = current.filter { session in
            guard isFinished(session.status) else { return false }
            let summary = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return false }
            if let old = prior[session.id] {
                let oldText = old.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return oldText != summary || old.status != session.status
            }
            return includeNew
        }
        guard let chosen = candidates.max(by: { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }) else { return nil }
        let text = PhoneSnapshot.clip(chosen.summary.trimmingCharacters(in: .whitespacesAndNewlines), limit: 280)
        guard !text.isEmpty else { return nil }
        return VoiceResult(sessionID: chosen.id, text: text)
    }

    private static func isFinished(_ status: SessionStatus) -> Bool {
        switch status {
        case .idle, .stopped, .failed:
            return true
        case .running, .needsApproval, .unknown:
            return false
        }
    }
}
