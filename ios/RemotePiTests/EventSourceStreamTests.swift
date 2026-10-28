import XCTest
@testable import RemotePi

/// End-to-end tests of the REAL stream reader (URLSession bytes → line
/// splitter → SSE parser → frames). Regression: `bytes.lines` dropped the
/// empty lines that terminate SSE events, so no frame was ever dispatched and
/// the app only saw state via polling (no question cards, wrong status).
final class EventSourceStreamTests: XCTestCase {
    // MARK: Line splitter

    private func split(_ text: String) async throws -> [String] {
        let bytes = Array(text.utf8)
        let stream = AsyncStream<UInt8> { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
        var out: [String] = []
        for try await line in SSELineSplitter(bytes: stream) { out.append(line) }
        return out
    }

    func testSplitterKeepsEmptyLines() async throws {
        let lines = try await split("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n")
        XCTAssertEqual(lines, ["event: a", "data: 1", "", "event: b", "data: 2", ""])
    }

    func testSplitterHandlesCRLFAndCR() async throws {
        let lines = try await split("a\r\nb\r\n\r\nc\rd\r\r")
        XCTAssertEqual(lines, ["a", "b", "", "c", "d", ""])
    }

    func testSplitterKeepsUTF8() async throws {
        let lines = try await split("data: héllo 👋\n\n")
        XCTAssertEqual(lines, ["data: héllo 👋", ""])
    }

    // MARK: Full pipeline through URLSession

    final class StubSSEProtocol: URLProtocol {
        static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Deliver in small pieces, splitting lines/events across chunks.
            let body = Self.body
            var offset = 0
            while offset < body.count {
                let end = min(body.count, offset + 7)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            // Keep the stream open (like a real SSE connection).
        }
        override func stopLoading() {}
    }

    @MainActor
    func testEventSourceDeliversQuestionAndStatusFrames() async throws {
        StubSSEProtocol.body = Data("""
        retry: 3000
        : connected

        event: agent_status
        id: mvqc3vqi.8-181
        data: {"type":"agent_status","phase":"streaming","busy":true,"owner":"tui","activity":{"kind":"question","since":1},"questionId":"rq-1"}

        event: agent_question
        id: mvqc3vqi.8-181
        data: {"type":"agent_question","requestId":"rq-1","questions":[{"index":0,"question":"Pick one","multiSelect":false,"options":[{"label":"A","description":"a"}]}]}

        event: queue_update
        id: mvqc3vqi.8-181
        data: {"type":"queue_update","items":[]}


        """.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSSEProtocol.self]
        let source = EventSource(url: URL(string: "https://example.invalid/api/sessions/s/events")!,
                                 token: "t", configuration: config)
        var received: [ParsedSSEFrame] = []
        let got = expectation(description: "three frames")
        source.onFrames = { frames in
            received += frames
            if received.count >= 3 { got.fulfill() }
        }
        source.start()
        await fulfillment(of: [got], timeout: 5)
        source.stop()

        XCTAssertEqual(received.map(\.type), ["agent_status", "agent_question", "queue_update"])
        XCTAssertEqual(received[1].payload?["requestId"] as? String, "rq-1")
        XCTAssertNotNil(AgentQuestion(json: received[1].payload ?? [:]))
    }

    // MARK: Cursor advances only on delivery (contract §13 "Event cursor")

    /// A server that honours Last-Event-ID: frames s-1…s-3, then s-4 for a
    /// client resuming from s-3. Records every request's Last-Event-ID.
    final class ResumableSSEProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var _seen: [String?] = []
        static var seenCursors: [String?] {
            lock.lock(); defer { lock.unlock() }
            return _seen
        }
        static func reset() {
            lock.lock(); _seen = []; lock.unlock()
        }

        static func frame(_ n: Int) -> String {
            "event: message_update\nid: s-\(n)\ndata: {\"type\":\"message_update\",\"key\":\"assistant:1\",\"offset\":\(n - 1),\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"x\",\"offset\":\(n - 1)}}\n\n"
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let cursor = request.value(forHTTPHeaderField: "Last-Event-ID")
            Self.lock.lock(); Self._seen.append(cursor); Self.lock.unlock()
            let body: String
            switch cursor {
            case nil: body = (1...3).map(Self.frame).joined()
            case "s-3"?: body = Self.frame(4)
            default: body = ""
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            // Stream stays open.
        }
        override func stopLoading() {}
    }

    @MainActor
    func testStopBetweenParseAndDeliveryResendsFramesExactlyOnce() async throws {
        ResumableSSEProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResumableSSEProtocol.self]
        let source = EventSource(url: URL(string: "https://example.invalid/api/sessions/s/events")!,
                                 token: "t", configuration: config)
        var received: [String] = []
        var firstBatch: XCTestExpectation?
        var resumed: XCTestExpectation?
        source.onFrames = { frames in
            received += frames.compactMap(\.id)
            if received.count >= 3 { firstBatch?.fulfill(); firstBatch = nil }
            if received.count >= 4 { resumed?.fulfill(); resumed = nil }
        }
        source.start()

        // Hold the main actor (no drain can run) until all three frames are
        // parsed and waiting for delivery.
        let deadline = Date().addingTimeInterval(5)
        while source.pendingFrameCountForTesting < 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(source.pendingFrameCountForTesting, 3)
        XCTAssertNil(source.cursorForTesting, "parsing alone must not advance the cursor")

        // Stop before delivery (backgrounding / reconnect): the parsed frames
        // are discarded un-acknowledged…
        source.stop()
        XCTAssertNil(source.cursorForTesting)
        // …and the next connection asks for them again.
        firstBatch = expectation(description: "frames re-sent after restart")
        source.start()
        await fulfillment(of: [firstBatch!], timeout: 5)
        XCTAssertEqual(received, ["s-1", "s-2", "s-3"], "nothing lost, nothing duplicated")
        XCTAssertEqual(source.cursorForTesting, "s-3", "delivered frames advance the cursor")

        // A reconnect now resumes after the last DELIVERED frame.
        resumed = expectation(description: "resume from s-3")
        source.reconnectNow()
        await fulfillment(of: [resumed!], timeout: 5)
        source.stop()
        XCTAssertEqual(received, ["s-1", "s-2", "s-3", "s-4"])
        XCTAssertEqual(ResumableSSEProtocol.seenCursors, [nil, nil, "s-3"])
    }
}
