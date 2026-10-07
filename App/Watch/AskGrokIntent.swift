import AppIntents

/// “Ask Grok” uses the Grok synonym in the Watch Info.plist.
/// A free-form task cannot be interpolated in an App Shortcut phrase, so Siri asks for it.
/// The app name token is required so the shortcut is indexed. Grok is that name.
struct AskGrokIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Grok"
    static let description = IntentDescription("Sends a task to the active computer.")

    /// Opens the Watch app so the task can leave through the iPhone or the direct relay.
    static var openAppWhenRun: Bool { true }

    @available(watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Task", requestValueDialog: "What should Grok do?")
    var task: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let accepted = await VoiceHandoff.submit(task)
        if accepted {
            return .result(dialog: "Sending that to the active computer.")
        }
        return .result(dialog: "Say what Grok should do.")
    }
}

/// Assigned in Settings, Action Button, Shortcut. A press toggles listen. It does not end the chat.
struct ToggleListenIntent: AppIntent {
    static let title: LocalizedStringResource = "Listen"
    static let description = IntentDescription("Starts or stops listening. Assign Listen to the Action Button.")

    static var openAppWhenRun: Bool { true }

    @available(watchOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            ListenActionButton.press()
        }
        return .result()
    }
}

struct WatchRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGrokIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Tell \(.applicationName)",
            ],
            shortTitle: "Ask Grok",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: ToggleListenIntent(),
            phrases: [
                "Listen with \(.applicationName)",
                "Toggle \(.applicationName) listening",
            ],
            shortTitle: "Listen",
            systemImageName: "mic.circle"
        )
    }
}
