import SwiftUI
import WatchRemoteCore

/// Scroll content on top, the speak row in a fixed slot underneath.
/// The slot is a little taller than the 44pt bar so a bordered button cannot spill upward.
struct SpeakBarPage<Content: View, Bar: View>: View {
    private static let slot = VoiceChromeMetrics.maxSpeakBarHeight + 8
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                content()
                    .frame(
                        width: proxy.size.width,
                        height: max(proxy.size.height - Self.slot, 1)
                    )
                    .clipped()
                bar()
                    .frame(width: proxy.size.width, height: Self.slot, alignment: .center)
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
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 6) {
            leading()
            Spacer(minLength: 4)
            ActionBarButton()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: VoiceChromeMetrics.maxSpeakBarHeight)
        .background(scheme == .dark ? Color.black : Color(red: 0.95, green: 0.95, blue: 0.96))
    }
}

/// Icon plus a short word. The accessibility label keeps the full "Action Button" name.
private struct ActionBarButton: View {
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var preferences = VoicePreferences.shared

    var body: some View {
        Button {
            model.toggleFromActionButton()
        } label: {
            Label(ListenEndpoint.barLabel(pauseSends: preferences.pauseSends), systemImage: "button.programmable")
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voice.action")
        .accessibilityLabel(ListenEndpoint.title(pauseSends: preferences.pauseSends))
    }
}
