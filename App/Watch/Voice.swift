import AVFoundation
import SwiftUI
import WatchConnectivity
import WatchKit
import WatchRemoteCore

enum VoicePreview {
    static let task = "Summarize the open changes"
}

@MainActor
final class VoicePreferences: ObservableObject {
    static let shared = VoicePreferences()

    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.set(autoSend, forKey: Keys.autoSend) }
    }

    @Published var readAloud: Bool {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: Keys.readAloud)
            if !readAloud {
                VoiceSpeaker.shared.stop()
            }
        }
    }

    /// Optional. Off by default: a pause does not send. Action Button and I'm done do.
    @Published var pauseSends: Bool {
        didSet { UserDefaults.standard.set(pauseSends, forKey: Keys.pauseSends) }
    }

    /// Off until turned on. Tool prompts are allowed without a tap.
    @Published var autoApproveTools: Bool {
        didSet { UserDefaults.standard.set(autoApproveTools, forKey: Keys.autoApprove) }
    }

    /// The two-line Action Button sentence shows once, until Speak or the Action Button is used.
    @Published var actionHintSeen: Bool {
        didSet { UserDefaults.standard.set(actionHintSeen, forKey: Keys.actionHintSeen) }
    }

    func noteActionHintUsed() {
        guard !actionHintSeen else { return }
        actionHintSeen = true
    }

    private init() {
        let defaults = UserDefaults.standard
        autoSend = defaults.bool(forKey: Keys.autoSend)
        readAloud = defaults.bool(forKey: Keys.readAloud)
        if defaults.object(forKey: Keys.pauseSends) == nil {
            pauseSends = false
        } else {
            pauseSends = defaults.bool(forKey: Keys.pauseSends)
        }
        autoApproveTools = defaults.bool(forKey: Keys.autoApprove)
        actionHintSeen = defaults.bool(forKey: Keys.actionHintSeen)
    }

    private enum Keys {
        static let autoSend = "watch.voice.autoSend"
        static let readAloud = "watch.voice.readAloud"
        static let pauseSends = "watch.voice.pauseSends"
        static let autoApprove = "watch.voice.autoApprove"
        static let actionHintSeen = "watch.voice.actionHintSeen"
    }
}

/// Siri runs before the Watch model exists. The model takes the task when it comes up.
@MainActor
enum VoiceHandoff {
    static var handler: ((String) -> Void)?
    private static let key = "watch.voice.pendingTask"

    @discardableResult
    static func submit(_ raw: String) -> Bool {
        guard case .send(let prompt) = VoiceTaskPolicy.disposition(transcript: raw, autoSend: true) else {
            return false
        }
        if let handler {
            handler(prompt)
        } else {
            UserDefaults.standard.set(prompt, forKey: key)
        }
        return true
    }

    static func takePending() -> String? {
        let stored = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }
}

final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceSpeaker()
    private var synthesizer: AVSpeechSynthesizer?
    private var lastKey: String?
    private var current: AVSpeechUtterance?
    private var onFinish: (() -> Void)?

    func speakNow(_ text: String, dedupeKey: String? = nil, whenFinished: (() -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            whenFinished?()
            return
        }
        if let dedupeKey {
            if dedupeKey == lastKey {
                whenFinished?()
                return
            }
            lastKey = dedupeKey
        }
        let speaker = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = speaker
        speaker.delegate = self
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        current = utterance
        onFinish = whenFinished
        speaker.speak(utterance)
    }

    func stop() {
        onFinish = nil
        current = nil
        synthesizer?.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = utterance
        DispatchQueue.main.async { [weak self] in
            guard let self, finished === self.current else { return }
            let finish = self.onFinish
            self.onFinish = nil
            self.current = nil
            finish?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelled = utterance
        DispatchQueue.main.async { [weak self] in
            guard let self, cancelled === self.current else { return }
            self.onFinish = nil
            self.current = nil
        }
    }
}

enum VoiceInput {
    static func present(_ onText: @escaping (String?) -> Void) {
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            DispatchQueue.main.async { onText(nil) }
            return
        }
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            let text = results?.first as? String
            DispatchQueue.main.async {
                onText(text)
            }
        }
    }
}

struct VoicePreferenceToggles: View {
    @ObservedObject private var preferences = VoicePreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $preferences.pauseSends) {
                Text("Pause sends")
                    .font(.caption2)
            }
            .accessibilityHint("Optional. Off uses the Action Button and I'm done. A pause does not send.")

            Toggle(isOn: $preferences.autoSend) {
                Text("Auto-send")
                    .font(.caption2)
            }
            .accessibilityHint("Applies to New task. Off until you turn it on. Speak still waits for I'm done unless Pause sends is on.")

            Toggle(isOn: $preferences.readAloud) {
                Text("Read results aloud")
                    .font(.caption2)
            }
            .accessibilityHint("Speaks the latest finished result. Off until you turn it on.")

            Toggle(isOn: $preferences.autoApproveTools) {
                Text("Auto-approve tools")
                    .font(.caption2)
            }
            .accessibilityIdentifier("settings.autoApprove")
            .accessibilityHint("Allows tool calls without a tap. Off until you turn it on.")
        }
    }
}

