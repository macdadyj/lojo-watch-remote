import SwiftUI
import WatchKit
import WatchRemoteCore

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase

    private var scheme: ColorScheme {
        model.appearance.colorScheme ?? systemScheme
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.forcedScreen == nil, model.voiceModeActive {
                    VoiceChatView()
                } else if model.forcedScreen == nil, let prompt = model.pendingDictation {
                    VoiceConfirmView(transcript: prompt, isPreview: false)
                } else {
                    switch model.forcedScreen {
                    case "session", "long":
                        if let session = model.snapshot.sessions.first(where: { $0.id == DemoCatalog.approvalID }) {
                            WatchDetailView(session: session)
                        }
                    case "compose":
                        WatchComposeView()
                    case "dictate":
                        VoiceConfirmView(transcript: VoicePreview.task, isPreview: true)
                    default:
                        WatchListView()
                            .safeAreaInset(edge: .bottom, spacing: 4) {
                                VoiceHomeSection()
                            }
                    }
                }
            }
        }
        .tint(LojoTheme.accent)
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(model.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.wake()
        }
        .onChange(of: model.snapshot) { previous, current in
            model.noteVoiceSnapshot(previous: previous, current: current)
        }
    }
}

struct WatchListView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.snapshot.hostLabel)
                        .font(.headline)
                        .foregroundStyle(LojoTheme.readablePrimary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        StatusMark(status: headerMark, size: 10)
                        Text(headerTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(headerTitle)
                    Text(model.pathTitle)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(pathColor)
                        .accessibilityLabel("Path \(model.pathTitle)")
                    if model.snapshot.computers.count > 1 {
                        computerSwitcher
                    }
                    if model.snapshot.mode == .demo { DemoBadge(compact: true) }
                    if showsApprovalNote {
                        Text("Tasks cannot ask for approval.")
                            .font(.caption2)
                            .foregroundStyle(LojoTheme.readableSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .lojoCard(padding: 12)
                .padding(.top, 8)
                if let banner = model.banner ?? model.snapshot.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.snapshot.sessions.isEmpty {
                    Text(emptyCopy)
                        .font(.caption)
                        .foregroundStyle(LojoTheme.readableSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .lojoCard(padding: 12)
                }
                ForEach(model.snapshot.sessions) { session in
                    NavigationLink {
                        WatchDetailView(session: session)
                    } label: {
                        WatchRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    WatchComposeView()
                } label: {
                    Label("New task", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityLabel("New task")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 10, for: .scrollContent)
        .contentMargins(.bottom, 18, for: .scrollContent)
        .navigationTitle("Remote")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
        .onAppear { model.refresh() }
    }

    private var computerSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computers")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LojoTheme.readableSecondary(scheme))
            ForEach(model.snapshot.computers) { computer in
                Button {
                    model.selectComputer(computer.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: computer.id == model.snapshot.activeComputerID ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                        Text(computer.label)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(computer.id == model.snapshot.activeComputerID ? "\(computer.label), active" : "Switch to \(computer.label)")
            }
        }
    }

    private var phoneAway: Bool {
        model.forcedScreen == nil && !model.reachable
    }

    private var headerTitle: String {
        if model.pathTitle == "Pair on iPhone first" { return "Pair on iPhone first" }
        if phoneAway && model.pathTitle != "direct" { return LinkState.phoneAway.title }
        return model.snapshot.link.title
    }

    private var pathColor: Color {
        model.pathTitle == "direct" ? LojoTheme.online : LojoTheme.readableSecondary(scheme)
    }

    private var headerMark: SessionStatus {
        if phoneAway { return .unknown }
        switch model.snapshot.link {
        case .demo, .connected:
            return .idle
        case .connecting, .needsPairing, .phoneAway:
            return .unknown
        case .offline:
            return .failed
        }
    }

    private var showsApprovalNote: Bool {
        model.forcedScreen == nil && model.snapshot.mode == .ssh && !model.snapshot.approvalsAvailable
    }

    private var emptyCopy: String {
        switch model.snapshot.link {
        case .connecting:
            return "Connecting to the computer."
        case .offline:
            return "Not connected. Open the iPhone app and check the computer."
        case .needsPairing:
            return "Pair on iPhone first."
        case .phoneAway:
            return model.pathTitle == "direct"
                ? "The iPhone is away. This Watch is connected directly. The link pauses when the app is not open."
                : "Pair on iPhone first."
        case .demo:
            return "No sessions. Start one with the button below."
        case .connected:
            return "No sessions. Start one with the button below."
        }
    }
}

struct WatchRow: View {
    var session: GrokSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusMark(status: session.status, size: 10)
                Text(session.status.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
            }
            Text(session.title)
                .font(.headline)
                .foregroundStyle(LojoTheme.readablePrimary(scheme))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.summary)
                .font(.caption2)
                .foregroundStyle(LojoTheme.readableSecondary(scheme))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lojoCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

struct WatchDetailView: View {
    var session: GrokSession
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    private var current: GrokSession {
        model.snapshot.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.title)
                    .font(.headline)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .lineLimit(2)
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    StatusMark(status: current.status, size: 10)
                    Text(current.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LojoTheme.readablePrimary(scheme))
                }
                .accessibilityElement(children: .combine)
                watchActions
                Text(current.summary)
                    .font(.caption)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let banner = model.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let permission = current.permission {
                    Text(permission.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LojoTheme.readablePrimary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if !permission.detail.isEmpty {
                        Text(permission.detail)
                            .font(.caption2)
                            .foregroundStyle(LojoTheme.readableSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Task")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
    }

    private var showsPermission: Bool { current.permission != nil }

    private var showsStop: Bool {
        current.status == .running || current.status == .needsApproval
    }

    @ViewBuilder
    private var watchActions: some View {
        if showsPermission || showsStop {
            VStack(spacing: 8) {
                if showsPermission {
                    HStack(spacing: 6) {
                        Button("Deny") {
                            WatchFeedback.failure()
                            model.deny(current)
                        }
                        .buttonStyle(DestructiveButtonStyle(compact: true))
                        .accessibilityLabel("Deny")
                        .accessibilityHint("Refuses this action")
                        Button("Allow") {
                            WatchFeedback.success()
                            model.allow(current)
                        }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .accessibilityLabel("Allow")
                        .accessibilityHint("Approves this action")
                    }
                }
                if showsStop {
                    Button("Stop") {
                        WatchFeedback.click()
                        model.stop(current)
                    }
                    .buttonStyle(DestructiveButtonStyle(compact: true))
                    .accessibilityLabel("Stop")
                    .accessibilityHint("Stops this task")
                }
                VoiceApprovalMic(session: current)
            }
        }
    }
}

struct WatchComposeView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme
    @State private var prompt: String

    init() {
        let screen = ProcessInfo.processInfo.environment["WATCHREMOTE_SCREEN"]
        let seeded = screen == "compose" || ProcessInfo.processInfo.arguments.contains("compose")
        _prompt = State(initialValue: seeded ? "Summarize the open changes" : "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dictate a task")
                    .font(.headline)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .padding(.top, 16)
                TextFieldLink(prompt: Text("Say what to do")) {
                    Text(prompt.isEmpty ? "Say what to do" : prompt)
                        .font(.footnote)
                        .foregroundStyle(prompt.isEmpty ? LojoTheme.readableSecondary(scheme) : LojoTheme.readablePrimary(scheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } onSubmit: { prompt = $0 }
                .buttonStyle(.plain)
                .accessibilityLabel("Task")
                .accessibilityValue(prompt)
                Button("Start") {
                    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if model.start(text) {
                        WatchFeedback.success()
                        prompt = ""
                    }
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityHint("Sends the task to the computer")
                if let banner = model.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("New task")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
        .onAppear {
            if ProcessInfo.processInfo.environment["WATCHREMOTE_SCREEN"] == "compose"
                || ProcessInfo.processInfo.arguments.contains("compose") {
                prompt = "Summarize the open changes"
            }
        }
    }
}

private struct WatchPage: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(page)
            .containerBackground(page, for: .navigation)
    }

    private var page: Color {
        switch scheme {
        case .light: return Color(red: 0.95, green: 0.95, blue: 0.96)
        case .dark: return .black
        @unknown default: return .black
        }
    }
}

extension View {
    func watchPage() -> some View {
        modifier(WatchPage())
    }
}

enum WatchFeedback {
    static func success() { WKInterfaceDevice.current().play(.success) }
    static func failure() { WKInterfaceDevice.current().play(.failure) }
    static func click() { WKInterfaceDevice.current().play(.click) }
    static func notification() { WKInterfaceDevice.current().play(.notification) }
}

