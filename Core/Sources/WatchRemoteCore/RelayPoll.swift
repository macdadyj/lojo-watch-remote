import Foundation

/// The Watch's side of the relay's `POST /v1/watch` long-poll.
///
/// A real Apple Watch refuses WebSockets to ordinary apps (TN3135), so the Watch
/// reaches the relay with plain HTTPS: each request carries sealed frames for the
/// computer and returns sealed frames for the Watch. The relay keeps frames until a
/// later poll acks them with `after`, so a reply is not lost when a poll dies.
public enum RelayPoll {
    public static let maxWaitMilliseconds = 25_000
    /// How long the Watch asks the relay to hold one poll. Shorter than `maxWaitMilliseconds`:
    /// a silent poll this long still returns, and a longer one is dropped on the Watch's own radio.
    public static let watchWaitMilliseconds = 8_000
    /// Seconds before another poll after the Watch itself has no network. This is not relay backoff.
    public static let noNetworkRetrySeconds = 1.0
    public static let maxFramesPerRequest = 16
    /// Failed polls in a row before the Watch says it is reconnecting. The first poll after a
    /// wrist raise often dies with the suspended request, and that is not worth a banner.
    public static let troubleAfterFailures = 2
    /// Failed polls in a row, roughly 15 seconds of backoff, before turns stop counting on the relay.
    public static let unreachableAfterFailures = 4

    /// The pairing stores the host's `wss://…/v1/room` address. The Watch polls the same relay over https.
    public static func pollURL(fromRelayURL text: String) -> URL? {
        guard let normalized = RelayMaterial.normalizeURL(text),
              var components = URLComponents(string: normalized) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1/room") {
            path.removeLast("/v1/room".count)
        }
        components.path = path + "/v1/watch"
        return components.url
    }

    public struct Request: Codable, Equatable, Sendable {
        public var send: [String]
        public var after: Int
        public var epoch: String
        public var wait: Int

        public init(send: [String], after: Int, epoch: String, wait: Int) {
            self.send = send
            self.after = after
            self.epoch = epoch
            self.wait = wait
        }
    }

    public struct Frame: Codable, Equatable, Sendable {
        public var seq: Int
        public var data: String

        public init(seq: Int, data: String) {
            self.seq = seq
            self.data = data
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var ok: Bool
        public var epoch: String?
        public var host: Bool?
        public var frames: [Frame]?
        public var error: String?

        public init(ok: Bool, epoch: String? = nil, host: Bool? = nil, frames: [Frame]? = nil, error: String? = nil) {
            self.ok = ok
            self.epoch = epoch
            self.host = host
            self.frames = frames
            self.error = error
        }
    }

    public static func encode(_ request: Request) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(request)
    }

    public static func decode(_ data: Data) -> Response? {
        try? JSONDecoder().decode(Response.self, from: data)
    }

    /// What one HTTP status means for the link.
    public enum Outcome: Equatable, Sendable {
        case ok
        /// The token was refused. Pairing again is the only fix.
        case pairingRejected
        /// This relay predates the Watch poll. It has to be redeployed.
        case relayOutdated
        /// Too many requests. Wait longer before the next try.
        case slowDown
        /// Anything else: retry with backoff.
        case retry
    }

    public static func outcome(status: Int) -> Outcome {
        switch status {
        case 200:
            return .ok
        case 401, 403:
            return .pairingRejected
        case 404, 405:
            return .relayOutdated
        case 429:
            return .slowDown
        default:
            return .retry
        }
    }

    public static let relayOutdatedText = "This relay needs an update for the Watch. Redeploy it from the repo."

    /// Seconds the Watch waits for one poll to finish, including the relay's hold.
    public static func watchTimeoutSeconds(waitMilliseconds: Int) -> Double {
        Double(waitMilliseconds) / 1000 + 12
    }

    /// Why one poll failed. "No network" means the Watch's own radio has no path.
    /// That is separate from the relay answering that the computer is offline.
    public enum WatchPollFailure: Equatable, Sendable {
        case notConnectedToInternet
        case dataNotAllowed
        case timedOut
        case networkConnectionLost
        case cannotReachHost
        case tls
        case transportSecurity
        case other
    }

    public enum WatchPollFault: Equatable, Sendable {
        case noNetwork
        case relayUnreachable
    }

    public static func fault(_ failure: WatchPollFailure, waitedForConnectivity: Bool) -> WatchPollFault {
        switch failure {
        case .notConnectedToInternet, .dataNotAllowed:
            return .noNetwork
        case .timedOut:
            return waitedForConnectivity ? .noNetwork : .relayUnreachable
        case .networkConnectionLost, .cannotReachHost, .tls, .transportSecurity, .other:
            return .relayUnreachable
        }
    }

    public static func detail(_ failure: WatchPollFailure, waitedForConnectivity: Bool) -> String {
        if fault(failure, waitedForConnectivity: waitedForConnectivity) == .noNetwork {
            return "The Watch has no network."
        }
        switch failure {
        case .timedOut:
            return "The relay did not answer in time."
        case .networkConnectionLost:
            return "The relay connection dropped."
        case .cannotReachHost:
            return "The relay could not be reached."
        case .tls:
            return "The relay's certificate was refused."
        case .transportSecurity:
            return "App Transport Security blocked the relay address."
        case .notConnectedToInternet, .dataNotAllowed, .other:
            return "The relay connection failed."
        }
    }

    /// Seconds before the next attempt after `failures` failures in a row.
    public static func backoff(failures: Int, outcome: Outcome) -> Double {
        switch outcome {
        case .ok:
            return 0
        case .relayOutdated:
            return 30
        case .slowDown:
            return 10
        case .pairingRejected:
            return 60
        case .retry:
            let step = max(0, min(failures, 5))
            return min(8.0, 0.5 * pow(2.0, Double(step)))
        }
    }
}