struct VoiceConfirmView: View {
    var transcript: String
    var isPreview: Bool
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send this task?")
                    .font(.headline)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .padding(.top, 12)
                Text(transcript)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.readablePrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Task")
                    .accessibilityValue(transcript)
                Button("Send") { send() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .accessibilityHint("Sends the task to the active computer")
                Button("Cancel") { cancel() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                if !isPreview, let banner = model.banner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(LojoTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .watchPage()
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("New task")
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
    }

    private func send() {
        guard !isPreview else { return }
        let text = transcript
        model.pendingDictation = nil
        if model.start(text) {
            WatchFeedback.success()
        }
    }

    private func cancel() {
        guard !isPreview else { return }
        model.pendingDictation = nil
    }
}

struct VoiceApprovalMic: View {
    var session: GrokSession
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Button {
                model.beginHandsFreeVoice()
            } label: {
                Label("Speak", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle(compact: true))
            .accessibilityLabel("Voice command")
            .accessibilityHint("Say allow, then yes. Deny and stop send on the first word. I'm done or the Action Button sends.")

            if model.pendingAllowSessionID == session.id {
                Button("Yes") {
                    model.confirmPendingAllow(session)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .accessibilityLabel("Yes")
                .accessibilityHint("Confirms the spoken allow. Saying yes does this too.")
            }

            if model.voiceNoteSessionID == session.id, let note = model.voiceNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct VoiceChatView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var preferences = VoicePreferences.shared
    @State private var followLatest = true
    @State private var holdFollow = true
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportOrigin: CGPoint = .zero
    @State private var lastSample = VoiceEdgeSample()
    @State private var followedToken = ""
    /// Set once the latest line has actually sat at the bottom, so a bad first measurement cannot unpin.
    @State private var sawBottom = false
    @State private var openToolIDs: Set<Int> = []
    @State private var restoredCaption = false
    @State private var pinGeneration = 0
    /// Empty space under the newest row. It grows until the top edge falls between bubbles.
    @State private var bottomPad: CGFloat = 0
    /// The hang `bottomPad` was applied for. A later reading that did not shrink means the pad cannot grow.
    @State private var paddedFor: CGFloat = 0
    @State private var rowSpans: [ViewportSpan] = []
    @State private var showCompose = false

    private let bubbleSpacing: CGFloat = 4

    private var showSpeakAgain: Bool {
        switch model.voiceStatus {
        case "Listening", "Hearing you", "Sending", "Speaking", "Waiting for the iPhone":
            return false
        default:
            return true
        }
    }

    private var history: [String] {
        if model.forcedScreen == "voice-loop" {
            return VoiceLoopHarness.lines(
                sessions: DemoCatalog.sessions(),
                hostLabel: "example-host",
                linkTitle: "Connected"
            )
        }
        if !model.voiceLog.isEmpty {
            return model.voiceLog
        }
        if model.forcedScreen == "voice-chat" {
            return VoiceConversationFixture.history
        }
        return []
    }

    var body: some View {
        SpeakBarPage {
            VStack(spacing: 0) {
                if model.banner == SessionResume.missingMessage {
                    Text(SessionResume.missingMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LojoTheme.readablePrimary(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                historyList
            }
        } bar: {
            VoiceConversationBar(
                showSpeak: showSpeakAgain || model.forcedScreen != nil,
                onNewTask: { showCompose = true },
                onOpenSession: { model.openHistory($0) }
            )
        }
        .watchPage()
        .navigationTitle(model.forcedScreen == "voice-loop" ? "Voice loop" : "")
        .toolbar(model.forcedScreen == "voice-loop" ? .automatic : .hidden, for: .navigationBar)
        .toolbarColorScheme(scheme == .dark ? .dark : .light, for: .navigationBar)
        .navigationDestination(isPresented: $showCompose) {
            WatchComposeView()
        }
        .onAppear {
            noteRestoredCaption(model.voiceStatus)
        }
        .onChange(of: model.voiceStatus) { _, status in
            noteRestoredCaption(status)
        }
    }

    private var showsRestoredCaption: Bool {
        restoredCaption && (model.voiceStatus == "Restored" || model.voiceStatus == "Restoring")
    }

    private func noteRestoredCaption(_ status: String) {
        guard status == "Restored" || status == "Restoring" else {
            restoredCaption = false
            return
        }
        restoredCaption = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard self.model.voiceStatus == status else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                self.restoredCaption = false
            }
        }
    }

    private var conversationLines: [String] {
        var rows: [String] = []
        let spoken = model.voiceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty, ChatTranscript.isConversation(spoken), !history.contains(spoken) {
            rows.append(spoken)
        }
        rows.append(contentsOf: history.filter { ChatTranscript.isConversation($0) || ChatTranscript.isToolCard($0) || ChatTranscript.isNote($0) })
        let title = chatTitle
        guard !title.isEmpty else { return rows }
        return rows.filter { $0 != title }
    }

    /// The list row's title. It stays out of the bubbles so it is not a second copy of the chat.
    private var chatTitle: String {
        guard let id = model.resumedSessionID else { return "" }
        return model.snapshot.sessions.first { $0.id == id }?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var tailToken: String {
        let lines = conversationLines
        return "\(lines.count)|\(lines.last ?? "")|\(model.voiceLine)"
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    bubbleStack(proxy)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .padding(.bottom, 2)
                        .offset(y: -bottomPad)
                    Color.clear
                        .frame(height: 1)
                        .id("voice.bottom")
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: VoiceBottomEdgeKey.self,
                                    value: VoiceEdgeSample(
                                        maxY: geo.frame(in: .named("voice.scroll")).maxY,
                                        token: tailToken
                                    )
                                )
                            }
                        }
                }
            }
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: "voice.scroll")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .preference(key: VoiceViewportKey.self, value: geo.size.height)
                        .preference(key: ViewportFrameKey.self, value: geo.frame(in: .global))
                }
            }
            .onPreferenceChange(VoiceBottomEdgeKey.self) { sample in
                lastSample = sample
                noteFollow(sample, viewport: viewportHeight)
            }
            .onPreferenceChange(VoiceViewportKey.self) { height in
                viewportHeight = height
                noteFollow(lastSample, viewport: height)
            }
            .onPreferenceChange(ViewportFrameKey.self) { frame in
                let moved = abs(frame.origin.y - viewportOrigin.y) > 1 || abs(frame.origin.x - viewportOrigin.x) > 1
                viewportOrigin = frame.origin
                if frame.height > 1 {
                    viewportHeight = frame.height
                }
                if moved {
                    paddedFor = 0
                    bottomPad = 0
                }
                noteRowSpans(rowSpans, origin: frame.origin)
            }
            .accessibilityIdentifier("voice.history")
            .accessibilityValue("\(Int(bottomPad.rounded()))")
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .onPreferenceChange(RowSpanKey.self) { spans in
                rowSpans = spans
                noteRowSpans(spans, origin: viewportOrigin)
            }
            .onChange(of: tailToken) { _, _ in
                pin(proxy)
            }
            .onChange(of: bottomPad) { _, _ in
                pin(proxy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.pin(proxy)
                }
            }
            .onChange(of: viewportHeight) { old, height in
                guard height > 1, abs(height - old) > 0.5, followLatest else { return }
                pin(proxy)
            }
            .onChange(of: restoredCaption) { _, shown in
                if !shown {
                    bottomPad = 0
                    paddedFor = 0
                }
                pin(proxy)
                guard !shown else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.pin(proxy)
                }
            }
            .onAppear {
                pin(proxy)
            }
        }
    }

    private func pin(_ proxy: ScrollViewProxy) {
        followLatest = true
        holdFollow = true
        pinGeneration += 1
        let generation = pinGeneration
        proxy.scrollTo("voice.bottom", anchor: .bottom)
        DispatchQueue.main.async {
            guard self.followLatest, self.pinGeneration == generation else { return }
            proxy.scrollTo("voice.bottom", anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard self.followLatest, self.pinGeneration == generation else { return }
            proxy.scrollTo("voice.bottom", anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.pinGeneration == generation else { return }
            self.holdFollow = false
        }
    }

    private func holdRow(_ proxy: ScrollViewProxy, id: String) {
        holdFollow = true
        proxy.scrollTo(id, anchor: .center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.holdFollow = false
        }
    }

    private func noteFollow(_ sample: VoiceEdgeSample, viewport: CGFloat) {
        guard viewport > 1, sample.maxY > 1 else { return }
        if sample.token != followedToken {
            followedToken = sample.token
            return
        }
        guard !holdFollow else { return }
        let gap = sample.maxY - viewport
        if gap < 16 {
            sawBottom = true
            followLatest = true
        } else if gap > 28, sawBottom {
            followLatest = false
        }
    }

    private func bubbleStack(_ proxy: ScrollViewProxy) -> some View {
        let lines = conversationLines
        let blocks = ChatTranscript.blocks(from: lines, toolsRunning: false)
        return VStack(alignment: .leading, spacing: bubbleSpacing) {
            if !chatTitle.isEmpty {
                Text(chatTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .reportRowSpan()
            }
            if model.forcedScreen == "voice-loop" {
                Text("Scripted check. The microphone stays off.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LojoTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let banner = model.banner, !banner.isEmpty, !ChatTranscript.isStatusNoise(banner),
               banner != SessionResume.missingMessage {
                Text(banner)
                    .font(.caption2)
                    .foregroundStyle(LojoTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.banner")
            }
            ForEach(blocks) { block in
                let rowID = rowID(for: block)
                WatchBubble(block: block, toolsOpen: openToolIDs.contains(block.id)) {
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
                .reportRowSpan()
            }
            if showsRestoredCaption || showsLiveStatus {
                Text(model.voiceStatus)
                    .font(.caption2)
                    .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("voice.status")
                    .accessibilityLabel("Voice status")
                    .accessibilityValue(model.voiceStatus)
                    .onLongPressGesture(minimumDuration: 0.6) {
                        model.toggleTransportDiagnostics()
                    }
                    .reportRowSpan()
            }
            if model.showTransportDiagnostics {
                Text(model.diagnosticsLine)
                    .font(.caption2)
                    .foregroundStyle(LojoTheme.readableSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.diagnostics")
            }
            if model.pendingAllowSessionID != nil {
                Button("Yes") {
                    model.confirmSpokenAllow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Yes")
                .accessibilityHint("Confirms the spoken allow. Saying yes does this too.")
            }
            if model.dictationOffered {
                Button("Dictate") {
                    model.presentDictationSheet()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Dictate")
                .accessibilityHint("Opens the keyboard. That sheet still needs Done.")
            }
            if model.repairOffered {
                Button(RelayUserNotice.repairText) {
                    model.requestPhonePairing()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("voice.repair")
            }
            if model.uiShowHooks {
                ListenTestHooks()
            }
        }
    }

    /// A row that still crosses the top shifts the stack up by that hang. Once the row is
    /// fully above the viewport the hang drops and the shift stays, so the list does not jump.
    private func noteRowSpans(_ spans: [ViewportSpan], origin: CGPoint) {
        guard viewportHeight > 1 else { return }
        let local = spans.map { span in
            ViewportSpan(
                minY: span.minY - origin.y,
                maxY: span.maxY - origin.y
            )
        }
        let stub = VoiceChromeMetrics.topStub(local)
        guard stub <= 48 else { return }
        if bottomPad > 0.5, paddedFor > 1, stub > paddedFor - 2 {
            return
        }
        guard stub > 1 else { return }
        let needed = min(stub, viewportHeight)
        guard needed > bottomPad + 0.5 else { return }
        paddedFor = stub
        bottomPad = needed
    }

    private var showsLiveStatus: Bool {
        let status = model.voiceStatus
        guard !status.isEmpty else { return false }
        return status != "Restored" && status != "Restoring"
    }

    private func rowID(for block: ChatBlock) -> String {
        switch block {
        case .user(let id, _), .assistant(let id, _):
            return "voice.msg.\(id)"
        case .tools(let id, _, _):
            return "voice.toolsrow.\(id)"
        case .note(let id, _):
            return "voice.note.\(id)"
        }
    }
}

private struct VoiceEdgeSample: Equatable {
    var maxY: CGFloat = 0
    var token: String = ""
}

private struct VoiceBottomEdgeKey: PreferenceKey {
    static var defaultValue = VoiceEdgeSample()
    static func reduce(value: inout VoiceEdgeSample, nextValue: () -> VoiceEdgeSample) {
        value = nextValue()
    }
}

private struct VoiceViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ViewportFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct RowSpanKey: PreferenceKey {
    static var defaultValue: [ViewportSpan] = []
    static func reduce(value: inout [ViewportSpan], nextValue: () -> [ViewportSpan]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func reportRowSpan() -> some View {
        background {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear.preference(
                    key: RowSpanKey.self,
                    value: [ViewportSpan(minY: frame.minY, maxY: frame.maxY)]
                )
            }
        }
    }
}

private struct WatchBubble: View {
    var block: ChatBlock
    var toolsOpen: Bool = false
    var onToggle: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch block {
        case .user(_, let text):
            line(text, mine: true)
        case .assistant(_, let text):
            line(text, mine: false)
        case .note(_, let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(LojoTheme.readableSecondary(scheme))
                .frame(maxWidth: .infinity, alignment: .center)
        case .tools(_, let steps, let running):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    onToggle()
                } label: {
                    HStack(spacing: 4) {
                        if running {
                            ProgressView()
                        }
                        Text(ChatTranscript.toolGroupTitle(count: steps.count))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .accessibilityIdentifier("voice.tools")
                .accessibilityLabel(ChatTranscript.toolGroupTitle(count: steps.count))
                if toolsOpen {
                    ForEach(Array(steps.enumerated()), id: \.offset) { item in
                        Text(item.element.summary)
                            .font(.caption2.weight(.semibold))
                        Text(item.element.detail)
                            .font(.caption2)
                            .foregroundStyle(LojoTheme.readableSecondary(scheme))
                            .lineLimit(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 8) }
            Text(text)
                .font(.footnote)
                .foregroundStyle(mine ? Color.white : LojoTheme.readablePrimary(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(mine ? LojoTheme.accent : (scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)))
                )
                .accessibilityIdentifier("voice.line")
            if !mine { Spacer(minLength: 8) }
        }
    }
}

extension WatchModel {
    func acceptDictation(_ transcript: String) {
        switch VoiceTaskPolicy.disposition(transcript: transcript, autoSend: VoicePreferences.shared.autoSend) {
        case .ignore:
            return
        case .confirm(let prompt):
            pendingDictation = prompt
            WatchFeedback.click()
        case .send(let prompt):
            pendingDictation = nil
            if start(prompt) {
                WatchFeedback.success()
            }
        }
    }

    /// Siri and the home microphone enter the same conversation.
    func submitSpokenTask(_ transcript: String) {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        handleVoiceTurn(transcript)
    }

    func openVoiceConversation(_ transcript: String) {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        handleVoiceTurn(transcript)
    }

    /// Stops the microphone now and sends the audio or text captured so far.
    /// The chat and the restored session stay open.
    func stopTalking() {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        VoiceSpeaker.shared.stop()
        speakingReply = false
        dictationPresented = false
        systemPausedListen = false
        ListenRuntime.shared.end()
        if uiTest {
            capture.stop()
            prepareID = nil
            expectID = nil
            let transcript = VoiceTestClips.transcript(forClip: injectedClip)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !transcript.isEmpty {
                remember("You: \(transcript)")
                if uiPhoneOff {
                    let reply = VoiceTestHost.reply(to: transcript)
                    if !reply.isEmpty {
                        remember(reply)
                    }
                }
            }
            voiceStatus = "Sent"
            return
        }
        let partial = inProgressUtterance()
        if !partial.isEmpty {
            remember(partial)
        }
        prepareID = nil
        if capture.finishEarly() {
            voiceStatus = "Sending"
            return
        }
        expectID = nil
        if !partial.isEmpty {
            handleVoiceTurn(partial)
            return
        }
        voiceStatus = "Paused"
    }

    private func inProgressUtterance() -> String {
        guard capture.isRunning || expectID != nil else { return "" }
        let line = voiceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let hints = [
            VoiceSpeechCopy.listeningHint,
            VoiceSpeechCopy.waitingForPhone,
            ListenEndpoint.manualHint,
            ListenEndpoint.waitingManual,
        ]
        if line.isEmpty || hints.contains(line) {
            return ""
        }
        if line == VoiceSpeechCopy.missed || line == VoiceSpeechCopy.phoneAway {
            return ""
        }
        return line
    }

    func endVoiceConversation() {
        declinedVoicePermissionID = pendingAllowSessionID.flatMap { id in
            snapshot.sessions.first { $0.id == id }?.permission?.id
        } ?? snapshot.sessions.first { $0.permission != nil }?.permission?.id
        voiceModeActive = false
        resumedSessionID = nil
        pendingAllowSessionID = nil
        voiceNote = nil
        voiceNoteSessionID = nil
        prepareID = nil
        expectID = nil
        speakingReply = false
        dictationPresented = false
        dictationOffered = false
        missedTurns = 0
        voiceStatus = ""
        systemPausedListen = false
        discardPendingHostAudio()
        capture.stop()
        ListenRuntime.shared.end()
        VoiceSpeaker.shared.stop()
    }

    func continueListening() {
        if uiTest {
            beginHandsFreeVoice()
            return
        }
        guard forcedScreen == nil else { return }
        applyListenChrome()
        DispatchQueue.main.async { [weak self] in
            self?.armListener()
        }
    }

    func beginHandsFreeVoice() {
        VoicePreferences.shared.noteActionHintUsed()
        if uiTest {
            voiceModeActive = true
            if uiPhoneOff {
                let route = VoiceListenPolicy.route(
                    phoneReachable: false,
                    attempt: uiHostReady ? 0 : VoiceListenPolicy.phoneWaitAttempts,
                    recognitionRefused: false,
                    captureFailed: false,
                    hostReady: uiHostReady
                )
                switch route {
                case .handsFree, .handsFreeHost:
                    voiceStatus = "Listening"
                    if voiceLog.isEmpty && voiceLine.isEmpty {
                        voiceLine = ListenEndpoint.hint(pauseSends: VoicePreferences.shared.pauseSends)
                        voiceLog = VoiceConversationFixture.history
                    }
                    scheduleUICap()
                case .presentDictation:
                    voiceLine = VoiceSpeechCopy.phoneAway
                    voiceStatus = "Dictation"
                    dictationOffered = true
                case .waitForPhone, .offerDictation:
                    offerDictation(VoiceSpeechCopy.phoneAway)
                @unknown default:
                    offerDictation(VoiceSpeechCopy.unavailable)
                }
                return
            }
            voiceStatus = "Listening"
            if voiceLog.isEmpty && voiceLine.isEmpty {
                voiceLine = ListenEndpoint.hint(pauseSends: VoicePreferences.shared.pauseSends)
                voiceLog = VoiceConversationFixture.history
            }
            scheduleUICap()
            return
        }
        resumedSessionID = nil
        guard forcedScreen == nil else { return }
        appIsActive = true
        declinedVoicePermissionID = nil
        dictationOffered = false
        missedTurns = 0
        voiceModeActive = true
        if let session = snapshot.sessions.first(where: { $0.permission != nil }),
           pendingAllowSessionID == nil,
           spokenPermissionIDs.contains(session.permission?.id ?? "") == false {
            beginAllowReadback(for: session, haptic: false)
            return
        }
        applyListenChrome()
        DispatchQueue.main.async { [weak self] in
            self?.armListener()
        }
    }

    func currentPhoneReachable() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isReachable
    }

    func setActive(_ active: Bool) {
        appIsActive = active
        if !uiTest {
            directNoteDisplay(active)
        }
        guard forcedScreen == nil, !uiTest else { return }
        if !active {
            holdThroughWristDown()
            return
        }
        let resumeListen = systemPausedListen || capture.isSuspended || capture.isRunning
        resumeAfterWristUp()
        if resumeListen || isManualListenActive {
            return
        }
        if let session = snapshot.sessions.first(where: { $0.permission != nil }) {
            considerSpokenApproval(for: session)
        }
    }

    func flushHeldVoiceTask(announcingFailure: Bool = true) {
        guard forcedScreen == nil, let prompt = heldVoiceTask else { return }
        if start(prompt, announcingFailure: announcingFailure, continueRestored: resumedSessionID != nil) {
            heldVoiceTask = nil
            WatchFeedback.success()
        }
    }

    func handleVoiceTurn(_ transcript: String, focused: GrokSession? = nil) {
        guard forcedScreen == nil else { return }
        let effect = VoiceTurnPlanner.effect(for: transcript, context: turnContext(focused: focused))
        heldVoiceTask = nil
        apply(effect)
    }

    func receiveVoice(_ raw: String) {
        guard forcedScreen == nil, let packet = VoiceWire.decode(raw) else { return }
        switch packet.kind {
        case .prepare, .audio:
            return
        case .ready:
            guard packet.utteranceID == prepareID else { return }
            prepareID = nil
            voiceStatus = packet.text == "on-device" ? "On-device speech" : "Speech on iPhone"
            capture.start()
        case .failure:
            guard packet.utteranceID == prepareID || packet.utteranceID == expectID else { return }
            prepareID = nil
            expectID = nil
            capture.stop()
            let reason = packet.text.isEmpty ? VoiceSpeechCopy.unavailable : packet.text
            if reason == VoiceSpeechCopy.missed {
                noteMissedUtterance()
            } else {
                offerDictation(reason)
            }
        case .transcript:
            guard packet.utteranceID == expectID else { return }
            if !packet.isLast {
                voiceLine = packet.text
                voiceStatus = "Hearing you"
                return
            }
            expectID = nil
            if let command = VoiceTranscriptGate.commandText(packet.text, isFinal: true) {
                missedTurns = 0
                voiceLine = ""
                remember("You: \(command)")
                handleVoiceTurn(command)
            } else {
                noteMissedUtterance()
            }
        }
    }

    func armListener(attempt: Int = 0) {
        guard forcedScreen == nil, appIsActive else { return }
        guard voiceModeActive || pendingAllowSessionID != nil else { return }
        guard !speakingReply, !capture.isRunning, prepareID == nil, !dictationPresented else { return }
        let phoneReachable = currentPhoneReachable()
        if phoneReachable {
            reachable = true
        }
        let route = VoiceListenPolicy.route(
            phoneReachable: phoneReachable,
            attempt: attempt,
            recognitionRefused: false,
            captureFailed: false,
            hostReady: hostIsReady
        )
        switch route {
        case .waitForPhone:
            voiceStatus = "Waiting for the iPhone"
            voiceLine = ListenEndpoint.waiting(pauseSends: VoicePreferences.shared.pauseSends)
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceListenPolicy.phoneWaitSpacing) { [weak self] in
                self?.armListener(attempt: attempt + 1)
            }
        case .presentDictation:
            fallBackToDictation(VoiceSpeechCopy.phoneAway, presentSheet: true)
        case .offerDictation:
            offerDictation(VoiceSpeechCopy.waiting)
        case .handsFree:
            beginCapture(attempt: attempt)
        case .handsFreeHost:
            beginHostCapture()
        @unknown default:
            offerDictation(VoiceSpeechCopy.unavailable)
        }
    }

    private func beginCapture(attempt: Int) {
        voiceSink = .phone
        capture.endsOnSilence = uiTest
            ? ListenEndpoint.endsOnSilence(pauseSends: VoicePreferences.shared.pauseSends)
            : true
        applyListenChrome()
        retainRuntime()
        capture.requestPermission { [weak self] granted in
            guard let self, self.voiceSink == .phone else { return }
            guard granted else {
                self.offerDictation(VoiceSpeechCopy.micDenied)
                return
            }
            let id = UUID().uuidString
            self.prepareID = id
            self.dictationOffered = false
            self.voiceStatus = "Listening"
            self.schedulePrepareTimeout(id)
            WatchVoiceLink.send(VoicePacket.prepare(id)) { [weak self] ok in
                guard let self, self.prepareID == id else { return }
                guard !ok else { return }
                self.prepareID = nil
                let next = attempt + 1
                let retry = VoiceListenPolicy.route(
                    phoneReachable: self.currentPhoneReachable(),
                    attempt: next,
                    recognitionRefused: false,
                    captureFailed: false,
                    hostReady: self.hostIsReady
                )
                switch retry {
                case .handsFree, .handsFreeHost, .waitForPhone:
                    self.armListener(attempt: next)
                case .presentDictation:
                    self.fallBackToDictation(VoiceSpeechCopy.phoneAway, presentSheet: true)
                case .offerDictation:
                    self.offerDictation(VoiceSpeechCopy.waiting)
                @unknown default:
                    self.offerDictation(VoiceSpeechCopy.unavailable)
                }
            }
        }
    }

    func noteMissedUtterance() {
        missedTurns += 1
        voiceLine = VoiceSpeechCopy.missed
        if missedTurns >= 3 {
            offerDictation(VoiceSpeechCopy.missed)
            return
        }
        relinquishListen(status: "Paused")
    }

    func offerDictation(_ reason: String) {
        guard forcedScreen == nil else { return }
        discardPendingHostAudio()
        capture.stop()
        ListenRuntime.shared.end()
        prepareID = nil
        expectID = nil
        voiceModeActive = true
        voiceLine = ""
        voiceStatus = ChatTranscript.isStatusNoise(reason) ? "Couldn't use the saved login" : reason
        dictationOffered = true
    }

    func fallBackToDictation(_ reason: String, presentSheet: Bool = false) {
        guard forcedScreen == nil else { return }
        voiceModeActive = true
        discardPendingHostAudio()
        capture.stop()
        ListenRuntime.shared.end()
        prepareID = nil
        expectID = nil
        voiceLine = ""
        voiceStatus = ChatTranscript.isStatusNoise(reason) ? "Couldn't use the saved login" : reason
        dictationOffered = true
        guard presentSheet else { return }
        presentDictationSheet()
    }

    func presentDictationSheet() {
        guard forcedScreen == nil, !dictationPresented else { return }
        dictationPresented = true
        voiceStatus = "Dictation"
        VoiceInput.present { [weak self] text in
            guard let self else { return }
            self.dictationPresented = false
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                self.voiceStatus = "Paused"
                return
            }
            self.handleVoiceTurn(trimmed)
        }
    }

    func confirmSpokenAllow() {
        guard let id = pendingAllowSessionID,
              let session = snapshot.sessions.first(where: { $0.id == id }),
              session.permission != nil else {
            pendingAllowSessionID = nil
            reply("Nothing is waiting for approval.", listenAfter: voiceModeActive)
            return
        }
        confirmPendingAllow(session)
    }

    func confirmPendingAllow(_ session: GrokSession) {
        guard pendingAllowSessionID == session.id else { return }
        pendingAllowSessionID = nil
        voiceNote = nil
        voiceNoteSessionID = nil
        WatchFeedback.success()
        allow(session)
        reply("Allowed.", listenAfter: voiceModeActive)
    }

    func noteVoiceSnapshot(previous: PhoneSnapshot, current: PhoneSnapshot) {
        guard forcedScreen == nil else { return }
        let speakResults = VoicePreferences.shared.readAloud || voiceModeActive
        let includeNew = previous.mode == current.mode
        let result = speakResults
            ? VoiceResultPicker.latestResult(previous: previous.sessions, current: current.sessions, includeNew: includeNew)
            : nil
        let oldIDs = Set(previous.sessions.compactMap(\.permission?.id))
        let arrived = current.sessions.first { session in
            guard let permission = session.permission else { return false }
            return !oldIDs.contains(permission.id)
        }
        if let arrived, hasLiveSnapshot, appIsActive, arrived.permission?.id != declinedVoicePermissionID {
            considerSpokenApproval(for: arrived)
            return
        }
        if let result {
            capture.stop()
            prepareID = nil
            expectID = nil
            if voiceModeActive {
                voiceLine = result.text
            }
            speakingReply = true
            voiceStatus = "Speaking"
            VoiceSpeaker.shared.speakNow(result.text, dedupeKey: result.sessionID + "\n" + result.text) { [weak self] in
                guard let self else { return }
                self.speakingReply = false
                guard self.voiceModeActive else { return }
                self.relinquishListen(status: "Sent")
            }
        }
    }

    private func beginAllowReadback(for session: GrokSession?, haptic: Bool = true) {
        guard let session, let permission = session.permission else {
            reply("Nothing is waiting for approval.", listenAfter: voiceModeActive)
            return
        }
        pendingAllowSessionID = session.id
        let line = VoiceAllowScript.readback(title: permission.title, detail: permission.detail)
        voiceNote = line
        voiceNoteSessionID = session.id
        if haptic {
            WatchFeedback.notification()
        }
        reply(line, listenAfter: true)
    }

    private func turnContext(focused: GrokSession?) -> VoiceTurnContext {
        VoiceTurnContext(
            inConversation: voiceModeActive,
            hostLabel: snapshot.hostLabel,
            linkTitle: snapshot.link.title,
            sessions: snapshot.sessions,
            computers: snapshot.computers,
            activeComputerID: snapshot.activeComputerID,
            focusedSessionID: focused?.id,
            pendingAllowSessionID: pendingAllowSessionID
        )
    }

    private func apply(_ effect: VoiceTurnEffect) {
        pendingAllowSessionID = effect.pendingAllowSessionID
        if effect.phase == .awaitingAllowYes {
            voiceNote = effect.spoken
            voiceNoteSessionID = effect.pendingAllowSessionID
        } else {
            voiceNote = nil
            voiceNoteSessionID = nil
        }
        if effect.listenAgain {
            voiceModeActive = true
        }
        switch effect.action {
        case .none:
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .allow(let sessionID):
            guard let session = session(sessionID) else {
                reply("Nothing is waiting for approval.", listenAfter: effect.listenAgain)
                return
            }
            WatchFeedback.success()
            allow(session)
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .deny(let sessionID):
            guard let session = session(sessionID) else {
                reply("Nothing is waiting.", listenAfter: effect.listenAgain)
                return
            }
            WatchFeedback.failure()
            deny(session)
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .stop(let sessionID):
            guard let session = session(sessionID) else {
                reply("Nothing is running.", listenAfter: effect.listenAgain)
                return
            }
            WatchFeedback.click()
            stop(session)
            reply(effect.spoken, listenAfter: effect.listenAgain)
        case .startTask(let prompt):
            rememberUser(prompt)
            heldVoiceTask = prompt
            flushHeldVoiceTask(announcingFailure: true)
            if heldVoiceTask == nil {
                if let banner, !banner.isEmpty {
                    reply("\(banner) \(effect.spoken)", listenAfter: effect.listenAgain)
                } else {
                    reply(effect.spoken, listenAfter: effect.listenAgain)
                }
            } else if promptIsQueued {
                voiceStatus = "Sending"
                voiceLine = ""
            } else if let banner, !banner.isEmpty {
                reply(banner, listenAfter: effect.listenAgain)
            } else {
                reply("Could not send that.", listenAfter: effect.listenAgain)
            }
        case .selectComputer(let id):
            selectComputer(id)
            if let banner, !banner.isEmpty {
                reply(banner, listenAfter: effect.listenAgain)
            } else {
                reply(effect.spoken, listenAfter: effect.listenAgain)
            }
        }
    }

    private func session(_ id: String) -> GrokSession? {
        snapshot.sessions.first { $0.id == id }
    }

    @discardableResult
    private func considerSpokenApproval(for session: GrokSession) -> Bool {
        guard hasLiveSnapshot, appIsActive, forcedScreen == nil else { return false }
        guard let permission = session.permission else { return false }
        if permission.id == declinedVoicePermissionID { return false }
        if spokenPermissionIDs.contains(permission.id) { return false }
        spokenPermissionIDs.insert(permission.id)
        voiceModeActive = true
        beginAllowReadback(for: session, haptic: false)
        return true
    }

    func schedulePrepareTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.prepareID == id else { return }
            self.prepareID = nil
            if self.hostIsReady {
                self.beginHostCapture()
                return
            }
            if self.currentPhoneReachable() {
                self.offerDictation(VoiceSpeechCopy.waiting)
            } else {
                self.fallBackToDictation(VoiceSpeechCopy.phoneAway, presentSheet: true)
            }
        }
    }

    func scheduleTranscriptTimeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.expectID == id else { return }
            self.expectID = nil
            self.noteMissedUtterance()
        }
    }

    func rememberUser(_ prompt: String) {
        let line = "You: \(prompt)"
        if voiceLog.last == line { return }
        remember(line)
    }

    func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ChatTranscript.isStatusNoise(trimmed) else { return }
        voiceLog.append(trimmed)
        if voiceLog.count > 80 {
            voiceLog.removeFirst(voiceLog.count - 80)
        }
    }

    private func reply(_ text: String, listenAfter: Bool) {
        capture.stop()
        discardPendingHostAudio()
        prepareID = nil
        expectID = nil
        voiceLine = text
        remember(text)
        speakingReply = true
        voiceStatus = "Speaking"
        VoiceSpeaker.shared.speakNow(text) { [weak self] in
            guard let self else { return }
            self.speakingReply = false
            guard listenAfter, self.voiceModeActive || self.pendingAllowSessionID != nil else {
                self.voiceStatus = ""
                return
            }
            self.relinquishListen(status: "Sent")
        }
    }
}
