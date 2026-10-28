import XCTest
@testable import RemotePi

final class ChatMergerTests: XCTestCase {

    private func msg(entryId: String? = nil, role: MessageRole = .assistant,
                     text: String, ts: Int?, cid: String? = nil) -> ChatMessage {
        ChatMessage(entryId: entryId, clientMessageId: cid, role: role, text: text, thinking: nil,
                    toolCalls: [], isError: false, toolName: nil, isSystemNote: false,
                    model: nil, errorMessage: nil, timestamp: ts)
    }

    // MARK: - Steered messages keep server order (device report)

    /// pi stamps a steered user message when it is QUEUED but appends it
    /// after the rows produced while it waited. Live sources must keep arrival
    /// (server) order, not move it above the agent's latest messages.
    func testLiveSteeredUserEchoWithOlderTimestampGoesToTail() {
        var list = [
            msg(entryId: "a1", text: "working on it", ts: 1_000),
            msg(entryId: "a2", text: "still digging, found the cause", ts: 5_000),
        ]
        let echo = msg(role: .user, text: "also check the logs", ts: 2_000, cid: "c1")
        ChatMerger.merge(&list, [echo], placement: .tail)
        XCTAssertEqual(list.map(\.text), ["working on it", "still digging, found the cause", "also check the logs"])
    }

    func testFileTailBatchWithSteeredUserRowKeepsServerOrder() {
        var list = [msg(entryId: "a1", text: "step one", ts: 1_000)]
        let batch = [
            msg(entryId: "a2", text: "step two", ts: 6_000),
            msg(entryId: "u1", role: .user, text: "steer: stop after this", ts: 3_000),
            msg(entryId: "a3", text: "ok, stopping", ts: 7_000),
        ]
        ChatMerger.merge(&list, batch, placement: .tail)
        XCTAssertEqual(list.map(\.entryId), ["a1", "a2", "u1", "a3"])
    }

    func testTailPlacementStaysAboveStreamingBubble() {
        var list = [msg(entryId: "a1", text: "done", ts: 1_000),
                    msg(text: "streaming…", ts: nil)]
        ChatMerger.merge(&list, [msg(role: .user, text: "next", ts: 500)], placement: .tail)
        XCTAssertEqual(list.map(\.text), ["done", "next", "streaming…"])
    }

    func testOlderPageStillPlacedByTimestamp() {
        var list = [msg(entryId: "a5", text: "recent", ts: 9_000)]
        ChatMerger.merge(&list, [msg(entryId: "a1", text: "old", ts: 1_000)])
        XCTAssertEqual(list.map(\.entryId), ["a1", "a5"])
    }

    // MARK: - Legacy behaviour (kept)