/// Which relay frames the Watch has already taken, by sequence number.
public struct RelayPollCursor: Equatable, Sendable {
    public private(set) var after = 0
    public private(set) var epoch = ""

    public init(after: Int = 0, epoch: String = "") {
        self.after = after
        self.epoch = epoch
    }

    /// Frames from one response that have not been seen yet, in order.
    /// A new epoch means the relay restarted or recreated the room: start counting again.
    public mutating func take(_ response: RelayPoll.Response) -> [RelayPoll.Frame] {
        if let epoch = response.epoch, epoch != self.epoch {
            self.epoch = epoch
            after = 0
        }
        let fresh = (response.frames ?? []).filter { $0.seq > after }.sorted { $0.seq < $1.seq }
        if let last = fresh.last {
            after = last.seq
        }
        return fresh
    }
}

/// Which frames from one poll the Watch should apply.
///
/// The relay keeps host frames until a later poll acks them. A Watch that has not
/// saved its cursor is handed that backlog again. Session updates describe the
/// computer now and still apply. A command reply applies only when this Watch
/// issued that id, so an old `ok` or `started` cannot satisfy a new command.
public enum WatchFrameFilter {
    public static func accepts(op: DirectMessage.Op, id: String, issued: Set<String>) -> Bool {
        switch op {
        case .sessions, .update:
            return true
        case .started, .ok, .pong, .restored, .transcript, .error, .result:
            return issued.contains(id)
        case .list, .start, .approve, .deny, .stop, .ping, .resume, .transcribe, .authorize:
            return false
        }
    }
}

/// What the computer says when the Watch asks again for a command.
public enum WatchReceipt {
    public static let pending = "pending"
    public static let done = "done"
    public static let failed = "error"
    public static let unknown = "unknown"

    /// The computer never saw this command. Sending the same id again does not start a second turn
    /// once the first one is recorded.
    public static func resend(_ status: String?) -> Bool {
        status == unknown
    }
}

/// Frame counters follow the clock so a Watch that lost its saved counter still moves past the computer's replay window.
public enum RelayCounter {
    public static func next(after previous: UInt64, now: Date = Date()) -> UInt64 {
        let clock = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        return max(previous &+ 1, clock)
    }
}
