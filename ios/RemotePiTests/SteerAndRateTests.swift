import XCTest
@testable import RemotePi

/// Task 2 (tokens/sec meter) + Task 3 (send-now / steer chip reconciliation).
final class SteerAndRateTests: XCTestCase {

    // MARK: - TokenRateMeter (tokens/sec, Task 2)

    private func t(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func testFirstSampleSeedsAndEmitsNothing() {
        var meter = TokenRateMeter()
        XCTAssertNil(meter.record(outputTokens: 0, at: t(0)), "the first usage frame is only a baseline")
    }

    func testRateIsOutputDeltaOverWallClock() throws {
        var meter = TokenRateMeter(alpha: 0.4, minInterval: 0.2)
        XCTAssertNil(meter.record(outputTokens: 0, at: t(0)))
        // 10 new output tokens over 1s → 10 tok/s (first real sample seeds EMA).
        XCTAssertEqual(try XCTUnwrap(meter.record(outputTokens: 10, at: t(1))), 10, accuracy: 0.001)
        // 20 more over 1s = 20 instantaneous; EMA = 0.4*20 + 0.6*10 = 14.
        XCTAssertEqual(try XCTUnwrap(meter.record(outputTokens: 30, at: t(2))), 14, accuracy: 0.001)
    }

    func testSamplesCloserThanMinIntervalAccumulate() throws {
        var meter = TokenRateMeter(alpha: 0.4, minInterval: 0.2)
        XCTAssertNil(meter.record(outputTokens: 0, at: t(0)))
        // 0.1s gap < 0.2s minInterval: skipped, baseline NOT advanced.
        XCTAssertNil(meter.record(outputTokens: 5, at: t(0.1)))
        // Now 0.3s since the baseline, 10 tokens → 10/0.3 ≈ 33.3 tok/s.
        XCTAssertEqual(try XCTUnwrap(meter.record(outputTokens: 10, at: t(0.3))),
                       10.0 / 0.3, accuracy: 0.01)
    }

    func testCounterDecreaseReseedsForNewTurn() throws {
        var meter = TokenRateMeter(alpha: 0.4, minInterval: 0.2)
        XCTAssertNil(meter.record(outputTokens: 100, at: t(0)))
        XCTAssertEqual(try XCTUnwrap(meter.record(outputTokens: 200, at: t(1))), 100, accuracy: 0.001)
        // Cumulative counter dropped (a fresh turn): reseed, emit nothing.
        XCTAssertNil(meter.record(outputTokens: 5, at: t(2)))
        // Next real sample starts the EMA from scratch, no spike from the drop.
        XCTAssertEqual(try XCTUnwrap(meter.record(outputTokens: 15, at: t(3))), 10, accuracy: 0.001)
    }

    func testResetClearsState() {
        var meter = TokenRateMeter()
        _ = meter.record(outputTokens: 0, at: t(0))
        _ = meter.record(outputTokens: 50, at: t(1))
        meter.reset()
        // After reset the next frame is again just a baseline.
        XCTAssertNil(meter.record(outputTokens: 999, at: t(2)))
    }

    // MARK: - Chip actions (send-now / cancel eligibility, Task 3)

    private func queue(_ id: String, _ text: String, status: String = "queued",
                       cid: String? = nil, at: Int? = nil) -> QueueItem {
        QueueItem(id: id, clientMessageId: cid, message: text, status: status, queuedAt: at)
    }

    private func chip(_ item: QueueItem, serverId: String?, origin: QueueChip.Origin) -> QueueChip {
        QueueChip(rowId: "q:" + (item.clientMessageId ?? item.id), item: item,
                  serverId: serverId, origin: origin)
    }

    func testQueuedServerChipIsCancellableAndSteerable() {
        let c = chip(queue("srv-1", "deploy", status: "queued", cid: "c1"), serverId: "srv-1", origin: .server)
        let actions = ChatViewModel.chipActions(c)
        XCTAssertTrue(actions.cancellable)
        XCTAssertTrue(actions.steerable)
    }

    func testRunningChipIsNeither() {
        // After a steer the chip flips queued → running in place: no longer
        // cancellable/steerable, and (below) still the same row — no duplicate.
        let c = chip(queue("srv-1", "deploy", status: "running", cid: "c1"), serverId: "srv-1", origin: .server)
        let actions = ChatViewModel.chipActions(c)
        XCTAssertFalse(actions.cancellable)
        XCTAssertFalse(actions.steerable)
    }

    func testLocalSendingChipWithoutServerIdIsNeither() {
        let c = chip(queue("pending:c1", "hi", status: "sending", cid: "c1"), serverId: nil, origin: .local)
        let actions = ChatViewModel.chipActions(c)
        XCTAssertFalse(actions.cancellable)
        XCTAssertFalse(actions.steerable)
    }

    func testPiNativeChipIsNeither() {
        let c = chip(queue("pi:0:x", "steer text", status: "queued"), serverId: nil, origin: .piNative)
        let actions = ChatViewModel.chipActions(c)
        XCTAssertFalse(actions.cancellable)
        XCTAssertFalse(actions.steerable)
    }

    func testSteerKeepsRowIdentitySoNoDuplicateChip() {
        // Queued → running is an in-place status flip; the reconciler keys the
        // chip row on the clientMessageId, so the row id is unchanged.
        let queued = QueueReconciler.reconcile(localPending: [],
                                               server: [queue("srv-1", "deploy", status: "queued", cid: "c1")],
                                               piNative: [], messages: [])
        let running = QueueReconciler.reconcile(localPending: [],
                                                server: [queue("srv-1", "deploy", status: "running", cid: "c1")],
                                                piNative: [], messages: [])
        XCTAssertEqual(queued.chips.count, 1)
        XCTAssertEqual(running.chips.count, 1)
        XCTAssertEqual(queued.chips.first?.rowId, running.chips.first?.rowId,
                       "steering keeps the same transcript row — the chip never duplicates")
    }
}

/// Live-object behaviour of the inherited tok/s + send-now work: when the
/// rate is shown, and how a steered chip renders (MainActor types).
@MainActor
final class LiveRateAndSteerStateTests: XCTestCase {

