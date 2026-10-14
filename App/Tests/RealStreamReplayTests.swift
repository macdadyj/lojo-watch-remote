import XCTest
import WatchRemoteCore

/// Frames recorded from real Grok Build 1.0.52 through the agent door by e2e/real_host_check.py
/// (fixtures made with e2e/make_fixtures.py), replayed through the phone's transcript rules:
/// ACPCodec, ChatFold, TurnTracker, and SessionResume.merge, in the order RemoteStore uses them.
/// Each `check` event holds the transcript the run asserted on the real computer.
final class RealStreamReplayTests: XCTestCase {
    func testANewChatShowsThePromptFirstAndASecondPromptBelowItsAnswer() throws {
        try replay("real-turns")
    }

    func testReopeningReplacesAStaleOutOfOrderCacheWithTheComputersOrder() throws {
        try replay("real-reopen")
    }

    func testAPhoneBackgroundedMidTurnGetsTheFinalAnswerAfterResuming() throws {
        try replay("real-background")
    }

    func testARelaunchedAppAnswersTheApprovalThatWasWaiting() throws {
        try replay("real-relaunch")
    }

    func testTwoChatsStreamingAtOnceKeepTheirOwnText() throws {
        try replay("real-crossing")
    }

    func testAPhoneChatBesideAWatchChatGetsOnlyItsOwnStream() throws {
        try replay("real-together")
    }

    private func replay(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try Self.load(name)
        var phone = PhoneReplay(events: fixture)
        var checks = 0
        for (index, event) in fixture.enumerated() {
            if event["k"] as? String == "check" {
                let session = event["s"] as? String ?? ""
                let expected = event["transcript"] as? [String] ?? []
                let chat = phone.chats[session]
                XCTAssertEqual(chat?.transcript, expected, "\(name): chat \(session.suffix(8)) after check \(checks + 1)", file: file, line: line)
                XCTAssertEqual(chat?.status, "idle", "\(name): chat \(session.suffix(8)) is not finished", file: file, line: line)
                if let first = event["first"] as? String {
                    XCTAssertEqual(chat?.transcript.first, first, "\(name): the prompt is not the first line", file: file, line: line)
                }
                checks += 1
            } else {
                phone.play(event, at: index)
            }
        }
        XCTAssertGreaterThan(checks, 0, "\(name) has no checks", file: file, line: line)
    }

    private static func load(_ name: String) throws -> [[String: Any]] {
        let source = URL(fileURLWithPath: #filePath)
        let candidates = [
            Bundle(for: RealStreamReplayTests.self).url(forResource: name, withExtension: "json"),
            source.deletingLastPathComponent().appendingPathComponent("../../e2e/fixtures/\(name).json").standardizedFileURL,
            ProcessInfo.processInfo.environment["WATCHREMOTE_FIXTURES"].map { URL(fileURLWithPath: $0).appendingPathComponent("\(name).json") },
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("fixture \(name).json is not in the test bundle or e2e/fixtures")
        }
        let data = try Data(contentsOf: url)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["events"] as? [[String: Any]])
    }
}

/// RemoteStore's SSH path, driven by recorded frames and the run's own UI steps.
private struct PhoneReplay {
    struct Chat {
        var transcript: [String] = []
        var status = "idle"
        var fold = ChatFold(live: true)
        var turns = TurnTracker()
        /// Prompts on screen whose `session/prompt` has not gone out yet (continueSSH loads first).
        var unsent: [Int] = []
    }

    var chats: [String: Chat] = [:]
    private let events: [[String: Any]]
    /// Auto-approval marks already applied at their approval request.
    private var applied: Set<Int> = []
    private var codec = ACPCodec()
    private var prompts: [String: (session: String, generation: Int)] = [:]
    private var loads: [String: (session: String, continuing: Bool)] = [:]
    private var captures: [String: [StreamEvent]] = [:]

    init(events: [[String: Any]]) {
        self.events = events
    }

    mutating func play(_ event: [String: Any], at index: Int) {
        let frame = event["f"] as? [String: Any] ?? [:]
        switch event["k"] as? String {
        case "ui":
            if !applied.contains(index) { ui(event) }
        case "out":
            outgoing(frame)
        case "in":
            guard let data = try? JSONSerialization.data(withJSONObject: frame),
                  let text = String(data: data, encoding: .utf8),
                  let inbound = codec.parse(text) else { return }
            incoming(inbound, raw: text, at: index)
        default:
            break
        }
    }

    /// The run records an auto-approval when the phone applied it, which can be a few frames after
    /// the request when the request waited for a reload. It belongs to the request.
    private func autoApproval(for session: String, after index: Int) -> Int? {
        for later in events.indices where later > index {
            let event = events[later]
            guard event["k"] as? String == "ui" else { continue }
            if event["a"] as? String == "killed" { return nil }
            if event["a"] as? String == "autoApproved", event["s"] as? String == session, !applied.contains(later) {
                return later
            }
        }
        return nil
    }

