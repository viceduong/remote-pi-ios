import XCTest
@testable import RemotePi

/// Contract §13: the pure identity store (replaces the old heuristic
/// `ChatMerger`). No text matching, no timestamp ordering.
final class TranscriptStoreTests: XCTestCase {

    private func msg(key: String? = nil, entryId: String? = nil, role: MessageRole = .assistant,
                     text: String, ts: Int? = nil, cid: String? = nil) -> ChatMessage {
        ChatMessage(entryId: entryId, clientMessageId: cid, role: role, text: text, thinking: nil,
                    toolCalls: [], isError: false, toolName: nil, isSystemNote: false,
                    model: nil, errorMessage: nil, timestamp: ts, key: key)
    }

    // MARK: - Identity

    func testRowIdIsDerivedFromKey() {
        XCTAssertEqual(msg(key: "assistant:5", entryId: "e1", text: "x").id, "k:assistant:5")
        XCTAssertEqual(msg(entryId: "e1", text: "x").id, "entry:e1")
    }

    func testIdentityLessRowsAreNeverStored() {
        var store = TranscriptStore()
        store.upsertLive(msg(text: "orphan"))
        store.finish(msg(text: "orphan"))
        store.merge([msg(text: "orphan")], placement: .newer)
        store.reload([msg(text: "orphan")], keepingLiveAfter: 0)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(TranscriptStore(rows: [msg(text: "cached orphan")]).rows.isEmpty)
    }

    func testSameTextDifferentKeysAreDifferentRows() {
        var store = TranscriptStore()
        store.upsertLive(msg(key: "user:1", role: .user, text: "continue"))
        store.upsertLive(msg(key: "user:2", role: .user, text: "continue"))
        XCTAssertEqual(store.rows.map(\.key), ["user:1", "user:2"])
    }

