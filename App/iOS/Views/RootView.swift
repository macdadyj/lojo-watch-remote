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
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What should Grok do?")
                    .font(.title3.weight(.semibold))
                TextField("Dictate or type a task", text: $prompt, axis: .vertical)
                    .lineLimit(8, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 140, alignment: .topLeading)
                    .accessibilityIdentifier("chat.prompt")
                Text(store.cwd.isEmpty ? "Working directory: the computer’s home" : "Working directory: \(store.cwd)")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
                Button("Start task") {
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
                if ProcessInfo.processInfo.environment["WATCHREMOTE_SCREEN"] == "compose"
                    || ProcessInfo.processInfo.arguments.contains("compose") {
                    prompt = "Summarize the open changes"
                }
            }
        }
    }
}
