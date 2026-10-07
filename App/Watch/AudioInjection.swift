import Foundation
import WatchRemoteCore

/// Debug and UI-test hook. A normal launch never reads a clip.
/// The Watch UI tests pass `-WatchRemoteUITest` and `-WatchRemoteInjectClip`.
enum WatchAudioInjection {
    static func samples(named name: String) -> [Float]? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        guard let url = Bundle.main.url(forResource: base, withExtension: "wav") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let samples = VoiceWAV.monoFloats(data: data)
        guard let samples, !samples.isEmpty else { return nil }
        return samples
    }
}
