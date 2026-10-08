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
            if entry.status == .needsApproval || entry.status == .failed {
                HStack(spacing: 6) {
                    StatusMark(status: entry.status)
                    Text(entry.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LojoTheme.secondaryText)
                }
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
    @FocusState private var composerFocused: Bool
    @State private var draft = ""
    /// Stays true until the reader scrolls up to read older messages.
    @State private var followLatest = true
    /// Ignores bottom-edge updates caused by our own scrollTo.
    @State private var holdFollow = true
    @State private var viewportHeight: CGFloat = 0
    @State private var lastSample = ChatEdgeSample()
    @State private var followedToken = ""
    /// Set once the latest line has actually sat at the bottom, so a bad first measurement cannot unpin.
    @State private var sawBottom = false
    @State private var pinRequest = 0
    @State private var openToolIDs: Set<Int> = []

    private var tailToken: String {
        let lines = current?.transcript ?? []
        return "\(lines.count)|\(lines.last ?? "")|\(current?.status.rawValue ?? "")"
    }

    private var current: GrokSession? {
        store.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        statusRow
                        transcript(proxy)
                        if let permission = current?.permission {
                            permissionCard(permission)
                        }
                        if let banner = store.banner, !banner.isEmpty, !ChatTranscript.isStatusNoise(banner) {
                            Text(banner)
                                .font(.footnote)
                                .foregroundStyle(LojoTheme.danger)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ChatBottomEdgeKey.self,
                                        value: ChatEdgeSample(maxY: geo.frame(in: .named("chat.scroll")).maxY, token: tailToken)
                                    )
                                }
                            }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "chat.scroll")
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: ChatViewportKey.self, value: geo.size.height)
                    }
                }
                .onPreferenceChange(ChatBottomEdgeKey.self) { sample in
                    lastSample = sample
                    noteFollow(sample, viewport: viewportHeight)
                }
                .onPreferenceChange(ChatViewportKey.self) { height in
                    viewportHeight = height
                    noteFollow(lastSample, viewport: height)
                }
                .accessibilityIdentifier("chat.history")
                .onChange(of: pinRequest) { _, _ in
                    pin(proxy)
                }
                .onChange(of: current?.transcript ?? []) { _, _ in
                    guard followLatest else { return }
                    pin(proxy)
                }
                .onChange(of: current?.status) { _, _ in
                    guard followLatest else { return }
                    pin(proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
                    guard followLatest else { return }
                    pin(proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                    guard followLatest else { return }
                    pin(proxy)
                }
                .onAppear {
                    pin(proxy)
                }
            }
            composer
        }
        .background(canvas)
        .navigationTitle(current?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionID) {
            followLatest = true
            pinRequest += 1
            await store.resume(sessionID: sessionID)
            pinRequest += 1
        }
    }

    private static let bottomID = "chat.bottom"

    private func pin(_ proxy: ScrollViewProxy) {
        followLatest = true
        holdFollow = true
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
        DispatchQueue.main.async {
            guard self.followLatest else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.followLatest else { return }
                self.holdFollow = false
            }
        }
    }

    /// Keeps an expanded tool row on screen when the reader is looking through history.
    private func holdRow(_ proxy: ScrollViewProxy, id: String) {
        holdFollow = true
        proxy.scrollTo(id, anchor: .center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.holdFollow = false
        }
    }

    private func noteFollow(_ sample: ChatEdgeSample, viewport: CGFloat) {
        guard viewport > 1, sample.maxY > 1 else { return }
        if sample.token != followedToken {
            followedToken = sample.token
            return
        }
        guard !holdFollow else { return }
        let gap = sample.maxY - viewport
        if gap < 24 {
            sawBottom = true
            followLatest = true
        } else if gap > 48, sawBottom {
            followLatest = false
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = false
        followLatest = true
        pinRequest += 1
        Task { await store.start(prompt: text, sessionID: sessionID) }
    }

    private var canvas: Color {
        scheme == .dark ? Color(red: 0.05, green: 0.05, blue: 0.06) : LojoTheme.pageBackground
    }

    @ViewBuilder
    private var statusRow: some View {
        if let current {
            HStack(spacing: 8) {
                StatusMark(status: current.status)
                Text(current.status == .idle ? "Chat" : current.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LojoTheme.secondaryText)
                    .accessibilityIdentifier("chat.thread")
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
    private func transcript(_ proxy: ScrollViewProxy) -> some View {
        let lines = current?.transcript ?? []
        let blocks = ChatTranscript.blocks(from: lines.isEmpty ? summaryLines : lines, toolsRunning: current?.status == .running)
        ForEach(blocks) { block in
            let rowID = "chat.block.\(block.id)"
            ChatBlockRow(
                block: block,
                oldest: block.id == blocks.first?.id,
                latest: block.id == blocks.last?.id,
                toolsOpen: openToolIDs.contains(block.id)
            ) {
                if openToolIDs.contains(block.id) {
                    openToolIDs.remove(block.id)
                } else {
                    openToolIDs.insert(block.id)
                }
                DispatchQueue.main.async {
                    if followLatest {
                        pin(proxy)
                    } else {
                        holdRow(proxy, id: rowID)
                    }
                }
            }
            .id(rowID)
        }
        if current?.status == .running, !blocks.endsWithRunningTools {
            Text("…")
                .font(.title3.weight(.bold))
                .foregroundStyle(LojoTheme.secondaryText)
                .accessibilityLabel("Reply streaming")
        }
    }

    private var summaryLines: [String] {
        guard let summary = current?.summary, !summary.isEmpty else { return [] }
        return [summary]
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
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                )
                .accessibilityIdentifier("chat.composer")
            Button(action: sendDraft) {
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

private struct ChatEdgeSample: Equatable {
    var maxY: CGFloat = 0
    var token: String = ""
}

private struct ChatBottomEdgeKey: PreferenceKey {
    static var defaultValue = ChatEdgeSample()
    static func reduce(value: inout ChatEdgeSample, nextValue: () -> ChatEdgeSample) {
        value = nextValue()
    }
}

private struct ChatViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension Array where Element == ChatBlock {
    var endsWithRunningTools: Bool {
        guard let last = last else { return false }
        if case .tools(_, _, true) = last { return true }
        return false
    }
}

struct ChatBlockRow: View {
    var block: ChatBlock
    var oldest: Bool
    var latest: Bool
    var toolsOpen: Bool
    var onToggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch block {
        case .user(_, let text):
            bubble(text, mine: true)
        case .assistant(_, let text):
            bubble(text, mine: false)
        case .note(_, let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(LojoTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
        case .tools(_, let steps, let running):
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    onToggle()
                } label: {
                    HStack(spacing: 8) {
                        if running {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(ChatTranscript.toolGroupTitle(count: steps.count))
                            .font(.footnote.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: toolsOpen ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.tools")
                .accessibilityLabel(ChatTranscript.toolGroupTitle(count: steps.count))
                if toolsOpen {
                    ForEach(Array(steps.enumerated()), id: \.offset) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.element.summary)
                                .font(.caption.weight(.semibold))
                            Text(item.element.detail)
                                .font(.caption2)
                                .foregroundStyle(LojoTheme.secondaryText)
                                .lineLimit(4)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(markdown(text))
            .font(.body)
            .foregroundStyle(mine ? Color.white : Color.primary)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(mine ? LojoTheme.accent : (scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
            )
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .accessibilityIdentifier(latest ? "chat.latest" : (oldest ? "chat.oldest" : "chat.line"))
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
