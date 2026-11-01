import XCTest
@testable import RemotePi

/// Stubbed send/queue endpoints: sends stay pending until the test resolves
/// them (a "late ack"), cancels record their call and fail on demand.
@MainActor
final class StubChatQueueService: ChatQueueService {
    private(set) var calls: [String] = []
    private var pendingSends: [CheckedContinuation<TurnResponse, Error>] = []
    var pendingSendCount: Int { pendingSends.count }
    var cancelError: Error?
    var byClientError: Error?
    var queue: [QueueItem] = []

    func sendTurn(_ id: String, message: String, force: Bool,
                  clientMessageId: String?) async throws -> TurnResponse {
        calls.append("send:\(clientMessageId ?? "")")
        // Deliberately ignores task cancellation: the server may answer a
        // request the client has already abandoned.
        return try await withCheckedThrowingContinuation { continuation in
            pendingSends.append(continuation)
        }
    }

    func resolveSend(_ response: TurnResponse) {
        guard !pendingSends.isEmpty else { return XCTFail("no pending send") }
        pendingSends.removeFirst().resume(returning: response)
    }

    func failSend(_ error: Error) {
        guard !pendingSends.isEmpty else { return XCTFail("no pending send") }
        pendingSends.removeFirst().resume(throwing: error)
    }

    func fetchQueue(_ id: String) async throws -> [QueueItem] {
        calls.append("fetchQueue")
        return queue
    }

    func cancelQueued(_ id: String, itemId: String) async throws {
        calls.append("delete:\(itemId)")
        if let cancelError { throw cancelError }
    }

    func cancelQueuedByClient(_ id: String, clientMessageId: String) async throws {
        calls.append("deleteByClient:\(clientMessageId)")
        if let byClientError { throw byClientError }
    }
}

/// Contract §15: ✕ on every pending chip (labels, actions, cancel flows).
final class ChipLabelAndActionTests: XCTestCase {

    private func item(_ id: String, status: String, cid: String? = "c1", at: Int? = nil,
                      steered: Bool? = nil) -> QueueItem {
        QueueItem(id: id, clientMessageId: cid, message: "Also add tests", status: status,
                  queuedAt: at, steered: steered)
    }

    private func chip(_ item: QueueItem, serverId: String?, origin: QueueChip.Origin) -> QueueChip {
        QueueChip(rowId: "q:" + (item.clientMessageId ?? item.id), item: item, serverId: serverId, origin: origin)
    }

    private func assertActions(_ chip: QueueChip, cancel: Bool, steer: Bool,
                               file: StaticString = #filePath, line: UInt = #line) {
        let actions = ChatViewModel.chipActions(chip)
        XCTAssertEqual(actions.cancellable, cancel, "cancellable", file: file, line: line)
        XCTAssertEqual(actions.steerable, steer, "steerable", file: file, line: line)
    }

    func testActionsPerState() {
        // Pre-ack local send: ✕ only (addressed by clientMessageId).
        let sending = chip(item("pending:c1", status: "sending"), serverId: nil, origin: .local)
        assertActions(sending, cancel: true, steer: false)
        XCTAssertEqual(ChatViewModel.chipActionId(sending), "pending:c1")

        // Queued: ⚡ + ✕.
        let queued = chip(item("srv-1", status: "queued"), serverId: "srv-1", origin: .server)
        assertActions(queued, cancel: true, steer: true)
        XCTAssertEqual(ChatViewModel.chipActionId(queued), "srv-1")

        // Steered / running awaiting its echo (with and without §15 `steered`): ✕ only.
        let steered = chip(item("srv-1", status: "running", steered: true), serverId: "srv-1", origin: .server)
        assertActions(steered, cancel: true, steer: false)
        let running = chip(item("srv-1", status: "running"), serverId: "srv-1", origin: .server)
        assertActions(running, cancel: true, steer: false)
        XCTAssertEqual(ChatViewModel.chipActionId(running), "srv-1")

        // Acknowledged local send without a queue id: ✕ by clientMessageId.
        let ackedNoId = chip(item("pending:c1", status: "running"), serverId: nil, origin: .local)
        assertActions(ackedNoId, cancel: true, steer: false)
        XCTAssertEqual(ChatViewModel.chipActionId(ackedNoId), "pending:c1")

        // pi-native text: nothing to address.
        let native = chip(item("pi:0:x", status: "queued", cid: nil), serverId: nil, origin: .piNative)
        assertActions(native, cancel: false, steer: false)
        XCTAssertNil(ChatViewModel.chipActionId(native))
    }

