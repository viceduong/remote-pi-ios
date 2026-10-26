import XCTest
import UIKit
@testable import RemotePi

final class TranscriptLogicTests: XCTestCase {

    private func msg(entryId: String? = nil, role: MessageRole, text: String, thinking: String? = nil,
                     isError: Bool = false, system: Bool = false, ts: Int? = nil, cid: String? = nil) -> ChatMessage {
        ChatMessage(entryId: entryId, clientMessageId: cid, role: role, text: text, thinking: thinking,
                    toolCalls: [], isError: isError, toolName: role == .tool ? "bash" : nil,
                    isSystemNote: system, model: nil, errorMessage: nil, timestamp: ts)
    }

    // MARK: - Visibility predicate (contract v2 §4)

    func testVisibilityRules() {
        XCTAssertTrue(ChatMessage.isVisibleInFocus(msg(role: .user, text: "hello")))
        XCTAssertFalse(ChatMessage.isVisibleInFocus(msg(role: .user, text: "  \n ")))
        XCTAssertFalse(ChatMessage.isVisibleInFocus(msg(role: .user, text: "### Tool Call 1", system: true)))
        XCTAssertTrue(ChatMessage.isVisibleInFocus(msg(role: .assistant, text: "answer")))
        XCTAssertFalse(ChatMessage.isVisibleInFocus(msg(role: .assistant, text: "", thinking: "pondering")))
        XCTAssertTrue(ChatMessage.isVisibleInFocus(msg(role: .assistant, text: "", isError: true)))
        XCTAssertFalse(ChatMessage.isVisibleInFocus(msg(role: .tool, text: "output")))
    }

    func testHasVisibleContentMatchesRendererForThinkingOnlyRows() {
        // I5: a thinking-only tail must count as NOT visible (so the
        // ?visible=1 fallback fires) — the renderer would draw nothing.
        let thinkingOnly = [msg(role: .assistant, text: "", thinking: "hmm"),
                            msg(role: .tool, text: "ls")]
        XCTAssertFalse(ChatMessage.hasVisibleContent(thinkingOnly))
        XCTAssertTrue(ChatMessage.hasVisibleContent(thinkingOnly + [msg(role: .user, text: "hi")]))
    }

    func testWireErrorRoleIsVisibleErrorRow() throws {
        let json = #"{"id":"e1","role":"error","text":"","errorMessage":"boom","timestamp":5}"#
        let wire = try JSONDecoder().decode(WireMessage.self, from: Data(json.utf8))
        let message = wire.toChatMessage()
        XCTAssertTrue(message.isError)
        XCTAssertTrue(ChatMessage.isVisibleInFocus(message))
        let item = ChatViewModel.transcriptItem(for: message, streaming: false)
        XCTAssertEqual(item.kind, .error)
        XCTAssertEqual(item.text, "boom")
    }

    func testWireMessageDecodesOptionalClientMessageIdAndToleratesMissingFields() throws {
        let withId = #"{"id":"e1","role":"user","text":"hi","clientMessageId":"c-1","toolCalls":[]}"#
        let old = #"{"id":"e2","role":"user","text":"hi"}"#
        XCTAssertEqual(try JSONDecoder().decode(WireMessage.self, from: Data(withId.utf8)).toChatMessage().clientMessageId, "c-1")
        XCTAssertNil(try JSONDecoder().decode(WireMessage.self, from: Data(old.utf8)).toChatMessage().clientMessageId)
    }

    func testQueueItemDecodingIsTolerant() throws {
        let v2 = #"{"id":"q1","message":"hi","status":"running","clientMessageId":"c1","queuedAt":1730000000000}"#
        let v1NoStatus = #"{"id":"q2","message":"yo"}"#
        let a = try JSONDecoder().decode(QueueItem.self, from: Data(v2.utf8))
        let b = try JSONDecoder().decode(QueueItem.self, from: Data(v1NoStatus.utf8))
        XCTAssertEqual(a.status, "running")
        XCTAssertEqual(a.clientMessageId, "c1")
        XCTAssertEqual(b.status, "queued")
        XCTAssertTrue(b.isActive)
    }

    // MARK: - Blank-line collapse (I16)

