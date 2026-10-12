import Foundation

/// How a Watch turn reaches the computer.
public enum WatchTurnPath: Equatable, Sendable {
    /// Straight to the relay. It does not depend on the iPhone app staying awake.
    case relay
    /// Through the iPhone app with WatchConnectivity.
    case phone
    /// Nothing is paired yet.
    case unavailable
}

public enum WatchRouting {
    /// The relay goes first whenever the Watch has a pairing. iOS suspends the iPhone app in
    /// the background, so a reply that depends on it can stall halfway. The iPhone is used
    /// when there is no relay pairing, or when the relay says the computer is not connected.
    public static func path(hasRelayPairing: Bool, relayHostOnline: Bool?, phoneReachable: Bool, phoneActivated: Bool) -> WatchTurnPath {
        if hasRelayPairing {
            if relayHostOnline == false && phoneReachable {
                return .phone
            }
            return .relay
        }
        if phoneReachable || phoneActivated {
            return .phone
        }
        return .unavailable
    }

    /// What routing believes about the computer behind the relay. The last thing the relay said
    /// stands through a few lost polls and through wrist-down. Sending a turn to a suspended
    /// iPhone app instead leaves it at "Sent" with no reply.
    public static func relayHostOnline(relayUp: Bool, relayFailed: Bool, failures: Int, lastHostOnline: Bool?) -> Bool? {
        if relayFailed {
            return false
        }
        if !relayUp && failures >= RelayPoll.unreachableAfterFailures {
            return false
        }
        return lastHostOnline
    }

    /// One session list from the relay and the iPhone. Relay rows win for the same id because
    /// they come straight from the computer; the longer transcript wins when only one side has it.
    public static func mergeSessions(relay: [GrokSession], phone: [GrokSession]) -> [GrokSession] {
        var merged: [GrokSession] = []
        var seen = Set<String>()
        let phoneByID = Dictionary(phone.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in relay where seen.insert(row.id).inserted {
            if let other = phoneByID[row.id], (other.transcript?.count ?? 0) > (row.transcript?.count ?? 0) {
                var copy = row
                copy.transcript = other.transcript
                merged.append(copy)
            } else {
                merged.append(row)
            }
        }
        for row in phone where seen.insert(row.id).inserted {
            merged.append(row)
        }
        return merged
    }

    /// After a new chat is sent through the iPhone, find the session it created: one that was not
    /// there before and whose transcript or title carries the prompt.
    public static func newChat(for prompt: String, known: Set<String>, in sessions: [GrokSession]) -> GrokSession? {
        let needle = fold(prompt)
        guard !needle.isEmpty else { return nil }
        let fresh = sessions.filter { !known.contains($0.id) }
        if let match = fresh.first(where: { session in
            (session.transcript ?? []).contains { fold(ChatTranscript.spokenText($0)) == needle }
        }) {
            return match
        }
        if let match = fresh.first(where: { session in
            let title = fold(session.title)
            return !title.isEmpty && needle.hasPrefix(title)
        }) {
            return match
        }
        return fresh.count == 1 ? fresh.first : nil
    }

    /// True once the open chat has a reply after the last thing the user said.
    public static func hasReply(after prompt: String, in transcript: [String]) -> Bool {
        let needle = fold(prompt)
        guard let index = transcript.lastIndex(where: { line in
            line.hasPrefix("You:") && (needle.isEmpty || fold(ChatTranscript.spokenText(line)) == needle)
        }) else { return false }
        return transcript[transcript.index(after: index)...].contains { $0.hasPrefix("Grok:") }
    }

    /// True when the transcript already carries these words as something the user said.
    public static func mentions(_ prompt: String, in transcript: [String]) -> Bool {
        let needle = fold(prompt)
        return transcript.contains { $0.hasPrefix("You:") && fold(ChatTranscript.spokenText($0)) == needle }
    }

    /// The sentence the Watch shows about the link, or nil when the turn path is healthy.
    /// "Reconnecting…" means the relay itself is unreachable; "Computer offline" means the relay
    /// answers but the computer is not in the room. Either one is moot while the iPhone carries turns.
    public static func notice(hasRelayPairing: Bool, relayUp: Bool, relayTrouble: Bool, relayHostOnline: Bool?, phoneReachable: Bool) -> String? {
        guard hasRelayPairing, !phoneReachable else { return nil }
        if !relayUp {
            return relayTrouble ? RelayUserNotice.reconnectingText : nil
        }
        return relayHostOnline == false ? RelayUserNotice.computerOfflineText : nil
    }

    static func fold(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
    }
}

/// The Watch's auto-approve default, kept in step with the iPhone's, plus per-chat overrides.
///
/// The latest change wins on either device. A change made on the Watch is held until the
/// iPhone reports the same value, so a stale snapshot cannot flip it back.
public struct WatchApprovalSetting: Codable, Equatable, Sendable {
    public var value: Bool
    /// The last value the iPhone reported. Nil before the first snapshot.
    public var lastPhone: Bool?
    /// The Watch changed the default and the iPhone has not confirmed it yet.
    public var awaitingPhone: Bool
    public var chats: [String: Bool]

    /// On until someone turns it off: tool calls run without a tap.
    public init(value: Bool = true, lastPhone: Bool? = nil, awaitingPhone: Bool = false, chats: [String: Bool] = [:]) {
        self.value = value
        self.lastPhone = lastPhone
        self.awaitingPhone = awaitingPhone
        self.chats = chats
    }

    /// The iPhone reported its setting. True when the Watch default changed.
    @discardableResult
    public mutating func notePhone(_ phoneValue: Bool) -> Bool {
        if awaitingPhone {
            guard phoneValue == value else { return false }
            awaitingPhone = false
            lastPhone = phoneValue
            return false
        }
        guard lastPhone != phoneValue else { return false }
        lastPhone = phoneValue
        guard value != phoneValue else { return false }
        value = phoneValue
        return true
    }

    /// The user changed the default on the Watch. True when it differs from before.
    @discardableResult
    public mutating func chooseOnWatch(_ newValue: Bool) -> Bool {
        guard value != newValue else { return false }
        value = newValue
        awaitingPhone = lastPhone != newValue
        return true
    }

    public func allows(chat id: String?) -> Bool {
        guard let id, let override = chats[id] else { return value }
        return override
    }

    public mutating func setChat(_ id: String, to newValue: Bool?) {
        if let newValue {
            chats[id] = newValue
        } else {
            chats.removeValue(forKey: id)
        }
    }
}
