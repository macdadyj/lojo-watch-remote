import SwiftUI
import WatchRemoteCore

private enum SpeakBarSlot {
    /// The 44pt control plus a two-line hint, so neither covers the scroll view.
    static let height = VoiceChromeMetrics.maxSpeakBarHeight + 36
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
                    .frame(width: proxy.size.width, height: SpeakBarSlot.height, alignment: .bottom)
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
            Button {
                model.beginHandsFreeVoice()
            } label: {
                SpeakChromeLabel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("voice.speak")
            .accessibilityLabel("Voice conversation")
            .accessibilityHint("Starts listening. I'm done or the Action Button sends. A pause sends only when Pause sends is on.")
            .modifier(PrimaryHandGesture())
        }
    }
}

struct VoiceConversationBar: View {
    var showSpeak: Bool
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        SpeakChromeBar {
            if showSpeak {
                Button {
                    model.continueListening()
                } label: {
                    SpeakChromeLabel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("voice.speak")
                .accessibilityHint("Starts listening. I'm done or the Action Button sends.")
                .modifier(PrimaryHandGesture())
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
    }
}

private struct SpeakChromeLabel: View {
    var body: some View {
        Label("Speak", systemImage: "mic.fill")
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SpeakChromeBar<Leading: View>: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var model: WatchModel
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        VStack(spacing: 2) {
            Button {
                model.toggleFromActionButton()
            } label: {
                Text("Press the Action Button to talk")
                    .font(.caption2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice.action")
            .accessibilityLabel(ListenEndpoint.manualTitle)
            leading()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(scheme == .dark ? Color.black : Color(red: 0.95, green: 0.95, blue: 0.96))
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
