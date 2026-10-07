import Foundation

/// How a listen ends.
///
/// Manual is the default: Speak, the Action Button, and I'm done.
/// Pause is optional. Silence ends the turn only in that mode.
public enum ListenEndpointMode: String, Equatable, Sendable {
    case manual
    case pause
}

public enum ListenEndpoint {
    public static let manualTitle = "Action Button"
    public static let actionBarLabel = "Action"
    public static let pauseBarLabel = "Pause"
    public static let doneTitle = "I'm done"
    public static let manualHint = "Listening. Action Button or I'm done sends."
    public static let waitingManual = "Waiting for the iPhone app. I'm done sends."
    public static let ownerDefault = ListenEndpointMode.manual

    public static func endsOnSilence(pauseSends: Bool) -> Bool {
        pauseSends
    }

    public static func hint(pauseSends: Bool) -> String {
        if pauseSends {
            return VoiceSpeechCopy.listeningHint
        }
        return manualHint
    }

    public static func title(pauseSends: Bool) -> String {
        if pauseSends {
            return VoiceSpeechCopy.pauseSends
        }
        return manualTitle
    }

    /// Short label for the bottom bar. The full title stays on the accessibility label.
    public static func barLabel(pauseSends: Bool) -> String {
        pauseSends ? pauseBarLabel : actionBarLabel
    }

    public static func waiting(pauseSends: Bool) -> String {
        if pauseSends {
            return VoiceSpeechCopy.waitingForPhone
        }
        return waitingManual
    }
}

/// What the direct socket just did. The Watch maps this to a banner.
public enum RelaySocketFault: Equatable, Sendable {
    case authSendFailed
    case authPayload(String)
    case dataSendFailed
    case disconnected
    case suspended
}

/// User-facing result of a relay fault.
///
/// `pairingRejected` is only produced from an auth payload whose `ok` field is present and not true.
public enum RelayUserNotice: Equatable, Sendable {
    case accepted
    case reconnecting
    case pairingRejected
    case ignored

    public static let pairingRejectedText = "This relay did not accept this pairing."
    public static let reconnectingText = "Reconnecting…"
    public static let repairText = "Pair again on iPhone."

    public static func classify(_ fault: RelaySocketFault) -> RelayUserNotice {
        switch fault {
        case .authSendFailed, .dataSendFailed, .disconnected, .suspended:
            return .reconnecting
        case .authPayload(let text):
            return classifyAuth(text)
        }
    }

    /// Nil keeps the current screen quiet.
    /// The pairing-reject sentence is returned only when auth JSON is explicitly not ok.
    public static func banner(for fault: RelaySocketFault, displayOff: Bool) -> String? {
        switch classify(fault) {
        case .accepted, .ignored:
            return nil
        case .reconnecting:
            if displayOff {
                return nil
            }
            return reconnectingText
        case .pairingRejected:
            return pairingRejectedText
        }
    }

    private static func classifyAuth(_ text: String) -> RelayUserNotice {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] else {
            return .ignored
        }
        if let flag = ok as? Bool {
            return flag ? .accepted : .pairingRejected
        }
        if let number = ok as? NSNumber {
            return number.boolValue ? .accepted : .pairingRejected
        }
        if let word = ok as? String {
            return (word == "true" || word == "1") ? .accepted : .pairingRejected
        }
        return .pairingRejected
    }
}
