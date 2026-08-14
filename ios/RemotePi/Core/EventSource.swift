import Foundation

/// One parsed Server-Sent Events frame.
struct SSEFrame {
    var event: String = "message"
    var data: String = ""
    var id: String?
}

private enum SSEParserError: LocalizedError {
    case frameTooLarge

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: return "SSE frame exceeded the 2 MiB safety limit"
        }
    }
}

/// Stateful SSE wire parser. It is confined to one EventSource task.
struct SSEParser {
    private static let maxFrameBytes = 2 * 1024 * 1024
    private var event = SSEFrame()
    private var retryMilliseconds: Int?
    private var lastEventId: String?

    mutating func consume(_ rawLine: String) throws -> SSEFrame? {
        var line = rawLine
        if line.last == "\r" { line.removeLast() }

        if line.isEmpty {
            let completed = event.data.isEmpty ? nil : event
            event = SSEFrame()
            return completed
        }
        if line.hasPrefix(":") { return nil }

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var v = String(line[line.index(after: colon)...])
            if v.first == " " { v.removeFirst() }
            value = v
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": event.event = value
        case "data":
            event.data += event.data.isEmpty ? value : "\n\(value)"
            guard event.data.utf8.count <= Self.maxFrameBytes else {
                throw SSEParserError.frameTooLarge
            }
        case "id":
            // SSE forbids NUL-containing IDs. Empty IDs reset the cursor.
            guard !value.contains("\0") else { return nil }
            event.id = value
            lastEventId = value
        case "retry":
            if let milliseconds = Int(value), milliseconds >= 0 {
                retryMilliseconds = milliseconds
            }
        default: break
        }
        return nil
    }

    /// Incomplete events at EOF are intentionally discarded. SSE dispatches
    /// only after a blank-line terminator; reconnect replay handles recovery.
    mutating func finish() {
        event = SSEFrame()
        retryMilliseconds = nil
    }

    mutating func takeRetryMilliseconds() -> Int? {
        defer { retryMilliseconds = nil }
        return retryMilliseconds
    }

    var cursor: String? { lastEventId }
}

/**
 * Dependency-free SSE client built on URLSession.AsyncBytes.
 *
 * The parser and reconnect loop are single-task confined. UI callbacks are
 * always delivered on MainActor. Reconnects use Last-Event-ID, server retry
 * hints, bounded exponential backoff, and jitter.
 */
final class EventSource {
    enum State: Equatable {
        case disconnected, connecting, connected
    }

    var onFrame: ((SSEFrame) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?

    private let url: URL
    private let token: String
    private let session: URLSession
    private var runTask: Task<Void, Never>?
    private let lock = NSLock()
    private var closed = true
    private var generation = 0
    private var lastEventId: String?
    private var retryDelay: TimeInterval = 1

    init(url: URL, token: String) {
        self.url = url
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache",
        ]
        self.session = URLSession(configuration: config)
    }

    func start() {
        lock.lock()
        guard runTask == nil else { lock.unlock(); return }
        closed = false
        generation += 1
        let currentGeneration = generation
        lock.unlock()
        runTask = Task { [weak self] in
            await self?.run(generation: currentGeneration)
        }
    }

    func stop() {
        lock.lock()
        closed = true
        generation += 1
        let task = runTask
        runTask = nil
        lock.unlock()
        task?.cancel()
        emitState(.disconnected, generation: nil)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && self.generation == generation
    }

    private func currentCursor() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastEventId
    }

    private func updateCursor(_ cursor: String?) {
        guard let cursor else { return }
        lock.lock(); lastEventId = cursor; lock.unlock()
    }

    private func run(generation: Int) async {
        var parser = SSEParser()
        var openedAt: Date?

        while isCurrent(generation) {
            emitState(.connecting, generation: generation)
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let cursor = currentCursor(), !cursor.isEmpty {
                request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
            }

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    let error = StreamHTTPError(statusCode: http.statusCode)
                    emitError(error.localizedDescription, generation: generation)
                    if [401, 403, 404].contains(http.statusCode) { break }
                    throw error
                }
                guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                      contentType.lowercased().contains("text/event-stream") else {
                    throw StreamHTTPError(statusCode: http.statusCode, detail: "invalid SSE Content-Type")
                }

                openedAt = Date()
                emitState(.connected, generation: generation)
                for try await line in bytes.lines {
                    guard isCurrent(generation) else { break }
                    let frame = try parser.consume(line)
                    if let retry = parser.takeRetryMilliseconds() {
                        setRetryDelay(TimeInterval(retry) / 1000)
                    }
                    if let frame {
                        updateCursor(parser.cursor)
                        emitFrame(frame, generation: generation)
                    }
                }
                parser.finish()
                guard isCurrent(generation) else { break }
                emitError("SSE stream ended", generation: generation)
            } catch is CancellationError {
                break
            } catch {
                guard isCurrent(generation) else { break }
                emitError(error.localizedDescription, generation: generation)
            }

            guard isCurrent(generation) else { break }
            emitState(.disconnected, generation: generation)
            let connectedLongEnough = openedAt.map { Date().timeIntervalSince($0) >= 60 } ?? false
            if connectedLongEnough { setRetryDelay(1) }
            let delay = nextDelay()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                break
            }
        }

        lock.lock()
        if self.generation == generation { runTask = nil }
        lock.unlock()
        emitState(.disconnected, generation: generation)
    }

    private func setRetryDelay(_ value: TimeInterval) {
        lock.lock(); retryDelay = min(30, max(0.25, value)); lock.unlock()
    }

    private func nextDelay() -> TimeInterval {
        lock.lock()
        let base = min(30, max(0.25, retryDelay))
        retryDelay = min(30, base * 2)
        lock.unlock()
        return base * Double.random(in: 0.75...1.25)
    }

    private func emitState(_ state: State, generation: Int?) {
        if let generation, !isCurrent(generation) { return }
        Task { @MainActor [weak self] in
            self?.onStateChange?(state)
        }
    }

    private func emitFrame(_ frame: SSEFrame, generation: Int) {
        guard isCurrent(generation) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.onFrame?(frame)
        }
    }

    private func emitError(_ message: String, generation: Int) {
        guard isCurrent(generation) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.onError?(message)
        }
    }
}

private struct StreamHTTPError: LocalizedError {
    let statusCode: Int
    var detail: String?

    init(statusCode: Int, detail: String? = nil) {
        self.statusCode = statusCode
        self.detail = detail
    }

    var errorDescription: String? {
        detail ?? "SSE HTTP error \(statusCode)"
    }
}
