import SwiftUI
import WatchRemoteCore

/// One short row. History stays in the scroll view above it.
struct VoiceHomeBar: View {
    @EnvironmentObject private var model: WatchModel

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
            .accessibilityHint("Listens until you pause, then sends. Say allow, then yes. Deny and stop send on the first word.")
            Text(VoiceSpeechCopy.pauseSends)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 8) {
            if showSpeak {
                Button {
                    guard model.forcedScreen == nil else { return }
                    model.armListener()
                } label: {
                    Label("Speak", systemImage: "mic.fill")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("voice.speak")
                .accessibilityHint("Listens until you pause, then sends.")
            } else {
                Label(model.voiceStatus.isEmpty ? VoiceSpeechCopy.pauseSends : model.voiceStatus, systemImage: "mic.fill")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("voice.speak")
            }
            Spacer(minLength: 4)
            Button("End") {
                guard model.forcedScreen == nil else { return }
                model.endVoiceConversation()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("voice.end")
            .accessibilityHint("Leaves the voice conversation. The microphone stops.")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, VoiceChromeMetrics.speakVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: VoiceChromeMetrics.maxSpeakBarHeight, alignment: .leading)
        .clipped()
    }
}
