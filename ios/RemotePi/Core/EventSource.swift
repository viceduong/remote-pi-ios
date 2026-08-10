import Foundation

/// One parsed Server-Sent Events frame.
struct SSEFrame {
    var event: String = "message"
    var data: String = ""
    var id: String?
}

/**
 * Minimal, dependency-free SSE client built on URLSession streaming.
 *
 * - Parses the SSE wire format (event/data/id lines + blank-line terminator)
 * - Auto-reconnects with exponential backoff, sending `Last-Event-ID` so the
 *   server can replay missed events from its ring buffer
 * - Fires a callback for every parsed frame on the main queue
 *
 * iOS 15 compatible (URLSession dataTask streaming).
 */
final class EventSource: NSObject, URLSessionDataDelegate {
    enum State {
        case disconnected, connecting, connected
    }

    var onFrame: ((SSEFrame) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let url: URL
    private let token: String
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var lastEventId: String?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var closed = false

    init(url: URL, token: String) {
        self.url = url
        self.token = token
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func start() {
        closed = false
        connect()
    }

    func stop() {
        closed = true
        reconnectTask?.cancel()
        task?.cancel()
        task = nil
    }

    private func connect() {
        guard !closed else { return }
        setState(.connecting)
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let lastEventId {
            req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }
        task = session.dataTask(with: req)
        task?.resume()
    }

    private func scheduleReconnect() {
        guard !closed else { return }
        let delay = min(30, pow(2.0, Double(reconnectAttempts))) // 1, 2, 4, ... capped at 30s
        reconnectAttempts += 1
        setState(.connecting)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        parseBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed else { return }
        if let error {
            // Connection dropped — reconnect with Last-Event-ID.
            reconnectAttempts = 0
            scheduleReconnect()
        } else {
            setState(.disconnected)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            setState(.connected)
            reconnectAttempts = 0
        }
        completionHandler(.allow)
    }

    // MARK: - SSE parsing

    private func parseBuffer() {
        while let lineEnd = buffer.firstIndex(of: 0x0A) { // \n
            let end = buffer.index(after: lineEnd)
            let lineData = buffer[buffer.startIndex..<lineEnd]
            buffer.removeSubrange(buffer.startIndex..<end)
            let line = String(decoding: lineData, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            handleLine(line)
        }
    }

    private var frame = SSEFrame()

    private func handleLine(_ line: String) {
        if line.isEmpty {
            // Frame terminator — dispatch and reset.
            let completed = frame
            frame = SSEFrame()
            if !completed.data.isEmpty {
                onFrame?(completed)
            }
            return
        }
        if line.hasPrefix(":") { return } // comment / keepalive

        if let colon = line.firstIndex(of: ":") {
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() } // strip single leading space
            switch field {
            case "event": frame.event = value
            case "data": frame.data += frame.data.isEmpty ? value : "\n\(value)"
            case "id": frame.id = value
            default: break
            }
        }
    }

    private func setState(_ state: State) {
        onStateChange?(state)
    }
}
