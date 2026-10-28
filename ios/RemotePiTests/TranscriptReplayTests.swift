import XCTest
@testable import RemotePi

/// Deterministic replay harness (contract v2 §13): recorded server event
/// sequences in the §13 WIRE format are fed through the REAL view-model frame
/// handler (`ChatViewModel.ingestForTesting`), with injected faults. The
/// final transcript (visible rows: key, role, text, order) must EXACTLY equal
/// the projection of the server history — the same rows `GET /messages`
/// returns, through the same visibility rule.
@MainActor
final class TranscriptReplayTests: XCTestCase {

    // MARK: - Recorded conversation

    /// One server message: identity, content, and its persisted entry id.
    struct Msg {
        enum Role { case user, assistant, qa }
        let key: String
        let role: Role
        let text: String
        let ts: Int
        let entryId: String
        var cid: String? = nil
        var toolCallId: String? = nil
        var qa: [String: Any]? = nil
        var thinking: String? = nil
    }

    /// Server (= file) order. U2 is a STEERED message: pi stamped it at
    /// queue time (1003), i.e. OLDER than A2 (1005) that precedes it.
    static let u1 = Msg(key: "user:1000", role: .user, text: "Fix the sign-out bug", ts: 1000, entryId: "e1", cid: "c1")
    static let a1 = Msg(key: "assistant:1001", role: .assistant, text: "Looking at `logout()` now.", ts: 1001,
                        entryId: "e2", thinking: "where is logout called?")
    static let q1 = Msg(key: "tool:call-q1", role: .qa, text: "User has answered your questions: \"Proceed?\"=\"Yes\".",
                        ts: 1002, entryId: "e3", toolCallId: "call-q1",
                        qa: ["cancelled": false, "items": [["question": "Proceed?", "answer": "Yes"]]])
    static let a2 = Msg(key: "assistant:1005", role: .assistant,
                        text: "Still signing out! The `logout()` no-op didn't help. Let me find the real sign-out trigger:",
                        ts: 1005, entryId: "e4")
    static let u2 = Msg(key: "user:1003", role: .user, text: "also check the token refresh", ts: 1003, entryId: "e5", cid: "c2")
    static let a3 = Msg(key: "assistant:1010", role: .assistant,
                        text: "Found it: the refresh handler clears the session.\n\n\nFixing now \u{1F44D}", ts: 1010,
                        entryId: "e6")

    static let conversation = [u1, a1, q1, a2, u2, a3]

    // MARK: - §13 wire format

    private var seq = 0

    /// Round-trip through JSONSerialization exactly like the EventSource
    /// reader does (NSNumber / NSNull / nested dictionaries).
    private func frame(_ json: [String: Any]) -> ParsedSSEFrame {
        seq += 1
        let data = try! JSONSerialization.data(withJSONObject: json)
        let payload = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ParsedSSEFrame(event: json["type"] as? String ?? "message", id: "ep.1-\(seq)", payload: payload)
    }

    private func piMessage(_ m: Msg) -> [String: Any] {
        switch m.role {
        case .user:
            return ["role": "user", "content": [["type": "text", "text": m.text]], "timestamp": m.ts]
        case .assistant:
            var content: [[String: Any]] = []
            if let thinking = m.thinking { content.append(["type": "thinking", "thinking": thinking]) }
            content.append(["type": "text", "text": m.text])
            return ["role": "assistant", "content": content, "timestamp": m.ts,
                    "provider": "anthropic", "model": "claude"]
        case .qa:
            return ["role": "toolResult", "toolCallId": m.toolCallId ?? "", "toolName": "ask_user_question",
                    "content": [["type": "text", "text": m.text]], "timestamp": m.ts]
        }
    }

    private func start(_ m: Msg) -> [String: Any] {
        var event: [String: Any] = ["type": "message_start", "key": m.key]
        switch m.role {
        case .assistant:
            event["message"] = ["role": "assistant", "content": [[String: Any]](), "timestamp": m.ts] as [String: Any]
        case .user:
            event["message"] = piMessage(m)
            if let cid = m.cid { event["clientMessageId"] = cid }
        case .qa:
            event["message"] = piMessage(m)
            event["qa"] = m.qa
        }
        return event
    }

