import Foundation

/// Measures what the connection actually achieves, rather than what the link
/// negotiated.
///
/// Link rate is a ceiling the radio agreed to; it says nothing about the path
/// beyond the router. This downloads a block of incompressible bytes and times
/// it, the same thing a browser speed test does.
///
/// It is the only part of Perch besides the updater that touches the network,
/// it never runs on its own, and it reports in megabits per second because
/// that is the unit every other speed test and every ISP quotes.
@MainActor
final class SpeedTest: ObservableObject {
    static let shared = SpeedTest()

    enum State: Equatable {
        case idle
        case latency
        case downloading(mbps: Double, progress: Double)
        case done(down: Double, latencyMS: Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Cloudflare's open speed endpoint: no account, no key, returns a stream
    /// of incompressible bytes of the requested size.
    private static let host = "speed.cloudflare.com"
    private static let payloadBytes = 25_000_000

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch state {
        case .latency, .downloading: return true
        default: return false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func start() {
        guard !isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let latency = try await self.measureLatency()
                if Task.isCancelled { return }
                let down = try await self.measureDownload()
                if Task.isCancelled { return }
                self.state = .done(down: down, latencyMS: latency)
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed("Could not reach the test server.")
            }
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    /// Median of five tiny round trips, so one slow packet does not set the number.
    private func measureLatency() async throws -> Double {
        state = .latency
        guard let url = URL(string: "https://\(Self.host)/__down?bytes=1") else {
            throw URLError(.badURL)
        }
        let s = session()
        var samples: [Double] = []
        for _ in 0..<5 {
            try Task.checkCancellation()
            let started = Date()
            _ = try await s.data(from: url)
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func measureDownload() async throws -> Double {
        guard let url = URL(string: "https://\(Self.host)/__down?bytes=\(Self.payloadBytes)") else {
            throw URLError(.badURL)
        }
        state = .downloading(mbps: 0, progress: 0)

        let probe = DownloadProbe(expected: Self.payloadBytes)
        probe.onProgress = { [weak self] mbps, progress in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.state = .downloading(mbps: mbps, progress: progress)
            }
        }
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            c.timeoutIntervalForRequest = 20
            c.httpShouldSetCookies = false
            return c
        }(), delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await probe.run(session: session, url: url)
        } onCancel: {
            probe.cancel()
        }
    }
}

/// Counts bytes as they arrive.
///
/// `URLSession.bytes` yields one `UInt8` at a time, so a 25 MB transfer would
/// spend its time in the iteration rather than on the wire and report a speed
/// far below the real one. The delegate hands over whole chunks instead.
private final class DownloadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expected: Int
    private let lock = NSLock()
    private var received = 0
    private var firstByteAt: Date?
    private var lastPublished = Date.distantPast
    private var continuation: CheckedContinuation<Double, Error>?
    private var task: URLSessionDataTask?

    var onProgress: ((Double, Double) -> Void)?

    init(expected: Int) { self.expected = expected }

    func run(session: URLSession, url: URL) async throws -> Double {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            continuation = c
            let t = session.dataTask(with: url)
            task = t
            lock.unlock()
            t.resume()
        }
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if firstByteAt == nil { firstByteAt = Date() }
        received += data.count
        let start = firstByteAt
        let total = received
        let due = Date().timeIntervalSince(lastPublished) > 0.15
        if due { lastPublished = Date() }
        lock.unlock()

        guard due, let start else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.05 else { return }
        onProgress?(Double(total) * 8 / elapsed / 1_000_000,
                    min(1, Double(total) / Double(expected)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        let total = received
        let start = firstByteAt
        lock.unlock()
        guard let c else { return }

        if let error {
            c.resume(throwing: error)
            return
        }
        guard let start, total > 0 else {
            c.resume(throwing: URLError(.zeroByteResource))
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else {
            c.resume(throwing: URLError(.zeroByteResource))
            return
        }
        c.resume(returning: Double(total) * 8 / elapsed / 1_000_000)
    }
}