    private func usage(_ output: Int) -> SessionUsage {
        SessionUsage(json: ["input": 1_000, "output": output])!
    }

    private func busy(_ kind: AgentActivity.Kind, tool: String? = nil) -> AgentStatusState.Event {
        .status(busy: true, owner: "bridge", v2: true, isSnapshot: false,
                activity: AgentActivity(kind: kind, tool: tool), hasActivity: true)
    }

    func testRateShownOnlyWhileModelStreamsOutput() {
        let status = ChatLiveStatus()
        let t0 = Date()
        // Optimistic "Waiting…" (no confirmed turn): usage never shows a rate.
        status.apply(.optimisticSend)
        status.setUsage(usage(0), at: t0)
        status.setUsage(usage(40), at: t0.addingTimeInterval(1))
        XCTAssertNil(status.tokensPerSecond)

        status.apply(busy(.writing))
        XCTAssertTrue(status.isStreamingOutput)
        status.setUsage(usage(100), at: t0.addingTimeInterval(2))
        status.setUsage(usage(160), at: t0.addingTimeInterval(3))
        XCTAssertEqual(status.tokensPerSecond, 60)

        // thinking ↔ writing keeps the meter (still streaming output).
        status.apply(busy(.thinking))
        XCTAssertEqual(status.tokensPerSecond, 60)

        // A tool run hides the readout immediately and ignores usage frames.
        status.apply(busy(.tool, tool: "bash"))
        XCTAssertFalse(status.isStreamingOutput)
        XCTAssertNil(status.tokensPerSecond)
        status.setUsage(usage(170), at: t0.addingTimeInterval(30))
        XCTAssertNil(status.tokensPerSecond)

        // Next message: fresh baseline — no sample spanning the tool run.
        status.apply(busy(.writing))
        status.setUsage(usage(5), at: t0.addingTimeInterval(31))
        XCTAssertNil(status.tokensPerSecond, "first frame after a gap is only a baseline")
        status.setUsage(usage(35), at: t0.addingTimeInterval(32))
        XCTAssertEqual(status.tokensPerSecond, 30)

        // Idle clears it and a final idle usage frame doesn't revive it.
        status.apply(.status(busy: false, owner: "bridge", v2: true, isSnapshot: false,
                             activity: nil, hasActivity: true))
        XCTAssertNil(status.tokensPerSecond)
        status.setUsage(usage(400), at: t0.addingTimeInterval(33))
        XCTAssertNil(status.tokensPerSecond)
    }