    func testEntryIdMatchesOnlyWhenOneSideHasNoKey() {
        var store = TranscriptStore(rows: [msg(entryId: "e1", text: "cached v1 row", ts: 1)])
        store.merge([msg(key: "assistant:1", entryId: "e1", text: "cached v1 row", ts: 1)], placement: .newer)
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].key, "assistant:1")
        XCTAssertEqual(store.rows[0].id, "entry:e1", "row id is stable")
        // Different keys never collapse, even with the same entry id.
        store.merge([msg(key: "assistant:9", entryId: "e1", text: "other", ts: 9)], placement: .newer)
        XCTAssertEqual(store.rows.count, 2)
    }

    // MARK: - Live order = arrival order

    func testLiveRowsAppendInArrivalOrderRegardlessOfTimestamp() {
        var store = TranscriptStore()
        store.finish(msg(key: "assistant:1000", text: "working on it", ts: 1000))
        store.finish(msg(key: "assistant:5000", text: "found the cause", ts: 5000))
        store.upsertLive(msg(key: "user:2000", role: .user, text: "also check logs", ts: 2000, cid: "c1"))
        XCTAssertEqual(store.rows.map(\.key), ["assistant:1000", "assistant:5000", "user:2000"])
    }

    // MARK: - Deltas

    func testDeltaOffsets() {
        var store = TranscriptStore()
        store.start(msg(key: "a", text: ""))
        XCTAssertEqual(store.applyDelta(key: "a", offset: 0, delta: "Hello "), .applied)
        XCTAssertEqual(store.applyDelta(key: "a", offset: 0, delta: "Hello "), .duplicate)
        XCTAssertEqual(store.applyDelta(key: "a", offset: 6, delta: "wor"), .applied)
        // Re-coalesced re-send straddling the boundary: only the unseen part.
        XCTAssertEqual(store.applyDelta(key: "a", offset: 6, delta: "world"), .applied)
        XCTAssertEqual(store.rows[0].text, "Hello world")
        XCTAssertEqual(store.stream(for: store.rows[0].id)?.length, 11)
        // Gap: never appended, row incomplete; later deltas ignored too.
        XCTAssertEqual(store.applyDelta(key: "a", offset: 20, delta: "lost"), .gap)
        XCTAssertEqual(store.applyDelta(key: "a", offset: 11, delta: "!"), .gap)
        XCTAssertEqual(store.rows[0].text, "Hello world")
        XCTAssertFalse(store.isSettled(store.rows[0]))
        // message_end heals it.
        store.finish(msg(key: "a", text: "Hello world, all of it"))
        XCTAssertEqual(store.rows[0].text, "Hello world, all of it")
        XCTAssertNil(store.inProgressId)
        XCTAssertTrue(store.isSettled(store.rows[0]))
        // A late replay after the end changes nothing.
        XCTAssertEqual(store.applyDelta(key: "a", offset: 0, delta: "Hello "), .ignored)
        store.start(msg(key: "a", text: ""))
        XCTAssertNil(store.inProgressId, "a replayed message_start never reopens an ended message")
    }

    func testOffsetsAreUTF16() {
        var store = TranscriptStore()
        store.start(msg(key: "a", text: ""))
        // U+1F44B is 2 UTF-16 units, U+00E9 one: the next offset is 3.
        XCTAssertEqual(store.applyDelta(key: "a", offset: 0, delta: "\u{1F44B}\u{E9}"), .applied)
        XCTAssertEqual(store.applyDelta(key: "a", offset: 3, delta: "!"), .applied)
        XCTAssertEqual(store.rows[0].text, "\u{1F44B}\u{E9}!")
        // A re-coalesced re-send straddling the boundary after an emoji.
        XCTAssertEqual(store.applyDelta(key: "a", offset: 2, delta: "\u{E9}!?"), .applied)
        XCTAssertEqual(store.rows[0].text, "\u{1F44B}\u{E9}!?")
    }

    func testKeyedDeltaWithoutStartCreatesTheRowAtArrival() {
        var store = TranscriptStore()
        store.upsertLive(msg(key: "user:1", role: .user, text: "go"))
        store.applyDelta(key: "assistant:2", offset: 0, delta: "On it")
        XCTAssertEqual(store.rows.map(\.key), ["user:1", "assistant:2"])
        XCTAssertEqual(store.inProgressRow?.text, "On it")
    }

    func testLegacyDeltasNeedAStartedMessage() {
        var store = TranscriptStore()
        XCTAssertEqual(store.appendLegacyDelta("-op didn't help."), .ignored)
        XCTAssertTrue(store.rows.isEmpty, "no floating fragment row")
        store.start(msg(key: "assistant:1", text: ""))
        store.appendLegacyDelta("Hi")
        XCTAssertEqual(store.rows[0].text, "Hi")
    }

    func testSnapshotReplacesTextWholesaleAndClearsGap() {
        var store = TranscriptStore()
        store.start(msg(key: "a", text: ""))
        store.applyDelta(key: "a", offset: 0, delta: "Hel")
        store.applyDelta(key: "a", offset: 9, delta: "gap")
        store.snapshot(key: "a", timestamp: 1, text: "Hello world")
        XCTAssertEqual(store.rows[0].text, "Hello world")
        XCTAssertEqual(store.applyDelta(key: "a", offset: 11, delta: "!"), .applied)
        XCTAssertEqual(store.rows[0].text, "Hello world!")
    }

    func testNewStartSupersedesAnUnendedMessage() {
        var store = TranscriptStore()
        store.start(msg(key: "a1", text: ""))
        store.applyDelta(key: "a1", offset: 0, delta: "partial")
        store.start(msg(key: "a2", text: ""))
        XCTAssertEqual(store.inProgressRow?.key, "a2")
        XCTAssertFalse(store.isSettled(store.rows[0]), "the unended row is not cacheable")
    }

    // MARK: - Pages

    func testDeltaPageInsertsAboveTheInProgressMessage() {
        var store = TranscriptStore()
        store.finish(msg(key: "a1", entryId: "e1", text: "one"))
        store.start(msg(key: "a3", text: ""))
        store.applyDelta(key: "a3", offset: 0, delta: "typing")
        store.merge([msg(key: "u2", entryId: "e2", role: .user, text: "missed echo")], placement: .newer)
        XCTAssertEqual(store.rows.map(\.key), ["a1", "u2", "a3"])
    }

    func testSliceFollowsServerOrderAroundAnchors() {
        var store = TranscriptStore(rows: [msg(key: "a", entryId: "a", text: "A"),
                                           msg(key: "z", entryId: "z", text: "Z")])
        store.merge([msg(key: "a", entryId: "a", text: "A"), msg(key: "b", entryId: "b", text: "B"),
                     msg(key: "c", entryId: "c", text: "C"), msg(key: "z", entryId: "z", text: "Z")],
                    placement: .newer)
        XCTAssertEqual(store.rows.map(\.key), ["a", "b", "c", "z"])
        store.merge([msg(key: "o", entryId: "o", text: "old")], placement: .older)
        XCTAssertEqual(store.rows.first?.key, "o")
    }

    func testReloadReplacesOverlapKeepsOlderAndLiveAfterRequest() {
        var store = TranscriptStore(rows: [msg(key: "k0", entryId: "e0", text: "old"),
                                           msg(key: "k1", entryId: "e1", text: "one"),
                                           msg(key: "k2", entryId: "e2", text: "gone from server")])
        store.upsertLive(msg(key: "stale", role: .user, text: "arrived before the request"))
        let originalId = store.rows[1].id
        let mark = store.liveMark
        store.upsertLive(msg(key: "fresh", role: .user, text: "arrived after the request"))
        store.reload([msg(key: "k1", entryId: "e1", text: "one"), msg(key: "k3", entryId: "e3", text: "three")],
                     keepingLiveAfter: mark)
        XCTAssertEqual(store.rows.map(\.key), ["k0", "k1", "k3", "fresh"])
        XCTAssertEqual(store.rows[1].id, originalId)
    }

    func testReloadKeepsTheInProgressMessageAfterThePage() {
        var store = TranscriptStore()
        store.finish(msg(key: "a0", entryId: "e0", text: "earlier"))
        store.start(msg(key: "a1", text: ""))
        store.applyDelta(key: "a1", offset: 0, delta: "streaming")
        store.reload([msg(key: "a0", entryId: "e0", text: "earlier"),
                      msg(key: "u9", entryId: "e9", role: .user, text: "steer")], keepingLiveAfter: store.liveMark)
        XCTAssertEqual(store.rows.map(\.key), ["a0", "u9", "a1"])
        XCTAssertEqual(store.inProgressRow?.text, "streaming")
    }

    func testReloadWithoutOverlapReplacesEverything() {
        var store = TranscriptStore(rows: [msg(key: "old1", entryId: "o1", text: "x"),
                                           msg(key: "old2", entryId: "o2", text: "y")])
        store.reload([msg(key: "n1", entryId: "n1", text: "new")], keepingLiveAfter: store.liveMark)
        XCTAssertEqual(store.rows.map(\.key), ["n1"], "keeping older rows would leave a hole")
    }

    func testPersistedCopyEndsTheInProgressMessage() {
        var store = TranscriptStore()
        store.start(msg(key: "a1", text: ""))
        store.applyDelta(key: "a1", offset: 0, delta: "partial")
        store.merge([msg(key: "a1", entryId: "e1", text: "partial and complete")], placement: .newer)
        XCTAssertNil(store.inProgressId)
        XCTAssertEqual(store.rows.map(\.text), ["partial and complete"])
        XCTAssertEqual(store.applyDelta(key: "a1", offset: 7, delta: " more"), .ignored)
    }

    func testDuplicateIdentitiesInAPageCollapse() {
        var store = TranscriptStore()
        store.merge([msg(key: "k", entryId: "e", text: "a"), msg(key: "k", entryId: "e", text: "a")],
                    placement: .newer)
        XCTAssertEqual(store.rows.count, 1)
    }

    func testEvictionPrunesBookkeeping() {
        var store = TranscriptStore()
        for i in 0..<10 { store.finish(msg(key: "a\(i)", text: "row \(i)")) }
        store.evictOldest(4)
        XCTAssertEqual(store.rows.first?.key, "a4")
        XCTAssertNil(store.stream(for: "k:a0"))
    }
}