    private mutating func ui(_ event: [String: Any]) {
        let session = event["s"] as? String ?? ""
        switch event["a"] as? String {
        case "prompt":
            var chat = chats[session] ?? Chat()
            chat.transcript = ChatTranscript.append("You: \(event["text"] as? String ?? "")", to: chat.transcript)
            chat.status = "running"
            chat.unsent.append(chat.turns.sent())
            chats[session] = chat
        case "cache":
            var chat = chats[session] ?? Chat()
            chat.transcript = event["lines"] as? [String] ?? []
            chat.fold.forgetTools()
            chats[session] = chat
        case "autoApproved":
            guard var chat = chats[session] else { return }
            chat.transcript = ChatTranscript.notingAutoApproval(event["title"] as? String ?? "", in: chat.transcript)
            chat.status = "running"
            chats[session] = chat
        case "killed":
            chats = [:]
            codec = ACPCodec()
            prompts = [:]
            loads = [:]
            captures = [:]
        default:
            break
        }
    }

    private mutating func outgoing(_ frame: [String: Any]) {
        guard let id = frame["id"].map({ "\($0)" }), let method = frame["method"] as? String else { return }
        let session = (frame["params"] as? [String: Any])?["sessionId"] as? String ?? ""
        switch method {
        case "session/prompt":
            guard var chat = chats[session], !chat.unsent.isEmpty else { return }
            prompts[id] = (session, chat.unsent.removeFirst())
            chats[session] = chat
        case "session/load":
            loads[id] = (session, !(chats[session]?.unsent.isEmpty ?? true))
            captures[session] = []
        default:
            break
        }
    }

    private mutating func incoming(_ inbound: ACPInbound, raw: String, at index: Int) {
        switch inbound {
        case .update(let session, let event):
            if captures[session] != nil {
                captures[session]?.append(event)
            } else {
                stream(event, session: session)
            }
        case .permission(let request):
            chats[request.sessionID, default: Chat()].status = "needsApproval"
            if let mark = autoApproval(for: request.sessionID, after: index) {
                applied.insert(mark)
                ui(events[mark])
            }
        case .activity(let rows):
            for row in rows where row.working {
                if let status = chats[row.sessionID]?.status, ["idle", "stopped", "failed"].contains(status) {
                    chats[row.sessionID]?.status = "running"
                }
            }
        case .result(let id, _, _):
            if let load = loads.removeValue(forKey: id) {
                loaded(load.session, continuing: load.continuing, raw: raw)
            } else if let prompt = prompts.removeValue(forKey: id) {
                let reason = Self.stopReason(raw)
                if chats[prompt.session]?.turns.answered(generation: prompt.generation) == true {
                    chats[prompt.session]?.status = reason == "cancelled" ? "stopped" : "idle"
                }
            }
        case .failure(let id, _, _):
            if let load = loads.removeValue(forKey: id) {
                captures[load.session] = nil
            } else if let prompt = prompts.removeValue(forKey: id),
                      chats[prompt.session]?.turns.answered(generation: prompt.generation) == true {
                chats[prompt.session]?.status = "failed"
            }
        case .notification:
            break
        }
    }

    private mutating func stream(_ event: StreamEvent, session: String) {
        guard var chat = chats[session] else { return }
        switch event {
        case .user, .text, .tool, .toolCall:
            chat.transcript = chat.fold.apply(event, to: chat.transcript)
            if chat.status != "needsApproval" { chat.status = "running" }
        case .toolCallUpdate:
            chat.transcript = chat.fold.apply(event, to: chat.transcript)
        case .turnStarted(let promptID):
            chat.turns.started(promptID)
            if chat.status != "needsApproval" { chat.status = "running" }
        case .turnComplete(let promptID, let reason):
            if chat.turns.completed(promptID) {
                chat.status = reason == "cancelled" ? "stopped" : "idle"
            }
        case .thought, .toolUpdate, .title, .usage, .end, .error, .ignored:
            break
        }
        chats[session] = chat
    }

    private mutating func loaded(_ session: String, continuing: Bool, raw: String) {
        let replay = captures.removeValue(forKey: session) ?? []
        var chat = chats[session] ?? Chat()
        let host = replay.isEmpty ? SessionResume.transcriptLines(inLoadJSON: raw) : ChatFold.replay(replay)
        chat.transcript = SessionResume.merge(local: chat.transcript, host: host)
        chat.fold.forgetTools()
        if !continuing {
            let running = ACPCodec.runningPromptID(inLoadResultJSON: raw)
            chat.turns.loaded(runningPromptID: running)
            if chat.status != "needsApproval" {
                chat.status = running == nil ? "idle" : "running"
            }
        }
        chats[session] = chat
    }

    private static func stopReason(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return "end_turn" }
        return result["stopReason"] as? String ?? "end_turn"
    }
}