    func testAppendsNewMessages() {
        var list = [msg(entryId: "m1", text: "hello", ts: 100)]
        ChatMerger.append(&list, [msg(entryId: "m2", text: "world", ts: 200)])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.entryId), ["m1", "m2"])
    }

    func testDedupesByEntryId() {
        var list = [msg(entryId: "m1", text: "hello", ts: 100)]
        ChatMerger.merge(&list, [msg(entryId: "m1", text: "hello", ts: 101)])
        XCTAssertEqual(list.count, 1)
    }

    func testDedupesOptimisticVsServerCopy() {
        // Identity-less local copy vs server echo: heuristic applies.
        var list = [msg(role: .user, text: "hi there", ts: 1000)]
        ChatMerger.merge(&list, [msg(entryId: "m9", role: .user, text: "hi there", ts: 1001)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].entryId, "m9")
    }

    func testReplacePartialStreamWithFullCopy() {
        var list = [msg(entryId: "a1", text: "The quick brown fox", ts: 100)]
        ChatMerger.merge(&list, [msg(entryId: "a1", text: "The quick brown fox jumps over the lazy dog", ts: 100)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "The quick brown fox jumps over the lazy dog")
    }

    func testContinuationWithoutEntryIdReplaces() {
        var list = [msg(role: .assistant, text: "First part of a long", ts: 50)]
        ChatMerger.merge(&list, [msg(role: .assistant, text: "First part of a long response continues here", ts: 52)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "First part of a long response continues here")
    }

    func testDistinctMessagesAppendEvenWithSharedPrefix() {
        var list = [msg(entryId: "x1", role: .user, text: "what is the weather", ts: 10)]
        ChatMerger.merge(&list, [msg(entryId: "x2", role: .user, text: "what is the weather tomorrow", ts: 5000)])
        XCTAssertEqual(list.count, 2)
    }

    func testSameRoleDifferentContentAppends() {
        var list = [msg(role: .assistant, text: "first answer", ts: 1)]
        ChatMerger.merge(&list, [msg(role: .assistant, text: "second answer", ts: 2)])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.text), ["first answer", "second answer"])
    }

    func testReplacementPreservesRowIdentity() {
        var list = [msg(entryId: "a1", text: "partial", ts: 100)]
        let originalID = list[0].id
        ChatMerger.merge(&list, [msg(entryId: "a1", text: "partial complete", ts: 100)])
        XCTAssertEqual(list[0].id, originalID)
    }

    // MARK: - I10: duplicates never crash

    func testDuplicateEntryIdsInExistingDoNotCrash() {
        var list = [msg(entryId: "dup", text: "one", ts: 1), msg(entryId: "dup", text: "two", ts: 2)]
        ChatMerger.merge(&list, [msg(entryId: "dup", text: "three", ts: 2), msg(entryId: "n", text: "new", ts: 3)])
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.last?.entryId, "n")
    }

    func testDuplicateEntryIdsInIncomingAreCollapsed() {
        var list: [ChatMessage] = []
        ChatMerger.merge(&list, [msg(entryId: "e", text: "a", ts: 1), msg(entryId: "e", text: "a", ts: 1)])
        XCTAssertEqual(list.count, 1)
    }

    // MARK: - I15: identical short texts with distinct ids are kept

    func testIdenticalShortTextsWithDistinctEntryIdsAreKept() {
        var list = [msg(entryId: "u1", role: .user, text: "ok", ts: 1000)]
        ChatMerger.merge(&list, [msg(entryId: "u2", role: .user, text: "ok", ts: 1500)])
        XCTAssertEqual(list.count, 2)
    }

    func testDistinctClientIdsAreNotMergedByText() {
        var list = [msg(role: .user, text: "continue", ts: 1000, cid: "c1")]
        ChatMerger.merge(&list, [msg(entryId: "e2", role: .user, text: "continue", ts: 1001, cid: "c2")])
        XCTAssertEqual(list.count, 2)
    }

    // MARK: - clientMessageId reconciliation

    func testClientMessageIdWinsOverText() {
        var list = [msg(role: .user, text: "hello", ts: 1000, cid: "c1")]
        let localId = list[0].id
        ChatMerger.merge(&list, [msg(entryId: "e9", role: .user, text: "hello (server-normalized)", ts: 99_999, cid: "c1")])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, localId, "row identity must survive the echo")
        XCTAssertEqual(list[0].entryId, "e9")
    }

    // MARK: - I3: ordering, never dropping server rows

    func testNewServerRowsInsertBeforeStreamingBubble() {
        var list = [
            msg(entryId: "u1", role: .user, text: "first", ts: 100),
            msg(entryId: "a1", text: "answer", ts: 200),
            msg(text: "streaming partial", ts: nil),
        ]
        ChatMerger.merge(&list, [msg(entryId: "u2", role: .user, text: "second prompt", ts: 300)])
        XCTAssertEqual(list.map(\.text), ["first", "answer", "second prompt", "streaming partial"])
    }

    func testRecoveredRowIsInsertedByTimestampNotAppended() {
        var list = [
            msg(entryId: "u1", role: .user, text: "q1", ts: 100),
            msg(entryId: "a2", text: "a2", ts: 300),
        ]
        ChatMerger.merge(&list, [msg(entryId: "u2", role: .user, text: "q2", ts: 200)])
        XCTAssertEqual(list.map(\.entryId), ["u1", "u2", "a2"])
    }

    func testServerOrderIsFollowedAfterAnAnchor() {
        var list = [msg(entryId: "a", text: "A", ts: 100), msg(entryId: "z", text: "Z", ts: 900)]
        // Server says: a, b, c (b/c newer than a, older than z).
        ChatMerger.merge(&list, [msg(entryId: "a", text: "A", ts: 100),
                                 msg(entryId: "b", text: "B", ts: 200),
                                 msg(entryId: "c", text: "C", ts: 300)])
        XCTAssertEqual(list.map(\.entryId), ["a", "b", "c", "z"])
    }

    func testReplaceTailKeepsOlderRowsDropsVanishedAndKeepsBubble() {
        var list = [
            msg(entryId: "e0", text: "old", ts: 50),
            msg(entryId: "e1", text: "one", ts: 100),
            msg(entryId: "e2", text: "gone", ts: 200),
            msg(text: "streaming", ts: nil),
        ]
        let e1Id = list[1].id
        ChatMerger.replaceTail(&list, with: [msg(entryId: "e1", text: "one", ts: 100),
                                              msg(entryId: "e3", text: "three", ts: 300)])
        XCTAssertEqual(list.map(\.text), ["old", "one", "three", "streaming"])
        XCTAssertEqual(list[1].id, e1Id)
    }

    func testReplaceTailWithEmptyPageKeepsOnlyFloatingRows() {
        var list = [msg(entryId: "e1", text: "one", ts: 100), msg(text: "streaming", ts: nil)]
        ChatMerger.replaceTail(&list, with: [])
        XCTAssertEqual(list.map(\.text), ["streaming"])
    }
}
