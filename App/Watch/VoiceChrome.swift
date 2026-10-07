import SwiftUI
import WatchRemoteCore

/// One short row. History stays in the scroll view above it.
struct VoiceHomeBar: View {
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var preferences = VoicePreferences.shared

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.beginHandsFreeVoice()
            } label: {
                Label("Speak", systemImage: "mic.fill")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("voice.speak")
            .accessibilityLabel("Voice conversation")
            .accessibilityHint("Starts listening. I'm done or the Action Button sends. A pause sends only when Pause sends is on.")
            Button {
                model.toggleFromActionButton()
            } label: {
                Text(ListenEndpoint.title(pauseSends: preferences.pauseSends))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice.action")
            .accessibilityLabel(ListenEndpoint.title(pauseSends: preferences.pauseSends))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, VoiceChromeMetrics.speakVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: VoiceChromeMetrics.maxSpeakBarHeight, alignment: .leading)
        .clipped()
    }
}

struct VoiceConversationBar: View {
    var showSpeak: Bool
    @EnvironmentObject private var model: WatchModel
    @ObservedObject private var preferences = VoicePreferences.shared

    var body: some View {
        HStack(spacing: 8) {
            if showSpeak {
                Button {
                    model.continueListening()
                } label: {
                    Label("Speak", systemImage: "mic.fill")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("voice.speak")
                .accessibilityHint("Starts listening. I'm done or the Action Button sends.")
            }
            Button {
                model.toggleFromActionButton()
            } label: {
                Text(ListenEndpoint.title(pauseSends: preferences.pauseSends))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice.action")
            .accessibilityLabel(ListenEndpoint.title(pauseSends: preferences.pauseSends))
            if !showSpeak {
                Button {
                    model.stopTalking()
                } label: {
                    Text("I'm done")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("voice.done")
                .accessibilityLabel("I'm done")
                .accessibilityHint("Stops the microphone and sends what you said. The chat stays open.")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, VoiceChromeMetrics.speakVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: VoiceChromeMetrics.maxSpeakBarHeight, alignment: .leading)
        .clipped()
    }
}
