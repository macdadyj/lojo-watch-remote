import SwiftUI
import UIKit
import WatchRemoteCore

struct RootView: View {
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $store.tab) {
            SessionsView()
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

struct SessionsView: View {
    @EnvironmentObject private var store: RemoteStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if store.sessions.isEmpty {
                        empty
                    } else {
                        ForEach(store.sessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(LojoTheme.pageBackground)
            .navigationTitle("Sessions")
            .navigationDestination(for: String.self) { id in
                if let session = store.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: session)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.showCompose = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New task")
                }
            }
            .sheet(isPresented: $store.showCompose) {
                ComposeView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                if store.selectedSessionID == nil {
                    await store.refresh()
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { store.selectedSessionID != nil },
                set: { if !$0 { store.selectedSessionID = nil } }
            )) {
                if let id = store.selectedSessionID, let session = store.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: session)
                }
            }
        }
    }

    private func mark(for link: LinkState) -> SessionStatus {
        switch link {
        case .demo, .connected:
            return .idle
        case .connecting, .needsPairing, .phoneAway:
            return .unknown
        case .offline:
            return .failed
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.host.label)
                    .font(.title2.weight(.semibold))
                Spacer()
                if store.mode == .demo { DemoBadge() }
            }
            HStack(spacing: 8) {
                StatusMark(status: mark(for: store.link), size: 10)
                Text(store.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            if let banner = store.banner {
                Text(banner)
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.danger)
            }
        }
        .lojoCard()
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sessions yet")
                .font(.headline)
            Text("Start a task from the phone or the watch. Interactive terminals already open on the computer stay where they are.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
        }
        .lojoCard()
    }
}

struct SessionRow: View {
    var session: GrokSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: "sparkles", active: session.status == .running || session.status == .needsApproval, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(session.summary)
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusMark(status: session.status)
                    Text(session.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LojoTheme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .lojoCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title). \(session.status.title). \(session.summary)")
    }
}

struct SessionDetailView: View {
    var session: GrokSession
    @EnvironmentObject private var store: RemoteStore

    private var current: GrokSession {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    StatusMark(status: current.status)
                    Text(current.status.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if store.mode == .demo { DemoBadge() }
                }
                Text(current.summary)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lojoCard()
                if let permission = current.permission {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(permission.title)
                            .font(.headline)
                        if !permission.detail.isEmpty {
                            Text(permission.detail)
                                .font(.subheadline)
                                .foregroundStyle(LojoTheme.secondaryText)
                        }
                        Button("Allow") {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            store.allow(current.id)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityHint("Approves this action on the computer")
                        Button("Deny") {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            store.deny(current.id)
                        }
                        .buttonStyle(DestructiveButtonStyle())
                        .accessibilityHint("Refuses this action on the computer")
                    }
                    .padding(.bottom, 8)
                    .lojoCard()
                    .accessibilityElement(children: .contain)
                }
                if current.status == .running || current.status == .needsApproval {
                    Button("Stop") { store.stop(current.id) }
                        .buttonStyle(DestructiveButtonStyle())
                        .accessibilityHint("Stops this task on the computer")
                }
                if !store.approvalsAvailable && store.mode == .ssh {
                    Text("Approvals need the agent server on this computer. Tasks run there and cannot ask first until it is answering.")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.secondaryText)
                }
            }
            .padding(20)
        }
        .background(LojoTheme.pageBackground)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
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
