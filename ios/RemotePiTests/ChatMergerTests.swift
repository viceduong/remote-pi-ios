import XCTest
@testable import RemotePi

final class ChatMergerTests: XCTestCase {

    private func msg(entryId: String? = nil, role: MessageRole = .assistant,
                     text: String, ts: Int) -> ChatMessage {
        ChatMessage(entryId: entryId, role: role, text: text, thinking: nil,
                    toolCalls: [], toolActivity: nil, isError: false,
                    toolName: nil, isSystemNote: false, model: nil,
                    errorMessage: nil, timestamp: ts)
    }

    func testAppendsNewMessages() {
        var list = [msg(entryId: "m1", text: "hello", ts: 100)]
        ChatMerger.append(&list, [msg(entryId: "m2", text: "world", ts: 200)])
        XCTAssertEqual(list.count, 2)
    }

    func testDedupesByEntryId() {
        var list = [msg(entryId: "m1", text: "hello", ts: 100)]
        ChatMerger.append(&list, [msg(entryId: "m1", text: "hello", ts: 101)])
        XCTAssertEqual(list.count, 1)
    }

    func testDedupesOptimisticVsServerCopy() {
        // Optimistic local copy has no entry id but same text+timestamp.
        var list = [msg(role: .user, text: "hi there", ts: 1000)]
        ChatMerger.append(&list, [msg(entryId: "m9", role: .user, text: "hi there", ts: 1001)])
        XCTAssertEqual(list.count, 1)
    }

    func testReplacePartialStreamWithFullCopy() {
        // SSE bubble is mid-stream (short text); file_update carries the full
        // version — replace, don't append.
        var list = [msg(entryId: "a1", text: "The quick brown fox", ts: 100)]
        ChatMerger.append(&list, [msg(entryId: "a1", text: "The quick brown fox jumps over the lazy dog", ts: 100)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "The quick brown fox jumps over the lazy dog")
    }

    func testContinuationWithoutEntryIdReplaces() {
        var list = [msg(role: .assistant, text: "First part of a long", ts: 50)]
        ChatMerger.append(&list, [msg(role: .assistant, text: "First part of a long response continues here", ts: 52)])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].text, "First part of a long response continues here")
    }

    func testDistinctMessagesAppendEvenWithSharedPrefix() {
        var list = [msg(entryId: "x1", role: .user, text: "what is the weather", ts: 10)]
        ChatMerger.append(&list, [msg(entryId: "x2", role: .user, text: "what is the weather tomorrow", ts: 5000)])
        XCTAssertEqual(list.count, 2)
    }

    func testSameRoleDifferentContentAppends() {
        var list = [msg(role: .assistant, text: "first answer", ts: 1)]
        ChatMerger.append(&list, [msg(role: .assistant, text: "second answer", ts: 2)])
        XCTAssertEqual(list.count, 2)
    }
}
