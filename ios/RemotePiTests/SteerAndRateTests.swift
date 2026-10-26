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