    func testLabelsPerState() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let nowMs = 2_000_000_000
        XCTAssertEqual(ChatViewModel.chipStatus(item("pending:c1", status: "sending"), now: now), "sending…")
        XCTAssertEqual(ChatViewModel.chipStatus(item("srv-1", status: "queued", at: nowMs - 5_000), now: now),
                       "queued")
        XCTAssertEqual(ChatViewModel.chipStatus(item("srv-1", status: "queued", at: nowMs - 125_000), now: now),
                       "queued · 2m")
        XCTAssertEqual(ChatViewModel.chipStatus(item("srv-1", status: "running", steered: true), now: now),
                       "waiting for agent · after current step")
        XCTAssertEqual(ChatViewModel.chipStatus(item("srv-1", status: "running"), now: now),
                       "waiting for agent · after current step")
    }

    func testQueueItemDecodesOptionalSteered() throws {
        let json = #"{"items":[{"id":"a","message":"x","status":"running","steered":true},{"id":"b","message":"y","status":"queued"}]}"#
        struct Wrapper: Decodable { let items: [QueueItem] }
        let items = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).items
        XCTAssertEqual(items.map(\.steered), [true, nil])

        let sse = QueueItem(json: ["id": "a", "message": "x", "status": "running", "steered": true])
        XCTAssertEqual(sse?.steered, true)
        XCTAssertNil(QueueItem(json: ["id": "b", "message": "y"])?.steered)
    }

    func testCancelOutcomeMapping() {
        func outcome(_ error: Error) -> String {
            switch ChatViewModel.cancelOutcome(for: error) {
            case .cancelled: return "cancelled"
            case .alreadyDelivered: return "delivered"
            case .notFound: return "notFound"
            case .failed: return "failed"
            }
        }
        XCTAssertEqual(outcome(APIError.http(409, "x", "already_delivered")), "delivered")
        XCTAssertEqual(outcome(APIError.http(404, "Queued item not found", nil)), "notFound")
        XCTAssertEqual(outcome(APIError.http(502, "owner < v7", nil)), "failed")
        XCTAssertEqual(outcome(APIError.offline), "failed")
    }
}

@MainActor
final class CancelPendingFlowTests: XCTestCase {

    private var vms: [ChatViewModel] = []

    override func tearDown() async throws {
        for vm in vms { vm.stop() }
        vms.removeAll()
    }

