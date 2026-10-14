import CoreFoundation
import Foundation

public enum ACPInbound: Equatable, Sendable {
    case result(id: String, isNumber: Bool, value: ACPValue)
    case failure(id: String, isNumber: Bool, message: String)
    case update(sessionID: String, event: StreamEvent)
    case permission(PermissionRequest)
    case activity([SessionActivity])
    case notification(method: String)
}

/// One row of Grok's `_x.ai/sessions/changed`: whether a chat is working right now.
public struct SessionActivity: Equatable, Sendable {
    public var sessionID: String
    public var working: Bool

    public init(sessionID: String, working: Bool) {
        self.sessionID = sessionID
        self.working = working
    }
}

public enum ACPValue: Equatable, Sendable {
    case object([String: String])
    case raw(String)
}

/// ACP JSON-RPC used by `grok agent serve` (protocol version 1, with a tolerant read of later fields).
public struct ACPCodec: Sendable {
    public private(set) var nextID: Int

    public init(nextID: Int = 1) {
        self.nextID = nextID
    }

    public mutating func initialize() -> (Int, String) {
        request(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
            "clientInfo": ["name": "Watch Remote", "version": "1.0"],
        ])
    }

    public mutating func newSession(cwd: String) -> (Int, String) {
        request(method: "session/new", params: [
            "cwd": cwd,
            "mcpServers": [Any](),
            "_meta": ["yoloMode": false, "autoMode": false],
        ])
    }

    public mutating func prompt(sessionID: String, text: String) -> (Int, String) {
        request(method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": text]],
        ])
    }

    public func cancel(sessionID: String) -> String {
        encode([
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sessionID],
        ])
    }

    /// Grok registers this extension with a leading underscore. The bare name is rejected with "Method not found".
    public mutating func listSessions() -> (Int, String) {
        request(method: "_x.ai/session/list", params: [:])
    }

    /// The agent door's headless path answered this spelling before the underscore was required.
    public mutating func listSessionsLegacy() -> (Int, String) {
        request(method: "x.ai/session/list", params: [:])
    }

    public mutating func loadSession(sessionID: String, cwd: String) -> (Int, String) {
        request(method: "session/load", params: [
            "sessionId": sessionID,
            "cwd": cwd,
            "mcpServers": [Any](),
        ])
    }

    public mutating func sessionUsage(sessionID: String) -> (Int, String) {
        request(method: "_x.ai/session/usage", params: ["sessionId": sessionID])
    }

    /// Missing means the real agent server, which can ask for approval.
    /// The host's headless fallback sets this to false.
    public static func approvalsAvailable(inResultJSON text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let meta = result["_meta"] as? [String: Any],
              let flag = meta["approvals"] as? Bool else { return true }
        return flag
    }

    public func permissionResponse(for request: PermissionRequest, allow: Bool) -> String {
        let outcome: [String: Any]
        if allow, let option = request.allowOptionID {
            outcome = ["outcome": ["outcome": "selected", "optionId": option]]
        } else if !allow, let option = request.denyOptionID {
            outcome = ["outcome": ["outcome": "selected", "optionId": option]]
        } else {
            outcome = ["outcome": ["outcome": "cancelled"]]
        }
        let id: Any = request.rpcIDIsNumber ? (Int(request.rpcID) ?? request.rpcID) : request.rpcID
        return encode(["jsonrpc": "2.0", "id": id, "result": outcome])
    }

    public func parse(_ text: String) -> ACPInbound? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let method = object["method"] as? String {
            return parseMethod(method, object: object)
        }
        let (id, isNumber) = rpcID(object["id"])
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "The agent reported an error."
            return .failure(id: id, isNumber: isNumber, message: message)
        }
        if object["result"] != nil {
            return .result(id: id, isNumber: isNumber, value: .raw(text))
        }
        return nil
    }

    public static func sessionID(inResultJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let result = object["result"] as? [String: Any] {
            return result["sessionId"] as? String
        }
        return object["sessionId"] as? String
    }

    public static func sessions(inResultJSON text: String) -> [GrokSession] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] else { return [] }
        let payload = sessionListPayload(result)
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: encoded, encoding: .utf8) else { return [] }
        return GrokOutput.parseSessionsList(json)
    }

    /// Grok wraps some extension results as `{result: {sessions: [...]}}` inside the JSON-RPC result.
    private static func sessionListPayload(_ result: Any) -> Any {
        guard let object = result as? [String: Any] else { return result }
        if let sessions = object["sessions"] {
            return ["sessions": sessions]
        }
        if let nested = object["result"] as? [String: Any] {
            if let sessions = nested["sessions"] {
                return ["sessions": sessions]
            }
            return nested
        }
        return result
    }

    private mutating func request(method: String, params: [String: Any]) -> (Int, String) {
        let id = nextID
        nextID += 1
        return (id, encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func parseMethod(_ method: String, object: [String: Any]) -> ACPInbound {
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "session/update":
            return .update(sessionID: params["sessionId"] as? String ?? "", event: updateEvent(params["update"]))
        case "session/request_permission":
            let (id, isNumber) = rpcID(object["id"])
            return .permission(permission(id: id, isNumber: isNumber, params: params))
        case "_x.ai/session/prompt_complete":
            // Sent to every connection that has the chat loaded, so a client that reconnected
            // mid-turn still learns the turn ended. The `session/prompt` result only reaches the sender.
            let sessionID = params["sessionId"] as? String ?? ""
            let reason = params["stopReason"] as? String ?? "end_turn"
            let promptID = params["promptId"] as? String ?? ""
            return .update(sessionID: sessionID, event: .turnComplete(promptID: promptID, stopReason: reason.isEmpty ? "end_turn" : reason))
        case "_x.ai/queue/changed":
            guard let sessionID = params["sessionId"] as? String,
                  let running = params["runningPromptId"] as? String, !running.isEmpty else {
                return .notification(method: method)
            }
            return .update(sessionID: sessionID, event: .turnStarted(promptID: running))
        case "_x.ai/sessions/changed":
            let rows = params["upserted"] as? [[String: Any]] ?? []
            let activity = rows.compactMap { row -> SessionActivity? in
                guard let id = row["sessionId"] as? String, !id.isEmpty, let state = row["activity"] as? String else { return nil }
                return SessionActivity(sessionID: id, working: state == "working")
            }
            return activity.isEmpty ? .notification(method: method) : .activity(activity)
        default:
            return .notification(method: method)
        }
    }

    /// `session/load` on a chat whose turn is still running names that turn here.
    public static func runningPromptID(inLoadResultJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let meta = result["_meta"] as? [String: Any],
              let running = meta["x.ai/runningPromptId"] as? String,
              !running.isEmpty else { return nil }
        return running
    }

    private func updateEvent(_ value: Any?) -> StreamEvent {
        guard let update = value as? [String: Any] else { return .ignored }
        let kind = update["sessionUpdate"] as? String ?? ""
        var text = contentText(update["content"])
        if text.isEmpty { text = contentText(update["text"]) }
        if text.isEmpty { text = contentText(update["message"]) }
        switch kind {
        case "user_message_chunk", "user_message":
            return .user(text)
        case "agent_message_chunk", "agent_message":
            return .text(text)
        case "agent_thought_chunk", "agent_thought":
            return .thought(text)
        case "tool_call":
            let title = update["title"] as? String ?? "Tool"
            if let id = update["toolCallId"] as? String, !id.isEmpty {
                return .toolCall(id: id, title: title)
            }
            return .tool(title: title)
        case "tool_call_update":
            let title = (update["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let status = update["status"] as? String
            if let id = update["toolCallId"] as? String, !id.isEmpty {
                return .toolCallUpdate(id: id, title: title, status: status)
            }
            return .toolUpdate(status: status ?? "")
        case "session_info_update":
            let title = (update["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? .ignored : .title(title)
        case "plan":
            return .ignored
        default:
            return .ignored
        }
    }

    private func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String { return text }
            if let content = object["content"] { return contentText(content) }
        }
        if let array = value as? [Any] {
            return array.map(contentText).joined()
        }
        return ""
    }

    private func permission(id: String, isNumber: Bool, params: [String: Any]) -> PermissionRequest {
        let sessionID = params["sessionId"] as? String ?? ""
        let tool = params["toolCall"] as? [String: Any]
        let title = params["title"] as? String ?? tool?["title"] as? String ?? "Approve this action"
        let detail = params["description"] as? String ?? tool?["rawInput"].map { String(describing: $0) } ?? ""
        let options = params["options"] as? [[String: Any]] ?? []
        let allow = Self.optionID(options, once: "allow_once", fallback: "allow")
        let deny = Self.optionID(options, once: "reject_once", fallback: "reject")
        return PermissionRequest(
            id: "\(sessionID):\(id)",
            sessionID: sessionID,
            rpcID: id,
            rpcIDIsNumber: isNumber,
            title: title,
            detail: PhoneSnapshot.clip(detail, limit: 180),
            allowOptionID: allow,
            denyOptionID: deny
        )
    }

    /// Grok lists "always allow" first, and that grant is saved for every later bash command in the
    /// folder. One tap or one auto-approval answers this request only.
    private static func optionID(_ options: [[String: Any]], once: String, fallback: String) -> String? {
        if let exact = options.first(where: { ($0["kind"] as? String)?.lowercased() == once }) {
            return exact["optionId"] as? String
        }
        let fallbackOption = options.first { option in
            let words = optionKind(option)
            return words.contains(fallback) && !words.contains("always")
        } ?? options.first { optionKind($0).contains(fallback) }
        return fallbackOption?["optionId"] as? String
    }

    private static func optionKind(_ option: [String: Any]) -> String {
        let kind = (option["kind"] as? String ?? "").lowercased()
        let name = (option["name"] as? String ?? "").lowercased()
        return kind + " " + name
    }

    private func rpcID(_ value: Any?) -> (String, Bool) {
        if let number = value as? Int { return (String(number), true) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return (number.stringValue, true)
        }
        if let text = value as? String { return (text, false) }
        return ("", true)
    }
}