    func testRateIsSmoothedNotJumpy() {
        let status = ChatLiveStatus()
        let t0 = Date()
        status.apply(busy(.writing))
        status.setUsage(usage(0), at: t0)
        status.setUsage(usage(50), at: t0.addingTimeInterval(1))     // 50 tok/s seeds
        status.setUsage(usage(250), at: t0.addingTimeInterval(2))    // burst: 200 instant
        let shown = status.tokensPerSecond ?? 0
        XCTAssertGreaterThan(shown, 50)
        XCTAssertLessThan(shown, 120, "a single burst moves the readout only part of the way")
    }

    private func queueFrame(status: String) -> ParsedSSEFrame {
        let json = #"{"type":"queue_update","items":[{"id":"srv-1","clientMessageId":"c1","message":"Also add tests","status":"\#(status)","queuedAt":1793033681031}]}"#
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: "queue_update", id: nil, payload: payload)
    }

    func testSteeredChipKeepsRowAndIgnoresLaggingQueuedStatus() throws {
        let vm = ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t"),
                               sessionId: "steer-tests")
        vm.ingestForTesting([queueFrame(status: "queued")])
        vm.commitNow()
        let before = try XCTUnwrap(vm.transcript.value.first { $0.kind == .queued })
        XCTAssertTrue(before.canSteer)
        XCTAssertTrue(before.cancellable)
        XCTAssertEqual(before.actionId, "srv-1")

        vm.steerQueued("srv-1")
        vm.commitNow()
        let after = try XCTUnwrap(vm.transcript.value.first { $0.kind == .queued })
        XCTAssertEqual(after.id, before.id, "same row — no duplicate, no recreation")
        XCTAssertEqual(vm.transcript.value.filter { $0.kind == .queued }.count, 1)
        XCTAssertFalse(after.canSteer, "no second send-now while one is in flight")
        XCTAssertEqual(after.statusText, "sending")

        // A lagging queue_update still saying `queued` must not flip it back.
        vm.ingestForTesting([queueFrame(status: "queued")])
        vm.commitNow()
        let lagged = try XCTUnwrap(vm.transcript.value.first { $0.kind == .queued })
        XCTAssertEqual(lagged.statusText, "sending")
        XCTAssertFalse(lagged.canSteer)
        vm.stop()
    }

    func testPiNativeSteerEchoDoesNotDuplicateDeliveredChip() {
        // Server item (running, steered) already echoed as a user row, while
        // pi's own steering queue still lists the text: no chip at all.
        let server = QueueItem(id: "srv-1", clientMessageId: "c1", message: "Also add tests",
                               status: "running", queuedAt: 1_000)
        let echo = ChatMessage(entryId: "e1", clientMessageId: "c1", role: .user, text: "Also add tests",
                               thinking: nil, toolCalls: [], isError: false, toolName: nil,
                               isSystemNote: false, model: nil, errorMessage: nil, timestamp: 2_000)
        let result = QueueReconciler.reconcile(localPending: [], server: [server],
                                               piNative: ["Also add tests"], messages: [echo])
        XCTAssertTrue(result.chips.isEmpty)
        // An unrelated pi-native text is still shown.
        let other = QueueReconciler.reconcile(localPending: [], server: [server],
                                              piNative: ["something else"], messages: [echo])
        XCTAssertEqual(other.chips.map(\.origin), [.piNative])
    }
}