    private func end(_ m: Msg) -> [String: Any] {
        var event: [String: Any] = ["type": "message_end", "key": m.key, "message": piMessage(m)]
        switch m.role {
        case .assistant:
            event["text"] = m.text
        case .user:
            event["text"] = m.text
            if let cid = m.cid { event["clientMessageId"] = cid }
        case .qa:
            event["qa"] = m.qa
        }
        return event
    }

    /// The streamed chunks of an assistant message (grapheme-safe).
    private func chunks(_ m: Msg, size: Int = 9) -> [String] {
        let chars = Array(m.text)
        return stride(from: 0, to: chars.count, by: size).map {
            String(chars[$0..<min($0 + size, chars.count)])
        }
    }

    /// `text_delta` wire events with §13 offsets (UTF-16 length before each).
    private func deltas(_ m: Msg, size: Int = 9) -> [[String: Any]] {
        var offset = 0
        return chunks(m, size: size).map { chunk in
            defer { offset += chunk.utf16.count }
            return delta(key: m.key, offset: offset, chunk)
        }
    }

    /// Exactly the server's coalesced delta: `offset` top-level AND inside
    /// `assistantMessageEvent`; `key: null` deltas carry no offset.
    private func delta(key: String?, offset: Int?, _ text: String) -> [String: Any] {
        var inner: [String: Any] = ["type": "text_delta", "contentIndex": 1, "delta": text]
        var event: [String: Any] = ["type": "message_update"]
        if let key { event["key"] = key } else { event["key"] = NSNull() }
        if let offset {
            inner["offset"] = offset
            event["offset"] = offset
        }
        event["assistantMessageEvent"] = inner
        return event
    }

    private func snapshot(_ m: Msg, upTo text: String) -> [String: Any] {
        ["type": "message_snapshot", "key": m.key, "role": "assistant", "timestamp": m.ts,
         "text": text, "streaming": true]
    }

    private func status(busy: Bool) -> [String: Any] {
        ["type": "agent_status", "phase": busy ? "streaming" : "idle", "busy": busy, "owner": "bridge",
         "activity": busy ? (["kind": "writing", "since": 1] as [String: Any]) as Any : NSNull() as Any,
         "questionId": NSNull()]
    }

    private let reset: [String: Any] = ["type": "reset", "reason": "gap"]

    /// The whole message, live, without faults.
    private func live(_ m: Msg) -> [[String: Any]] {
        switch m.role {
        case .assistant: return [start(m)] + deltas(m) + [end(m)]
        case .user, .qa: return [start(m), end(m)]
        }
    }

    /// `GET /messages` rows (server history mapping, §13 keys, §3 cids, §9 qa).
    private func historyRow(_ m: Msg) -> ChatMessage {
        var row: [String: Any] = ["id": m.entryId, "key": m.key, "text": m.text, "timestamp": m.ts,
                                  "isError": false]
        switch m.role {
        case .user:
            row["role"] = "user"
            if let cid = m.cid { row["clientMessageId"] = cid }
        case .assistant:
            row["role"] = "assistant"
            row["model"] = "anthropic/claude"
            if let thinking = m.thinking { row["thinking"] = thinking }
        case .qa:
            row["role"] = "tool"
            row["toolName"] = "ask_user_question"
            row["qa"] = m.qa
        }
        let data = try! JSONSerialization.data(withJSONObject: row)
        return try! JSONDecoder().decode(WireMessage.self, from: data).toChatMessage()
    }

    private func history(_ messages: [Msg] = TranscriptReplayTests.conversation) -> [ChatMessage] {
        messages.map { historyRow($0) }
    }

    // MARK: - Projection + assertions

    struct Row: Equatable, CustomStringConvertible {
        let key: String?
        let role: String
        let text: String
        var description: String { "\(key ?? "nil") [\(role)] \(text.debugDescription)" }
    }

    private static func row(_ m: ChatMessage) -> Row {
        let item = ChatViewModel.transcriptItem(for: m, streaming: false)
        return Row(key: m.key, role: item.kind.rawValue, text: item.text)
    }

    /// The server-history projection: what a fresh client shows.
    private func projection(_ messages: [Msg] = TranscriptReplayTests.conversation) -> [Row] {
        ChatViewModel.prepareHistory(history(messages)).filter(ChatMessage.isVisibleInFocus).map(Self.row)
    }

