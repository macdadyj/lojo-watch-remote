import Foundation

/// Folds one chat's ACP updates into transcript lines.
///
/// Grok sends one `tool_call` and then three or four `tool_call_update`s for every tool, most of
/// them without a title. A tool is one step: the first event adds its card, and a later titled
/// update renames that card in place ("run_terminal_command" becomes "Execute `…`").
public struct ChatFold: Equatable, Sendable {
    /// Live turns never echo the prompt, but a replayed `user_message_chunk` can repeat one we showed.
    public var live: Bool
    private var toolLines: [String: Int] = [:]

    public init(live: Bool) {
        self.live = live
    }

    /// The transcript was replaced wholesale, so remembered card positions no longer hold.
    public mutating func forgetTools() {
        toolLines = [:]
    }

    public mutating func apply(_ event: StreamEvent, to lines: [String]) -> [String] {
        switch event {
        case .user(let text):
            return live
                ? ChatTranscript.mergingUserEcho(text, into: lines)
                : ChatTranscript.streamingSpeaker(prefix: "You:", text, in: lines)
        case .text(let text):
            return ChatTranscript.streamingAssistant(text, in: lines)
        case .tool(let title):
            return ChatTranscript.append(ChatTranscript.toolCard(title), to: lines)
        case .toolCall(let id, let title):
            return card(id: id, title: title, in: lines)
        case .toolCallUpdate(let id, let title, _):
            guard let title else { return lines }
            return card(id: id, title: title, in: lines)
        case .thought, .toolUpdate, .title, .turnStarted, .turnComplete, .usage, .end, .error, .ignored:
            return lines
        }
    }

    public static func replay(_ events: [StreamEvent]) -> [String] {
        var fold = ChatFold(live: false)
        return events.reduce(into: [String]()) { lines, event in
            lines = fold.apply(event, to: lines)
        }
    }

    private mutating func card(id: String, title: String, in lines: [String]) -> [String] {
        let line = ChatTranscript.toolCard(title)
        if let index = toolLines[id], index < lines.count, ChatTranscript.isToolCard(lines[index]) {
            guard lines[index] != line else { return lines }
            var copy = lines
            copy[index] = line
            return copy
        }
        let appended = ChatTranscript.append(line, to: lines)
        if appended.count > lines.count {
            toolLines[id] = appended.count - 1
        }
        return appended
    }
}

/// Decides when a chat's turn is over.
///
/// Grok sends `prompt_complete` and then the `session/prompt` result. A prompt the user sends in
/// between must not be marked done by that late result, and a `prompt_complete` for an earlier
/// prompt must not end a prompt that is still queued behind it.
public struct TurnTracker: Equatable, Sendable {
    /// Prompts this phone sent that Grok has not yet reported running.
    private var unstarted = 0
    private var running: String?
    private var generation = 0

    public init() {}

    /// Call when a prompt is sent. Hand the result back to `answered(generation:)`.
    public mutating func sent() -> Int {
        unstarted += 1
        generation += 1
        return generation
    }

    public mutating func started(_ promptID: String) {
        guard running != promptID else { return }
        running = promptID
        unstarted = max(0, unstarted - 1)
    }

    /// `prompt_complete`. True when nothing else is running or waiting in this chat.
    public mutating func completed(_ promptID: String) -> Bool {
        guard unstarted == 0 else { return false }
        if let running, !promptID.isEmpty, running != promptID { return false }
        running = nil
        return true
    }

    /// The `session/prompt` result. Only the newest send can end the turn this way.
    public mutating func answered(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        unstarted = 0
        running = nil
        return true
    }

    /// A `session/load` said whether a turn is running. Sends the computer never got are dropped.
    public mutating func loaded(runningPromptID: String?) {
        running = runningPromptID
        unstarted = 0
    }
}
