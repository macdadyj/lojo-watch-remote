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
    /// when there is no relay pairing, when the relay says the computer is not connected,
    /// or when the Watch itself has no network and the iPhone is reachable.
    public static func path(
        hasRelayPairing: Bool,
        relayHostOnline: Bool?,
        phoneReachable: Bool,
        phoneActivated: Bool,
        watchHasNetwork: Bool = true,
        phoneCanSSH: Bool = true
    ) -> WatchTurnPath {
        if hasRelayPairing {
            // A phone with no key yet cannot carry a turn. The relay still can, and it auto-approves.
            if !watchHasNetwork && phoneReachable && phoneCanSSH {
                return .phone
            }
            if relayHostOnline == false && phoneReachable && phoneCanSSH {
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

    /// Post sealed frames only after the relay has not said the computer is gone.
    /// Nil is the first poll: those frames may wait in the room. False means this relay
    /// process has no computer socket, so a posted frame would sit there with no reply.
    public static func shouldPost(hostOnline: Bool?) -> Bool {
        hostOnline != false
    }

    /// Polls with `host == false` and `hostSeen == false` before the Watch says to re-pair.
    /// Each quiet poll waits about eight seconds. Ten of them cover the computer's redial
    /// after a relay restart, which forgets `hostSeen` until the computer joins again.
    /// A room that never had a computer stays false past this window.
    public static let staleHostPolls = 10

    /// True when this relay process has answered and this room has never had a computer.
    /// A missing `hostSeen` (an older relay) is unknown, not stale.
    public static func needsRepair(hostOnline: Bool?, hostSeen: Bool?, unhostedPolls: Int) -> Bool {
        hostOnline == false && hostSeen == false && unhostedPolls >= staleHostPolls
    }

    /// What an open turn should say. A computer the relay has marked offline keeps the
    /// message on the Watch. "Still waiting" is only for a turn that was actually sent.
    /// A stale pairing says to re-pair instead of waiting.
    public static func turnStatus(current: String, computerOffline: Bool, slow: Bool, repair: Bool = false) -> String {
        let pending = [
            "", "Sent", "Sending",
            RelayUserNotice.stillWaitingText,
            RelayUserNotice.queuedOfflineText,
            RelayUserNotice.repairNeededText,
        ]
        guard pending.contains(current) else { return current }
        if repair {
            return RelayUserNotice.repairNeededText
        }
        if current == RelayUserNotice.repairNeededText {
            return computerOffline ? RelayUserNotice.queuedOfflineText : "Sending"
        }
        if computerOffline {
            return RelayUserNotice.queuedOfflineText
        }
        if current == RelayUserNotice.queuedOfflineText {
            return "Sending"
        }
        if slow && (current.isEmpty || current == "Sent" || current == "Sending") {
            return RelayUserNotice.stillWaitingText
        }
        return current
    }

    /// The sentence the Watch shows about the link, or nil when the turn path is healthy.
    /// "No network" means the Watch's own radio has no path. "Reconnecting…" means the radio is up
    /// and the relay is not answering. "Computer offline" means this relay process answered and
    /// the computer's socket is not in the room. "Re-pair needed" means the room has never had a
    /// computer. A missing `hostSeen` stays "Computer offline". The room token does not expire.
    /// These stay quiet while the iPhone can carry turns.
    public static func notice(
        hasRelayPairing: Bool,
        relayUp: Bool,
        relayTrouble: Bool,
        relayHostOnline: Bool?,
        phoneReachable: Bool,
        noNetwork: Bool = false,
        phoneCanSSH: Bool = true,
        hostSeen: Bool? = nil,
        unhostedPolls: Int = 0
    ) -> String? {
        guard hasRelayPairing else { return nil }
        let repair = relayUp && needsRepair(hostOnline: relayHostOnline, hostSeen: hostSeen, unhostedPolls: unhostedPolls)
        if noNetwork && !phoneReachable {
            return RelayUserNotice.noNetworkText
        }
        if repair && (!phoneReachable || !phoneCanSSH) {
            return RelayUserNotice.repairNeededText
        }
        guard !phoneReachable else { return nil }
        if !relayUp {
            return relayTrouble ? RelayUserNotice.reconnectingText : nil
        }
        if repair {
            return RelayUserNotice.repairNeededText
        }
        return relayHostOnline == false ? RelayUserNotice.computerOfflineText : nil
    }

    /// Header text stays short. The banner carries the re-pair steps.
    public static func connectionBanner(_ notice: String?) -> String? {
        if notice == RelayUserNotice.repairNeededText {
            return RelayUserNotice.repairNeededSteps
        }
        return notice
    }

    /// The words a person sees for a path. Diagnostics keep the short internal name.
    public static func routeTitle(_ pathTitle: String) -> String {
        if pathTitle == "direct" {
            return "On this Watch"
        }
        if pathTitle == "via iPhone" {
            return "Through iPhone"
        }
        return pathTitle
    }

    /// One status line. A link problem replaces the route name.
    public static func statusLine(notice: String?, pathTitle: String) -> String {
        if let notice, !notice.isEmpty {
            return notice
        }
        return routeTitle(pathTitle)
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
