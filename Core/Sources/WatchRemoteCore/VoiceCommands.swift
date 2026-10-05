import Foundation

/// Spoken allow is two steps. The first utterance only asks. Yes or confirm is the second step.
public enum VoiceDialogue: Equatable, Sendable {
    case idle
    case awaitingAllowYes
}

public enum VoiceCommand: Equatable, Sendable {
    case requestAllow
    case confirmAllow
    case deny
    case stop
    case stopSession
    case listSessions
    case status
    case switchComputer(String?)
    case newTask(String)
    case cancelConfirm
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

public enum VoiceAllowScript {
    public static let confirmCue = "Say yes to confirm."

    /// Spoken and shown before a yes can approve. The cue is always the end of the line.
    public static func readback(title: String, detail: String) -> String {
        let name = collapsed(title)
        let extra = collapsed(detail)
        let subject = name.isEmpty ? "this action" : name
        let body: String
        if extra.isEmpty || extra == subject {
            body = "Allow \(subject)."
        } else {
            body = "Allow \(subject). \(extra)."
        }
        let room = 180 - confirmCue.count - 1
        let clipped = body.count > room ? PhoneSnapshot.clip(body, limit: max(room, 1)) : body
        return clipped + " " + confirmCue
    }

    public static func sessionsSpeech(_ sessions: [GrokSession]) -> String {
        if sessions.isEmpty { return "No sessions." }
        let count = sessions.count == 1 ? "1 session." : "\(sessions.count) sessions."
        let lines = sessions.prefix(3).map { session in
            "\(collapsed(session.title)), \(session.status.title)."
        }
        var sentence = ([count] + lines).joined(separator: " ")
        if sessions.count > 3 {
            sentence += " And \(sessions.count - 3) more."
        }
        return sentence
    }

    public static func statusSpeech(host: String, linkTitle: String, running: Int, waiting: Int) -> String {
        var parts = ["\(collapsed(host)). \(collapsed(linkTitle))."]
        if waiting > 0 {
            parts.append(waiting == 1 ? "1 task needs approval." : "\(waiting) tasks need approval.")
        } else if running > 0 {
            parts.append(running == 1 ? "1 task is running." : "\(running) tasks are running.")
        } else {
            parts.append("Nothing is running.")
        }
        return parts.joined(separator: " ")
    }

    public static func shortTask(_ prompt: String) -> String {
        PhoneSnapshot.clip(collapsed(prompt), limit: 80)
    }

    /// One saved computer label, or nil when the spoken name is missing or ambiguous.
    /// A short fragment does not match. "example host" still matches "example-host".
    public static func matchingLabel(spoken: String, labels: [String]) -> String? {
        let needle = fold(spoken)
        guard !needle.isEmpty else { return nil }
        let exact = labels.filter { fold($0) == needle }
        if exact.count == 1 { return exact[0] }
        if !exact.isEmpty { return nil }
        guard needle.count >= 3 else { return nil }
        let partial = labels.filter { label in
            let folded = fold(label)
            guard folded.count >= 3 else { return false }
            return folded.contains(needle) || needle.contains(folded)
        }
        guard partial.count == 1 else { return nil }
        return partial[0]
    }

    private static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: " ")
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum VoiceDialogueMatcher {
    public static func interpret(_ transcript: String, phase: VoiceDialogue) -> VoiceCommand {
        let phrase = stripPolite(normalize(transcript))
        if phrase.isEmpty {
            return .unrecognized
        }
        if phase == .awaitingAllowYes, yesPhrases.contains(phrase) {
            return .confirmAllow
        }
        if denyPhrases.contains(phrase) {
            return .deny
        }
        if stopSessionPhrases.contains(phrase) {
            return .stopSession
        }
        if stopPhrases.contains(phrase) {
            return .stop
        }
        if allowPhrases.contains(phrase) {
            return .requestAllow
        }
        if listPhrases.contains(phrase) {
            return .listSessions
        }
        if statusPhrases.contains(phrase) {
            return .status
        }
        if let target = switchTarget(phrase) {
            let name = target.trimmingCharacters(in: .whitespaces)
            return .switchComputer(name.isEmpty ? nil : name)
        }
        if phase == .awaitingAllowYes, declinePhrases.contains(phrase) {
            return .cancelConfirm
        }
        if yesPhrases.contains(phrase) {
            return .unrecognized
        }
        guard let task = VoiceTaskPolicy.normalizedTask(transcript) else {
            return .unrecognized
        }
        return .newTask(task)
    }

    static func normalize(_ text: String) -> String {
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

    /// nil when the phrase is not a switch command. Empty asks which computer.
    private static func switchTarget(_ phrase: String) -> String? {
        if phrase == "switch" || phrase == "switch to" || phrase == "switch computer"
            || phrase == "switch computers" || phrase == "switch computer to" {
            return ""
        }
        let prefixes = ["switch computer to ", "switch to ", "switch computer "]
        for prefix in prefixes where phrase.hasPrefix(prefix) {
            let name = String(phrase.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == "to" { return "" }
            return name
        }
        return nil
    }

    private static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "confirm", "yes confirm", "confirm yes", "ok", "okay", "go ahead",
    ]
    private static let allowPhrases: Set<String> = [
        "allow", "allow it", "allow this", "allow that", "allow once",
        "allow this action", "allow the action",
        "approve", "approve it", "approve this", "approve that", "approve once", "approved",
        "accept", "accept it",
    ]
    private static let denyPhrases: Set<String> = [
        "deny", "deny it", "deny this", "deny that", "deny once", "denied",
        "reject", "reject it", "reject this", "refuse", "refuse it",
        "no", "no thanks",
        "don't allow", "dont allow", "do not allow",
        "don't approve", "dont approve", "do not approve",
    ]
    private static let stopPhrases: Set<String> = [
        "stop", "stop it", "stop this", "stop that", "stop the task", "stop task", "stopped",
        "halt", "halt it", "halt the task",
        "cancel", "cancel it", "cancel that", "cancel the task",
        "end", "end it", "end the task",
    ]
    private static let stopSessionPhrases: Set<String> = [
        "stop session", "stop the session", "stop this session", "stop current session",
    ]
    private static let listPhrases: Set<String> = [
        "list sessions", "list the sessions", "show sessions", "show the sessions",
    ]
    private static let statusPhrases: Set<String> = [
        "status", "session status", "what's the status", "whats the status", "what is the status",
    ]
    private static let declinePhrases: Set<String> = [
        "never mind", "not now", "forget it",
    ]
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
