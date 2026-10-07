import WatchKit

/// Keeps a listen alive after the wrist drops.
///
/// An unexpected end pauses the microphone without dropping audio, the chat, or the relay.
@MainActor
final class ListenRuntime: NSObject, WKExtendedRuntimeSessionDelegate {
    static let shared = ListenRuntime()

    private var session: WKExtendedRuntimeSession?
    private var userEnded = false
    private(set) var isRunning = false
    var onUnexpectedEnd: (() -> Void)?

    func begin(onUnexpectedEnd: @escaping () -> Void) {
        self.onUnexpectedEnd = onUnexpectedEnd
        guard session == nil else { return }
        userEnded = false
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        session.start()
    }

    func end() {
        userEnded = true
        isRunning = false
        let ending = session
        session = nil
        ending?.invalidate()
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            self.isRunning = true
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            self.isRunning = false
            guard !self.userEnded else { return }
            self.onUnexpectedEnd?()
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            self.isRunning = false
            self.session = nil
            guard !self.userEnded else { return }
            switch reason {
            case .none:
                break
            case .sessionInProgress, .expired, .resignedFrontmost, .suppressedBySystem, .error:
                self.onUnexpectedEnd?()
            @unknown default:
                self.onUnexpectedEnd?()
            }
        }
    }
}

/// The Action Button runs `ToggleListenIntent`. Wrist raise does not.
@MainActor
enum ListenActionButton {
    static let activityType = "com.lojo.WatchRemote.listen"

    private static var handler: (() -> Void)?
    private static var pending = false

    static func register(_ handler: @escaping () -> Void) {
        self.handler = handler
        if pending {
            pending = false
            handler()
        }
    }

    static func press() {
        if let handler {
            handler()
        } else {
            pending = true
        }
    }
}