    private func make() -> (ChatViewModel, StubChatQueueService) {
        let stub = StubChatQueueService()
        let vm = ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t"),
                               sessionId: "cancel-\(UUID().uuidString)", queueService: stub)
        vms.append(vm)
        return (vm, stub)
    }

    private func frame(_ json: [String: Any]) -> ParsedSSEFrame {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let payload = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ParsedSSEFrame(event: json["type"] as? String ?? "message", id: nil, payload: payload)
    }

    private func queueUpdate(_ items: [[String: Any]]) -> ParsedSSEFrame {
        frame(["type": "queue_update", "items": items])
    }

    private func serverItem(_ id: String, cid: String, status: String, steered: Bool? = nil) -> [String: Any] {
        var d: [String: Any] = ["id": id, "clientMessageId": cid, "message": "Also add tests",
                                "status": status, "queuedAt": 1_793_033_681_031]
        if let steered { d["steered"] = steered }
        return d
    }

    private func userEcho(cid: String) -> ParsedSSEFrame {
        frame(["type": "message_start", "key": "user:5000", "clientMessageId": cid,
               "message": ["role": "user", "content": [["type": "text", "text": "Also add tests"]],
                           "timestamp": 5000] as [String: Any]])
    }

    private func chips(_ vm: ChatViewModel) -> [TranscriptItem] {
        vm.commitNow()
        return vm.transcript.value.filter { $0.kind == .queued }
    }

    private func offlineRows(_ vm: ChatViewModel) -> [TranscriptItem] {
        vm.commitNow()
        return vm.transcript.value.filter { $0.kind == .offline }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Let spawned follow-up work (settling a cancel) run.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Pre-ack ("sending…")

    func testPreAckCancelThenLateAckCancelsByClientMessageId() async throws {
        let (vm, stub) = make()
        vm.send("Also add tests")
        try await waitUntil("the POST") { stub.pendingSendCount == 1 }
        let chip = try XCTUnwrap(chips(vm).first)
        XCTAssertEqual(chip.statusText, "sending…")
        XCTAssertTrue(chip.cancellable)
        XCTAssertFalse(chip.canSteer)
        let actionId = try XCTUnwrap(chip.actionId)
        XCTAssertTrue(actionId.hasPrefix("pending:"))
        let cid = String(actionId.dropFirst("pending:".count))

        vm.cancelQueued(actionId)
        XCTAssertTrue(chips(vm).isEmpty, "the chip goes at once")

        // The server got the request anyway and acknowledges it late.
        stub.resolveSend(TurnResponse(accepted: true, queued: true, queueItemId: "srv-9",
                                      queueDepth: 1, dispatched: false))
        try await waitUntil("the by-client DELETE") { stub.calls.contains("deleteByClient:\(cid)") }
        try await settle()
        XCTAssertFalse(stub.calls.contains("delete:srv-9"), "by-client succeeded — no fallback")

        // A queue_update that still lists it (sent before the cancel) stays hidden.
        vm.ingestForTesting([queueUpdate([serverItem("srv-9", cid: cid, status: "queued")])])
        XCTAssertTrue(chips(vm).isEmpty)
        XCTAssertTrue(offlineRows(vm).isEmpty)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.infoMessage)
    }

    func testPreAckCancelOfLostRequestCancelsItLaterIfItShowsUp() async throws {
        let (vm, stub) = make()
        stub.byClientError = APIError.http(404, "Not Found", nil)
        vm.send("Also add tests")
        try await waitUntil("the POST") { stub.pendingSendCount == 1 }
        let actionId = try XCTUnwrap(chips(vm).first?.actionId)
        let cid = String(actionId.dropFirst("pending:".count))

        vm.cancelQueued(actionId)
        // The abandoned request fails (as URLSession does on cancel)…
        stub.failSend(CancellationError())
        // …but may still have reached the server: cancel by clientMessageId.
        try await waitUntil("the by-client DELETE") { stub.calls.contains("deleteByClient:\(cid)") }
        try await settle()
        XCTAssertTrue(offlineRows(vm).isEmpty, "a cancelled send never goes to the offline outbox")
        XCTAssertTrue(chips(vm).isEmpty)

        // The server processed it after all: it is cancelled by queue id.
        vm.ingestForTesting([queueUpdate([serverItem("srv-7", cid: cid, status: "queued")])])
        XCTAssertTrue(chips(vm).isEmpty)
        try await waitUntil("the DELETE by queue id") { stub.calls.contains("delete:srv-7") }
        try await settle()
        XCTAssertTrue(chips(vm).isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Steered / running (§15)

    func testSteeredCancelSucceeds() async throws {
        let (vm, stub) = make()
        vm.ingestForTesting([queueUpdate([serverItem("srv-1", cid: "c1", status: "running", steered: true)])])
        let chip = try XCTUnwrap(chips(vm).first)
        XCTAssertEqual(chip.statusText, "waiting for agent · after current step")
        XCTAssertTrue(chip.cancellable)
        XCTAssertFalse(chip.canSteer)
        XCTAssertEqual(chip.actionId, "srv-1")

        vm.cancelQueued("srv-1")
        XCTAssertTrue(chips(vm).isEmpty, "optimistically hidden")
        try await waitUntil("the DELETE") { stub.calls.contains("delete:srv-1") }
        try await settle()
        // Lagging queue_update (still running) does not resurrect it.
        vm.ingestForTesting([queueUpdate([serverItem("srv-1", cid: "c1", status: "running", steered: true)])])
        XCTAssertTrue(chips(vm).isEmpty)
        vm.ingestForTesting([queueUpdate([])])
        XCTAssertTrue(chips(vm).isEmpty)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.infoMessage)
        XCTAssertEqual(stub.calls.filter { $0.hasPrefix("delete") }, ["delete:srv-1"])
    }

    func testAlreadyDeliveredShowsInfoAndChipStaysUntilEcho() async throws {
        let (vm, stub) = make()
        stub.cancelError = APIError.http(409, "already delivered", "already_delivered")
        vm.ingestForTesting([queueUpdate([serverItem("srv-1", cid: "c1", status: "running", steered: true)])])
        vm.cancelQueued("srv-1")
        XCTAssertTrue(chips(vm).isEmpty)

        try await waitUntil("the info") { vm.infoMessage != nil }
        XCTAssertEqual(vm.infoMessage, "Already delivered to the agent")
        XCTAssertNil(vm.errorMessage)
        let back = try XCTUnwrap(chips(vm).first, "the chip stays until its echo")
        XCTAssertEqual(back.statusText, "waiting for agent · after current step")
        XCTAssertFalse(back.cancellable, "no ✕ for a message pi already took")

        // The echo turns it into the user row.
        vm.ingestForTesting([userEcho(cid: "c1")])
        XCTAssertTrue(chips(vm).isEmpty)
        XCTAssertEqual(vm.transcript.value.filter { $0.kind == .user }.map(\.text), ["Also add tests"])
    }

    func testTransportFailureRollsBackWithError() async throws {
        let (vm, stub) = make()
        stub.cancelError = APIError.http(502, "update the host pi owner extension", nil)
        // Pre-§15 shape: running without `steered`.
        let running = serverItem("srv-1", cid: "c1", status: "running")
        stub.queue = [QueueItem(json: running)!]
        vm.ingestForTesting([queueUpdate([running])])
        XCTAssertTrue(try XCTUnwrap(chips(vm).first).cancellable)

        vm.cancelQueued("srv-1")
        XCTAssertTrue(chips(vm).isEmpty)
        try await waitUntil("the error") { vm.errorMessage != nil }
        try await waitUntil("the queue resync") { stub.calls.contains("fetchQueue") }
        try await settle()
        let back = try XCTUnwrap(chips(vm).first, "rolled back")
        XCTAssertTrue(back.cancellable, "the user may try again")
        XCTAssertEqual(back.statusText, "waiting for agent · after current step")
        XCTAssertNil(vm.infoMessage)
    }
}
