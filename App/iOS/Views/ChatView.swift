import SwiftUI
import UIKit
import WatchRemoteCore

struct ChatListView: View {
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    computerPicker
                    connectionLine
                    if store.sessions.isEmpty {
                        empty
                    } else {
                        ForEach(store.sessions) { session in
                            Button {
                                store.openChat(session.id)
                            } label: {
                                ChatListRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session.row.\(session.id)")
                        }
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("session.list")
            .background(canvas)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New task")
                    .accessibilityIdentifier("chat.new")
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
                ChatThreadHost()
            }
        }
    }

    private var canvas: Color {
        scheme == .dark ? Color(red: 0.05, green: 0.05, blue: 0.06) : LojoTheme.pageBackground
    }

    private var computerPicker: some View {
        Menu {
            ForEach(store.computers) { computer in
                Button {
                    store.selectComputer(id: computer.id)
                } label: {
                    if computer.id == store.host.id {
                        Label(computer.label, systemImage: "checkmark")
                    } else {
                        Text(computer.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                Text(store.host.label)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
                if store.mode == .demo { DemoBadge() }
            }
            .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("computer.picker")
        .accessibilityLabel("Computer \(store.host.label)")
    }

    private var connectionLine: some View {
        HStack(spacing: 8) {
            StatusMark(status: mark(for: store.link), size: 10)
            Text(store.statusLine)
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(store.statusLine)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No chats yet")
                .font(.headline)
            Text("Start one with the button above. A finished chat stays in this list.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
        }
        .lojoCard()
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
}

struct ChatListRow: View {
    var session: GrokSession

    private var entry: ChatListEntry { ChatTranscript.entry(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let updated = entry.updatedAt {
                    Text(updated, style: .relative)
                        .font(.caption)
                        .foregroundStyle(LojoTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Text(entry.lastMessage)
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
                .lineLimit(2)
            HStack(spacing: 6) {
                StatusMark(status: entry.status)
                Text(entry.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LojoTheme.secondaryText)
            }
        }
        .lojoCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title). \(entry.status.title). \(entry.lastMessage)")
    }
}

struct ChatThreadHost: View {
    @EnvironmentObject private var store: RemoteStore

    var body: some View {
        if let id = store.selectedSessionID {
            ChatThreadView(sessionID: id)
        }
    }
}

struct ChatThreadView: View {
    var sessionID: String
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""

    private var current: GrokSession? {
        store.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusRow
                    transcript
                    if let permission = current?.permission {
                        permissionCard(permission)
                    }
                    if let banner = store.banner, !banner.isEmpty {
                        Text(banner)
                            .font(.footnote)
                            .foregroundStyle(LojoTheme.danger)
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("chat.history")
            composer
        }
        .background(canvas)
        .navigationTitle(current?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chat.thread")
        .task(id: sessionID) {
            await store.resume(sessionID: sessionID)
        }
    }

    private var canvas: Color {
        scheme == .dark ? Color(red: 0.05, green: 0.05, blue: 0.06) : LojoTheme.pageBackground
    }

    @ViewBuilder
    private var statusRow: some View {
        if let current {
            HStack(spacing: 8) {
                StatusMark(status: current.status)
                Text(current.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LojoTheme.secondaryText)
                Spacer(minLength: 0)
                Button("End chat") { store.endChat(current.id) }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("chat.end")
            }
            Toggle(isOn: Binding(
                get: {
                    ApprovalPreference(
                        globalAutoApprove: store.autoApproveTools,
                        sessionOverride: current.autoApprove
                    ).autoApproves
                },
                set: { store.setSessionAutoApprove(current.id, $0) }
            )) {
                Text("Auto-approve this chat")
                    .font(.footnote)
            }
            .accessibilityIdentifier("chat.autoApprove")
        }
    }

    @ViewBuilder
    private var transcript: some View {
        let lines = current?.transcript ?? []
        if lines.isEmpty, let summary = current?.summary, !summary.isEmpty {
            ChatBubble(line: summary)
        }
        ForEach(Array(lines.enumerated()), id: \.offset) { item in
            ChatBubble(line: item.element)
        }
        if current?.status == .running {
            Text("…")
                .font(.title3.weight(.bold))
                .foregroundStyle(LojoTheme.secondaryText)
                .accessibilityLabel("Reply streaming")
        }
    }

    private func permissionCard(_ permission: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(permission.title)
                .font(.headline)
            if !permission.detail.isEmpty {
                Text(permission.detail)
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            Button("Allow") {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                store.allow(sessionID)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("chat.allow")
            Button("Deny") {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                store.deny(sessionID)
            }
            .buttonStyle(DestructiveButtonStyle())
            .accessibilityIdentifier("chat.deny")
        }
        .lojoCard()
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6, reservesSpace: true)
                .textFieldStyle(.plain)
                .padding(12)
                .frame(minHeight: 48, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                )
                .accessibilityIdentifier("chat.composer")
            Button {
                let text = draft
                draft = ""
                Task { await store.start(prompt: text, sessionID: sessionID) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat.send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(canvas)
    }
}

struct ChatBubble: View {
    var line: String
    @Environment(\.colorScheme) private var scheme
    @State private var toolOpen = false

    var body: some View {
        if ChatTranscript.isToolCard(line) {
            DisclosureGroup(isExpanded: $toolOpen) {
                Text(String(line.dropFirst(ChatTranscript.toolPrefix.count)).trimmingCharacters(in: .whitespaces))
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
            } label: {
                Text(line)
                    .font(.footnote.weight(.semibold))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
        } else if ChatTranscript.isNote(line) {
            Text(line)
                .font(.caption)
                .foregroundStyle(LojoTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if line.hasPrefix("You:") {
            Text(markdown(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                .font(.body)
                .foregroundStyle(.white)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LojoTheme.accent)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(markdown(display))
                .font(.body)
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                )
        }
    }

    private var display: String {
        if line.hasPrefix("Grok:") {
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private func markdown(_ source: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(source)
    }
}
