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
    }
}
