import SwiftUI
import WatchRemoteCore

private enum SpeakBarSlot {
    /// One slim row. The height cap keeps the mic from covering the transcript.
    static let height = min(40, VoiceChromeMetrics.maxSpeakBarHeight)
}

/// Scroll content on top, the speak row in a fixed slot underneath.
struct SpeakBarPage<Content: View, Bar: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                content()
                    .frame(
                        width: proxy.size.width,
                        height: max(proxy.size.height - SpeakBarSlot.height, 1)
                    )
                    .clipped()
                bar()
                    .frame(width: proxy.size.width, height: SpeakBarSlot.height, alignment: .center)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// One short row under the list. History stays in the scroll view above it.
struct VoiceHomeBar: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        SpeakChromeBar {
            SpeakMicButton(hint: "Starts listening. I'm done or the Action Button sends. A pause sends only when Pause sends is on.") {
                model.beginHandsFreeVoice()
            }
        }
    }
}

struct VoiceConversationBar: View {
    var showSpeak: Bool
    var onNewTask: () -> Void = {}
    var onOpenSession: (GrokSession) -> Void = { _ in }
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        SpeakChromeBar {
            HStack(spacing: 4) {
                chatMenu
                if showSpeak {
                    SpeakMicButton(hint: "Starts listening. I'm done or the Action Button sends.") {
                        model.continueListening()
                    }
                } else {
                    Button {
                        model.stopTalking()
                    } label: {
                        Text("I'm done")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("voice.done")
                    .accessibilityLabel("I'm done")
                    .accessibilityHint("Stops the microphone and sends what you said. The chat stays open.")
                    .modifier(PrimaryHandGesture())
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Chats, End, and New task stay off the transcript. Session rows still resume from here.
    private var chatMenu: some View {
        NavigationLink {
            ChatActionsPage(onNewTask: onNewTask, onOpenSession: onOpenSession)
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .fixedSize()
        .accessibilityLabel("Chat actions")
    }
}

/// watchOS has no Menu. These actions open on their own page so the transcript stays bubbles.
private struct ChatActionsPage: View {
    var onNewTask: () -> Void
    var onOpenSession: (GrokSession) -> Void
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button("Chats") {
                    model.voiceModeActive = false
                }
                .accessibilityIdentifier("chat.back")
                Button("End chat") {
                    model.endChat()
                }
                .accessibilityIdentifier("chat.end")
                Button("New task", action: onNewTask)
                ForEach(model.snapshot.sessions) { session in
                    Button(session.title) {
                        onOpenSession(session)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Chat")
    }
}

private struct SpeakMicButton: View {
    var hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(LojoTheme.accent))
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier("voice.speak")
        .accessibilityLabel("Voice conversation")
        .accessibilityHint(hint)
        .modifier(PrimaryHandGesture())
    }
}

private struct SpeakChromeBar<Control: View>: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var preferences = VoicePreferences.shared
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            actionControl
            if preferences.actionHintSeen {
                Spacer(minLength: 4)
            }
            control()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme == .dark ? Color.black : Color(red: 0.95, green: 0.95, blue: 0.96))
    }

    private var actionControl: some View {
        Button {
            model.toggleFromActionButton()
        } label: {
            if preferences.actionHintSeen {
                Image(systemName: "button.programmable")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            } else {
                Text("Press the Action Button to talk")
                    .font(.caption2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: 32, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(maxHeight: SpeakBarSlot.height)
        .accessibilityIdentifier("voice.action")
        .accessibilityLabel(ListenEndpoint.manualTitle)
    }
}

/// Double tap on supported watches runs the same control as the mic button.
private struct PrimaryHandGesture: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}