    private func visible(_ vm: ChatViewModel) -> [Row] {
        vm.commitNow()
        return vm.visibleMessages.map(Self.row)
    }

    private func assertMatchesHistory(_ vm: ChatViewModel, _ messages: [Msg] = TranscriptReplayTests.conversation,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let got = visible(vm)
        let want = projection(messages)
        let gotText = got.map { $0.description }.joined(separator: "\n")
        let wantText = want.map { $0.description }.joined(separator: "\n")
        XCTAssertEqual(got, want, "\nGOT:\n" + gotText + "\nWANT:\n" + wantText, file: file, line: line)
        // No chip/offline/question leftovers either: the transcript is the rows.
        let rowKinds: [TranscriptItem.Kind] = [.user, .assistant, .error, .qa]
        let rendered = vm.transcript.value.filter { rowKinds.contains($0.kind) }
        XCTAssertEqual(rendered.map(\.text), want.map(\.text), file: file, line: line)
        XCTAssertNil(vm.store.inProgressId, "nothing may stay streaming", file: file, line: line)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t"),
                      sessionId: "replay-\(UUID().uuidString)")
    }

    private var vms: [ChatViewModel] = []

    private func feed(_ vm: ChatViewModel, _ events: [[String: Any]]) {
        vm.ingestForTesting(events.map { self.frame($0) })
    }

    private func newVM() -> ChatViewModel {
        let vm = makeViewModel()
        vms.append(vm)
        return vm
    }

    override func tearDown() async throws {
        for vm in vms { vm.stop() }
        vms.removeAll()
    }

    // MARK: - Baseline

    func testCleanLiveStreamEqualsHistory() {
        let vm = newVM()
        feed(vm, [status(busy: true)] + Self.conversation.flatMap { self.live($0) } + [status(busy: false)])
        assertMatchesHistory(vm)
        // A reload with the real history changes nothing — not even row ids
        // (no cell churn).
        let ids = vm.visibleMessages.map(\.id)
        vm.reloadForTesting(history(), mark: vm.liveMarkForTesting)
        assertMatchesHistory(vm)
        vm.commitNow()
        XCTAssertEqual(vm.visibleMessages.map(\.id), ids)
    }

    // MARK: - (a) missing message_start

    func testMissingMessageStartKeyedDeltasStillBuildTheRow() {
        let vm = newVM()
        var events = Self.conversation.flatMap { self.live($0) }
        events.removeAll { ($0["type"] as? String) == "message_start" && ($0["key"] as? String) == Self.a2.key }
        feed(vm, events)
        assertMatchesHistory(vm)
    }

    /// The server itself attached mid-message: deltas carry `key: null`.
    /// They must not create a row (the old "-op didn't help…" fragment); the
    /// keyed message_end brings the text.
    func testServerSideKeylessDeltasNeverCreateRows() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) })
        let before = visible(vm)
        let a2 = deltas(Self.a2)
        feed(vm, a2.dropFirst(3).map { var e = $0; e["key"] = NSNull(); e["offset"] = nil; return e })
        XCTAssertEqual(visible(vm), before, "no fragment row from key-less deltas")
        feed(vm, [end(Self.a2)] + [Self.u2, Self.a3].flatMap { self.live($0) })
        assertMatchesHistory(vm)
        // And the fragment never reappears under later replies / reloads.
        vm.reloadForTesting(history(), mark: vm.liveMarkForTesting)
        assertMatchesHistory(vm)
    }

    // MARK: - (b) missing middle deltas, then message_end

    func testMissingMiddleDeltasNeverAppendAcrossTheGap() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) })
        let all = deltas(Self.a2)
        feed(vm, [start(Self.a2), all[0], all[1]] + Array(all[3...]))
        let streaming = vm.store.rows.first { $0.key == Self.a2.key }
        let parts = chunks(Self.a2)
        XCTAssertEqual(streaming?.text, parts[0] + parts[1], "nothing after the gap is appended")
        XCTAssertEqual(streaming.flatMap { vm.store.stream(for: $0.id) }?.incomplete, true)
        XCTAssertFalse(vm.cacheableRowsForTesting.contains { $0.key == Self.a2.key }, "incomplete rows are never cached")
        feed(vm, [end(Self.a2)] + [Self.u2, Self.a3].flatMap { self.live($0) })
        assertMatchesHistory(vm)
    }

    // MARK: - (c) reconnect mid-message with snapshot

    func testReconnectMidMessageWithSnapshot() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) })
        let all = deltas(Self.a2)
        let parts = chunks(Self.a2)
        // Connection drops after two deltas; deltas 2…4 are lost with it.
        feed(vm, [start(Self.a2), all[0], all[1]])
        // Reconnect: status snapshot, then the in-progress snapshot (§13),
        // then the replay overlaps (delta 1 again) and continues.
        feed(vm, [status(busy: true), snapshot(Self.a2, upTo: parts[0..<5].joined()), all[1]]
             + Array(all[5...]) + [end(Self.a2)])
        feed(vm, [Self.u2, Self.a3].flatMap { self.live($0) } + [status(busy: false)])
        assertMatchesHistory(vm)
    }

    /// The server sends the snapshot while the message is still thinking
    /// (`text: ""`): the row exists (identity, position) but is invisible
    /// until text streams, and its deltas start at offset 0.
    func testThinkingOnlySnapshotKeepsAnInvisibleRow() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) })
        feed(vm, [status(busy: true), snapshot(Self.a2, upTo: "")])
        XCTAssertEqual(vm.store.inProgressRow?.key, Self.a2.key)
        XCTAssertEqual(visible(vm).map(\.key), [Self.u1.key, Self.a1.key, Self.q1.key])
        feed(vm, deltas(Self.a2) + [end(Self.a2)] + [Self.u2, Self.a3].flatMap { self.live($0) })
        assertMatchesHistory(vm)
    }

    // MARK: - (d) reset + reload while streaming

    func testResetAndReloadWhileStreaming() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) })
        let all = deltas(Self.a2)
        let parts = chunks(Self.a2)
        feed(vm, [start(Self.a2), all[0]])
        // Ring overflow: `reset`; the reload request starts now…
        feed(vm, [reset])
        let mark = vm.liveMarkForTesting
        // …the server re-announces the in-progress message, streaming goes on…
        feed(vm, [status(busy: true), snapshot(Self.a2, upTo: parts[0..<3].joined())] + Array(all[3..<6]))
        // …and the page (A2 not persisted yet) lands mid-stream.
        vm.reloadForTesting(history([Self.u1, Self.a1, Self.q1]), mark: mark)
        XCTAssertEqual(visible(vm).map(\.key), [Self.u1.key, Self.a1.key, Self.q1.key, Self.a2.key],
                       "the in-progress row survives the reload, after the page")
        XCTAssertEqual(vm.store.inProgressRow?.text, parts[0..<6].joined())
        feed(vm, Array(all[6...]) + [end(Self.a2)] + [Self.u2, Self.a3].flatMap { self.live($0) })
        assertMatchesHistory(vm)
    }

    /// A stale live row that arrived BEFORE the reset reload started and that
    /// the server does not have is dropped by the reload.
    func testResetReloadDropsRowsTheServerDoesNotHave() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1].flatMap { self.live($0) })
        // A message that started but was never persisted (aborted, lost end).
        let ghost = Msg(key: "assistant:999999", role: .assistant, text: "half a sent", ts: 999_999, entryId: "-")
        feed(vm, [start(ghost)] + deltas(ghost).prefix(1))
        feed(vm, [reset])
        let mark = vm.liveMarkForTesting
        vm.reloadForTesting(history([Self.u1, Self.a1]), mark: mark)
        feed(vm, [Self.q1, Self.a2, Self.u2, Self.a3].flatMap { self.live($0) })
        assertMatchesHistory(vm)
    }

    // MARK: - (e) steered user message with an older timestamp

    func testSteeredUserMessageKeepsServerOrder() {
        let vm = newVM()
        feed(vm, Self.conversation.flatMap { self.live($0) })
        let keys = visible(vm).map(\.key)
        XCTAssertEqual(keys, [Self.u1.key, Self.a1.key, Self.q1.key, Self.a2.key, Self.u2.key, Self.a3.key],
                       "U2 (stamped 1003) stays BELOW A2 (1005): arrival = server order")
        assertMatchesHistory(vm)
        // Cursor refresh + full reload: order unchanged.
        vm.mergeDeltaForTesting(history([Self.a2, Self.u2, Self.a3]))
        assertMatchesHistory(vm)
        vm.reloadForTesting(history(), mark: vm.liveMarkForTesting)
        assertMatchesHistory(vm)
    }

    // MARK: - (f) duplicated / replayed deltas

    func testDuplicatedAndReplayedDeltasAreIdempotent() {
        let vm = newVM()
        var events: [[String: Any]] = []
        for m in Self.conversation {
            switch m.role {
            case .assistant:
                let d = deltas(m)
                events.append(start(m))
                for e in d { events.append(e); events.append(e) }     // every delta twice
                events.append(contentsOf: d.prefix(3))                 // a replayed run
                // A re-coalesced re-send straddling the applied boundary.
                if d.count > 2 {
                    let merged = chunks(m)[1] + chunks(m)[2]
                    events.append(delta(key: m.key, offset: chunks(m)[0].utf16.count, merged))
                }
                events.append(end(m))
                // Late cursor replay of the whole message after its end.
                events.append(contentsOf: [start(m)] + d + [end(m)])
            case .user, .qa:
                events.append(contentsOf: live(m) + live(m))
            }
        }
        feed(vm, events)
        assertMatchesHistory(vm)
    }

    // MARK: - (g) stream dies before message_end, then a history refresh

    func testStreamDiesBeforeEndThenHistoryRefresh() {
        let vm = newVM()
        feed(vm, [status(busy: true)] + [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) })
        feed(vm, [start(Self.a2)] + deltas(Self.a2).prefix(4))
        XCTAssertFalse(vm.cacheableRowsForTesting.contains { $0.key == Self.a2.key },
                       "the streaming row is never cached")
        // The connection dies; the end, U2 and A3 happen while we are away.
        // Reconnect: the agent is idle now (status snapshot), no snapshot.
        feed(vm, [status(busy: false)])
        XCTAssertNil(vm.store.inProgressId)
        // The healing cursor refresh (`?since=`) returns the persisted rows.
        vm.mergeDeltaForTesting(history([Self.a2, Self.u2, Self.a3]))
        assertMatchesHistory(vm)
        XCTAssertEqual(vm.cacheableRowsForTesting.compactMap(\.key), Self.conversation.map(\.key))
    }

    func testStreamDiesBeforeEndThenFullReload() {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) } + [start(Self.a2)] + deltas(Self.a2).prefix(4))
        feed(vm, [["type": "agent_end"]])
        let mark = vm.liveMarkForTesting
        vm.reloadForTesting(history(), mark: mark)
        assertMatchesHistory(vm)
    }

    // MARK: - (h) queue chip disappears exactly when the cid user row appears

    private func queueUpdate(status: String?) -> [String: Any] {
        guard let status else { return ["type": "queue_update", "items": [[String: Any]]()] }
        return ["type": "queue_update",
                "items": [["id": "srv-2", "clientMessageId": Self.u2.cid!, "message": Self.u2.text,
                           "status": status, "queuedAt": 1_003] as [String: Any]]]
    }

    private func chips(_ vm: ChatViewModel) -> [TranscriptItem] {
        vm.commitNow()
        return vm.transcript.value.filter { $0.kind == .queued }
    }

    func testQueueChipDisappearsExactlyWhenTheUserRowAppears() throws {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1, Self.q1].flatMap { self.live($0) } + [start(Self.a2)] + deltas(Self.a2).prefix(2))
        feed(vm, [queueUpdate(status: "queued")])
        let queued = try XCTUnwrap(chips(vm).first)
        XCTAssertTrue(queued.canSteer)
        // Send now (§10): optimistic "sending", same row.
        vm.steerQueued("srv-2")
        XCTAssertEqual(chips(vm).map(\.statusText), ["sending"])
        XCTAssertEqual(chips(vm).map(\.id), [queued.id])
        feed(vm, [queueUpdate(status: "running")] + Array(deltas(Self.a2).dropFirst(2)) + [end(Self.a2)])
        XCTAssertEqual(chips(vm).count, 1, "still pending: its user row has not appeared yet")
        // A user row with the SAME TEXT but another identity (no cid) does
        // not consume the chip on a keyed server (no text matching).
        let lookalike = Msg(key: "user:1004", role: .user, text: Self.u2.text, ts: 1004, entryId: "x")
        feed(vm, [start(lookalike)])
        XCTAssertEqual(chips(vm).count, 1)
        // The echo with the chip's clientMessageId: the chip goes in the SAME
        // commit the row appears in — no stuck "sending", no duplicate.
        feed(vm, [start(Self.u2)])
        vm.commitNow()
        let items = vm.transcript.value
        XCTAssertTrue(items.filter { $0.kind == .queued }.isEmpty)
        XCTAssertEqual(items.filter { $0.kind == .user && $0.text == Self.u2.text }.count, 2)
        // The lagging queue_update (still `running`) cannot resurrect it.
        feed(vm, [queueUpdate(status: "running"), end(Self.u2)])
        XCTAssertTrue(chips(vm).isEmpty)
        feed(vm, [queueUpdate(status: nil)])
        XCTAssertTrue(chips(vm).isEmpty)
    }

    // MARK: - §8 question card + §9 Q&A row

    func testQuestionCardThenQARow() throws {
        let vm = newVM()
        feed(vm, [Self.u1, Self.a1].flatMap { self.live($0) })
        let question: [String: Any] = [
            "type": "agent_question", "requestId": "rq-1",
            "questions": [["index": 0, "question": "Proceed?", "multiSelect": false,
                           "options": [["label": "Yes", "description": ""]]] as [String: Any]],
        ]
        feed(vm, [question])
        vm.commitNow()
        XCTAssertEqual(vm.transcript.value.last?.kind, .question)
        let resolved: [String: Any] = ["type": "agent_question_resolved", "requestId": "rq-1"]
        feed(vm, [resolved] + live(Self.q1))
        vm.commitNow()
        XCTAssertEqual(vm.transcript.value.last?.kind, .qa)
        XCTAssertEqual(vm.transcript.value.last?.text, "Q: Proceed?\nA: Yes")
        feed(vm, [Self.a2, Self.u2, Self.a3].flatMap { self.live($0) })
        assertMatchesHistory(vm)
    }

    // MARK: - Cache

    func testOrphanBubblesFromOlderCachesAreDiscarded() {
        let vm = newVM()
        let orphan = ChatMessage(role: .assistant, text: "-op didn't help. Let me find the real sign-out trigger:",
                                 thinking: nil, toolCalls: [], isError: false, toolName: nil, isSystemNote: false,
                                 model: nil, errorMessage: nil, timestamp: nil)
        // An old-build cache: entry-id rows (no keys) + an orphan bubble.
        let old = history([Self.u1, Self.a1]).map { m -> ChatMessage in var r = m; r.key = nil; return r }
        vm.loadCacheForTesting(old + [orphan])
        vm.commitNow()
        XCTAssertEqual(vm.visibleMessages.count, 2, "the orphan is gone")
        // Opening: reload with the newest page; old rows heal by entry id.
        vm.reloadForTesting(history(), mark: vm.liveMarkForTesting)
        assertMatchesHistory(vm)
    }

    // MARK: - Legacy (pre-§13) server: no keys anywhere

    private func legacy(_ event: [String: Any]) -> [String: Any] {
        var e = event
        e["key"] = nil
        e["offset"] = nil
        e["text"] = nil
        return e
    }

    func testLegacyServerDerivesIdentityFromTimestamps() {
        let vm = newVM()
        var events = Self.conversation.flatMap { self.live($0) }.map { self.legacy($0) }
        // A message whose start was lost: its deltas only update status.
        events.removeAll { ($0["type"] as? String) == "message_start"
            && (($0["message"] as? [String: Any])?["timestamp"] as? Int) == Self.a3.ts }
        feed(vm, events)
        XCTAssertFalse(vm.serverKeyed)
        // History without keys: rows match by the derived identity.
        let page = history().map { m -> ChatMessage in var r = m; r.key = nil; return r }
        vm.mergeDeltaForTesting(page)
        vm.reloadForTesting(page, mark: vm.liveMarkForTesting)
        vm.commitNow()
        XCTAssertEqual(vm.visibleMessages.map(\.text), projection().map(\.text))
        XCTAssertEqual(vm.visibleMessages.map(\.entryId), Self.conversation.map(\.entryId))
        // Only persisted rows are cached for key-less servers.
        XCTAssertTrue(vm.cacheableRowsForTesting.allSatisfy { $0.entryId != nil })
    }
}
