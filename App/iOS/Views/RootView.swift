import SwiftUI
import WatchRemoteCore

struct RootView: View {
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $store.tab) {
            ChatListView()
                .tag(AppTab.sessions)
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            ComputerView()
                .tag(AppTab.computer)
                .tabItem { Label("Computer", systemImage: "desktopcomputer") }
            SettingsView()
                .tag(AppTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(item: $store.trustPrompt, onDismiss: { store.rejectTrust() }) { prompt in
            TrustView(prompt: prompt)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.reconnectIfNeeded() }
        }
    }
}

struct ComposeView: View {
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = ComposerDictation()
    @FocusState private var promptFocused: Bool
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What should Grok do?")
                    .font(.title3.weight(.semibold))
                TextField("Dictate or type a task", text: $prompt, axis: .vertical)
                    .lineLimit(8, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
                    .focused($promptFocused)
                    .keyboardType(.default)
                    .textContentType(nil)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .frame(minHeight: 140, alignment: .topLeading)
                    .accessibilityIdentifier("chat.prompt")
                Button {
                    promptFocused = false
                    dictation.toggle(appendingTo: prompt) { text in
                        prompt = text
                    }
                } label: {
                    Label(dictation.listening ? "Stop dictation" : "Dictate", systemImage: dictation.listening ? "stop.circle.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("chat.dictate")
                if let problem = dictation.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.danger)
                        .accessibilityIdentifier("chat.dictateProblem")
                }
                Text(store.cwd.isEmpty ? "Working directory: the computer’s home" : "Working directory: \(store.cwd)")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
                Button("Start task") {
                    dictation.stop()
                    let text = prompt
                    dismiss()
                    Task { await store.start(prompt: text) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat.start")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(LojoTheme.pageBackground)
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(LojoTheme.secondaryText)
                }
            }
            .onAppear {
                ComposerSpeech.releaseIdleSession()
                if ProcessInfo.processInfo.environment["WATCHREMOTE_SCREEN"] == "compose"
                    || ProcessInfo.processInfo.arguments.contains("compose") {
                    prompt = "Summarize the open changes"
                }
            }
            .onDisappear {
                dictation.stop()
            }
        }
    }
}
