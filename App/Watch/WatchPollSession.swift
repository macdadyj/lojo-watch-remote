import Foundation

/// One HTTPS poll to the relay.
///
/// A fresh ephemeral session each time so the previous response's Alt-Svc hint is not reused.
/// URLSession otherwise tries HTTP/3 on the next poll in the same session, and HTTP/3 from the
/// Watch's own radio fails while HTTP/2 through the phone works. `waitsForConnectivity` is on so
/// a poll started while the radio is still coming up waits instead of failing at once.
final class WatchPollTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        var data: Data
        var response: HTTPURLResponse?
        var error: Error?
        var waitedForConnectivity: Bool
        /// The poll was cancelled because it outlived its deadline.
        var watchdogFired: Bool
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var waited = false
    private var watchdogFired = false
    private var resumed = false
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var waitingTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var waitingHandler: (@Sendable () -> Void)?

    /// Fires once, off the main actor, after the task has been waiting for a path.
    var onWaiting: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return waitingHandler
        }
        set {
            lock.lock()
            waitingHandler = newValue
            lock.unlock()
        }
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func invalidate() {
        finish(error: URLError(.cancelled), watchdog: false)
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
    }

    func post(_ request: URLRequest, timeout: TimeInterval) async -> Outcome {
        var request = request
        request.assumesHTTP3Capable = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                self.continuation = continuation
                self.buffer = Data()
                self.response = nil
                self.waited = false
                self.watchdogFired = false
                self.resumed = false
                let task = self.session?.dataTask(with: request)
                self.task = task
                self.lock.unlock()
                self.armWatchdog(timeout)
                task?.resume()
                if task == nil {
                    self.finish(error: URLError(.cannotConnectToHost), watchdog: false)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.lock()
        waited = true
        let alreadyArmed = waitingTimer != nil
        lock.unlock()
        guard !alreadyArmed else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.resumed ? nil : self.waitingHandler
            self.lock.unlock()
            handler?()
        }
        lock.lock()
        waitingTimer = timer
        lock.unlock()
        timer.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error, watchdog: false)
    }

    private func armWatchdog(_ timeout: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.resumed {
                self.lock.unlock()
                return
            }
            self.watchdogFired = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
            self.finish(error: URLError(.timedOut), watchdog: true)
        }
        lock.lock()
        watchdog = timer
        lock.unlock()
        timer.resume()
    }

    private func finish(error: Error?, watchdog: Bool) {
        lock.lock()
        if watchdog {
            watchdogFired = true
        }
        guard !resumed, let continuation else {
            lock.unlock()
            return
        }
        resumed = true
        let outcome = Outcome(
            data: buffer,
            response: response,
            error: error,
            waitedForConnectivity: waited,
            watchdogFired: watchdogFired
        )
        self.continuation = nil
        waitingTimer?.cancel()
        self.watchdog?.cancel()
        waitingTimer = nil
        self.watchdog = nil
        lock.unlock()
        continuation.resume(returning: outcome)
    }
}
