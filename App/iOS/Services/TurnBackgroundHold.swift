import UIKit

/// iOS suspends a backgrounded app within seconds, and its SSH socket with it. While a turn is
/// running this asks for the finishing time iOS grants, so a short reply still streams in after
/// the screen locks. A longer turn keeps running on the computer and lands on the foreground
/// catch-up instead.
@MainActor
final class TurnBackgroundHold {
    private var task: UIBackgroundTaskIdentifier = .invalid
    /// iOS took the time back. Asking again before the app returns would only expire at once.
    private var spent = false

    var isHeld: Bool { task != .invalid }

    func update(turnRunning: Bool) {
        if turnRunning {
            begin()
        } else {
            end()
        }
    }

    func noteForeground() {
        spent = false
    }

    private func begin() {
        guard task == .invalid, !spent else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "grok-turn") { [weak self] in
            MainActor.assumeIsolated {
                self?.spent = true
                self?.end()
            }
        }
    }

    private func end() {
        guard task != .invalid else { return }
        let finished = task
        task = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}