    func testCollapseBlankLines() {
        XCTAssertEqual(ChatMessage.collapseBlankLines("\n\na  \n\n\n \t\n b\t\n\n"), "a\n\n b")
        XCTAssertEqual(ChatMessage.collapseBlankLines("x\r\ny\r\n\r\n\r\nz"), "x\ny\n\nz")
        XCTAssertEqual(ChatMessage.collapseBlankLines("   "), "")
        XCTAssertEqual(ChatMessage.collapseBlankLines("    code"), "    code")
    }

    // MARK: - Queue chip reconciliation (I13)

    private func queue(_ id: String, _ text: String, status: String = "queued", cid: String? = nil,
                       at: Int? = nil) -> QueueItem {
        QueueItem(id: id, clientMessageId: cid, message: text, status: status, queuedAt: at)
    }

    func testLocalSendAndServerItemWithSameClientIdAreOneChip() {
        let local = queue("pending:c1", "hello", status: "sending", cid: "c1", at: 1000)
        let server = queue("srv-1", "hello", status: "queued", cid: "c1", at: 1001)
        let result = QueueReconciler.reconcile(localPending: [local], server: [server], piNative: [], messages: [])
        XCTAssertEqual(result.chips.count, 1)
        XCTAssertEqual(result.chips.first?.rowId, "q:c1")
        XCTAssertEqual(result.chips.first?.serverId, "srv-1")
    }

    func testPiNativeQueueDoesNotDuplicateServerItem() {
        let server = queue("srv-1", "fix the\nbuild", cid: "c1")
        let result = QueueReconciler.reconcile(localPending: [], server: [server],
                                               piNative: ["fix the build"], messages: [])
        XCTAssertEqual(result.chips.count, 1)
    }

    func testDeliveredByClientIdDropsChip() {
        let local = queue("srv-9", "deploy", status: "running", cid: "c9", at: 5000)
        let echo = msg(entryId: "e1", role: .user, text: "deploy", ts: 5100, cid: "c9")
        let result = QueueReconciler.reconcile(localPending: [local], server: [], piNative: [], messages: [echo])
        XCTAssertTrue(result.chips.isEmpty)
        XCTAssertEqual(result.deliveredLocal, ["c9"])
    }

    func testMultiLineTextFallbackMatchesWithSameNormalization() {
        // v1 server: echo has no clientMessageId; raw chip text has trailing
        // spaces/blank lines that the transcript row collapsed.
        let local = queue("srv-1", "line one  \n\n\nline two\n", status: "running", cid: "c1", at: 10_000)
        let echo = msg(entryId: "e1", role: .user, text: "line one\n\nline two", ts: 10_500)
        let result = QueueReconciler.reconcile(localPending: [local], server: [], piNative: [], messages: [echo])
        XCTAssertTrue(result.chips.isEmpty)
    }

    func testQueuedItemIsNotHiddenByOldIdenticalPrompt() {
        let oldEcho = msg(entryId: "e1", role: .user, text: "continue", ts: 1_000)
        let server = queue("srv-2", "continue", status: "queued", cid: "c2", at: 900_000)
        let result = QueueReconciler.reconcile(localPending: [], server: [server], piNative: [], messages: [oldEcho])
        XCTAssertEqual(result.chips.count, 1)
    }

    // MARK: - Status reducer (I14 / contract v2 §5)

