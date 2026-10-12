import Foundation

/// The Watch's side of the relay's `POST /v1/watch` long-poll.
///
/// A real Apple Watch refuses WebSockets to ordinary apps (TN3135), so the Watch
/// reaches the relay with plain HTTPS: each request carries sealed frames for the
/// computer and returns sealed frames for the Watch. The relay keeps frames until a
/// later poll acks them with `after`, so a reply is not lost when a poll dies.
public enum RelayPoll {
    public static let maxWaitMilliseconds = 25_000
    public static let maxFramesPerRequest = 16

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

    public init() {}

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

/// Frame counters follow the clock so a Watch that lost its saved counter still moves past the computer's replay window.
public enum RelayCounter {
    public static func next(after previous: UInt64, now: Date = Date()) -> UInt64 {
        let clock = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        return max(previous &+ 1, clock)
    }
}