    func testOptimisticSurvivesSnapshotButNotLiveIdle() {
        var state = AgentStatusState()
        let t0 = Date()
        state.apply(.optimisticSend, now: t0)
        XCTAssertEqual(state.workingText, "Waiting for response…")
        state.apply(.status(busy: false, owner: nil, v2: true, isSnapshot: true), now: t0.addingTimeInterval(1))
        XCTAssertTrue(state.isBusy, "a reconnect snapshot must not erase a fresh send")
        state.apply(.status(busy: true, owner: "bridge", v2: true, isSnapshot: false), now: t0.addingTimeInterval(2))
        XCTAssertEqual(state.workingText, "Working…")
        state.apply(.activity(AgentActivity(kind: .writing)), now: t0.addingTimeInterval(3))
        XCTAssertEqual(state.workingText, "Writing…")
        state.apply(.status(busy: false, owner: "bridge", v2: true, isSnapshot: false), now: t0.addingTimeInterval(4))
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.workingText)
    }

    func testLegacyHintsIgnoredOnceV2StatusSeen() {
        var state = AgentStatusState()
        state.apply(.status(busy: true, owner: "tui", v2: true, isSnapshot: true))
        state.apply(.legacyBusy(false))
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(state.owner, "tui")
    }

    func testLegacyServerDrivesBusyFromLifecycle() {
        var state = AgentStatusState()
        state.apply(.legacyBusy(true))
        XCTAssertTrue(state.isBusy)
        state.apply(.crashed)
        XCTAssertEqual(state.workingText, "Agent crashed — restarting…")
        state.apply(.status(busy: false, owner: nil, v2: false, isSnapshot: false))
        XCTAssertNil(state.workingText)
    }

    // MARK: - Cache file names (I4)

    func testCacheFileNameIsStableSHA256() {
        XCTAssertEqual(SessionHistoryCache.fileName(for: "abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.json")
        XCTAssertEqual(SessionHistoryCache.fileName(for: "session-1"),
                       SessionHistoryCache.fileName(for: "session-1"))
        XCTAssertNotEqual(SessionHistoryCache.fileName(for: "a"), SessionHistoryCache.fileName(for: "b"))
    }

    func testCacheSignatureChangesWithContent() {
        let a = [msg(entryId: "e1", role: .user, text: "hi", ts: 1)]
        var b = a
        b[0].text = "hi there"
        XCTAssertEqual(SessionHistoryCache.signature(messages: a, hasMore: false, cursor: "e1"),
                       SessionHistoryCache.signature(messages: a, hasMore: false, cursor: "e1"))
        XCTAssertNotEqual(SessionHistoryCache.signature(messages: a, hasMore: false, cursor: "e1"),
                          SessionHistoryCache.signature(messages: b, hasMore: false, cursor: "e1"))
    }

    // MARK: - SSE frames (contract v2 §1)

    func testOpaqueEventIdsAndResetFrame() throws {
        var parser = SSEParser()
        XCTAssertNil(try parser.consume("event: reset"))
        XCTAssertNil(try parser.consume("id: lq2x9k.3-17"))
        XCTAssertNil(try parser.consume(#"data: {"type":"reset","reason":"epoch"}"#))
        let raw = try XCTUnwrap(try parser.consume(""))
        XCTAssertEqual(parser.cursor, "lq2x9k.3-17")
        let frame = ParsedSSEFrame(raw)
        XCTAssertTrue(frame.isReset)
        XCTAssertEqual(frame.id, "lq2x9k.3-17")
        XCTAssertEqual(frame.payload?["reason"] as? String, "epoch")
    }

    func testUnnamedFrameUsesPayloadTypeAndBadJSONIsTolerated() {
        let typed = ParsedSSEFrame(SSEFrame(event: "message", data: #"{"type":"reset"}"#, id: nil))
        XCTAssertTrue(typed.isReset)
        let status = ParsedSSEFrame(SSEFrame(event: "agent_status", data: #"{"type":"agent_status","busy":true}"#, id: "e-1"))
        XCTAssertEqual(status.type, "agent_status")
        XCTAssertEqual(status.payload?["busy"] as? Bool, true)
        let garbage = ParsedSSEFrame(SSEFrame(event: "message_update", data: "{not json", id: "e-2"))
        XCTAssertNil(garbage.payload)
        XCTAssertFalse(garbage.isReset)
    }

    // MARK: - Markdown rendering (off-main safe, pure)

    func testMarkdownRendersInlineAndBlocks() {
        let palette = MarkdownRenderer.Palette(text: .white, accent: .blue, codeBackground: .darkGray)
        let out = MarkdownRenderer.render("# Title\n- **bold** item\n```\nlet x = 1\n```\nsee [docs](https://example.com)",
                                          font: .systemFont(ofSize: 17), palette: palette)
        XCTAssertEqual(out.string, "Title\n• bold item\nlet x = 1\nsee docs")
        let links = MarkdownRenderer.links(in: out, text: "see [docs](https://example.com)")
        XCTAssertEqual(links.first?.host, "example.com")
    }
}
