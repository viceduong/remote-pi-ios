import XCTest
@testable import RemotePi

/// Contract §7 (activity), §8 (questionnaires), §9 (Q&A rows).
final class ActivityAndQATests: XCTestCase {

    private func status(busy: Bool, _ activity: AgentActivity?, snapshot: Bool = false) -> AgentStatusState.Event {
        .status(busy: busy, owner: "bridge", v2: true, isSnapshot: snapshot, activity: activity, hasActivity: true)
    }

    // MARK: - Labels

    func testActivityLabels() {
        XCTAssertEqual(AgentActivity(kind: .waiting).label, "Working…")
        XCTAssertEqual(AgentActivity(kind: .thinking).label, "Thinking…")
        XCTAssertEqual(AgentActivity(kind: .writing).label, "Writing…")
        XCTAssertEqual(AgentActivity(kind: .toolcall, tool: "bash").label, "Preparing bash…")
        XCTAssertEqual(AgentActivity(kind: .tool, tool: "bash").label, "Running bash")
        XCTAssertEqual(AgentActivity(kind: .tool, tool: "bash", toolCount: 3).label, "Running bash +2")
        XCTAssertEqual(AgentActivity(kind: .compacting).label, "Compacting context…")
        XCTAssertEqual(AgentActivity(kind: .compacting, percent: 42).label, "Compacting context… 42%")
        XCTAssertEqual(AgentActivity(kind: .retrying, attempt: 2, maxAttempts: 3).label, "Retrying (2/3)…")
        XCTAssertEqual(AgentActivity(kind: .retrying).label, "Retrying…")
        XCTAssertEqual(AgentActivity(kind: .question).label, "Waiting for your answer")
    }

    func testActivityJSONIsTolerant() {
        let tool = AgentActivity(json: ["kind": "tool", "tool": "read", "toolCount": 2, "since": 1_730_000_000_000])
        XCTAssertEqual(tool?.label, "Running read +1")
        XCTAssertEqual(tool?.since, 1_730_000_000_000)
        XCTAssertEqual(AgentActivity(json: ["kind": "something-new"])?.kind, .waiting)
        XCTAssertNil(AgentActivity(json: ["tool": "x"]))
    }

    func testSessionSummaryDecodesActivityLeniently() throws {
        let base = #"{"id":"s1","name":"n","running":true,"busy":true,"messageCount":1,"createdAt":1,"lastActivityAt":2"#
        func decode(_ tail: String) throws -> SessionSummary {
            try JSONDecoder().decode(SessionSummary.self, from: Data((base + tail).utf8))
        }
        XCTAssertEqual(try decode(#","activity":{"kind":"thinking","since":5}}"#).currentActivity?.kind, .thinking)
        XCTAssertNil(try decode(#","activity":"oops"}"#).currentActivity, "malformed activity must not fail the list")
        XCTAssertNil(try decode(#","activity":{"since":5}}"#).currentActivity)
        XCTAssertNil(try decode(#","activity":null}"#).currentActivity)
        XCTAssertNil(try decode("}").currentActivity)
    }

    func testElapsedFormatter() {
        XCTAssertNil(ElapsedFormatter.label(2.9))
        XCTAssertEqual(ElapsedFormatter.label(12), "· 12s")
        XCTAssertEqual(ElapsedFormatter.label(65), "· 1m 05s")
        XCTAssertEqual(ElapsedFormatter.label(3_720), "· 1h 02m")
    }

    // MARK: - Reducer

    func testServerActivityIsAuthoritativeOverHeuristics() {
        var state = AgentStatusState()
        let t0 = Date()
        state.apply(status(busy: true, AgentActivity(kind: .thinking), snapshot: true), now: t0)
        XCTAssertEqual(state.workingText, "Thinking…")
        state.apply(.activity(AgentActivity(kind: .writing)), now: t0.addingTimeInterval(1))
        XCTAssertEqual(state.workingText, "Thinking…", "heuristics never override server activity")
        state.apply(status(busy: true, AgentActivity(kind: .tool, tool: "bash", toolCount: 2)), now: t0.addingTimeInterval(2))
        XCTAssertEqual(state.workingText, "Running bash +1")
        XCTAssertEqual(state.displayActivity?.kind, .tool)
    }

    func testHeuristicFallbackWithoutServerActivity() {
        var state = AgentStatusState()
        state.apply(.status(busy: true, owner: "bridge", v2: true, isSnapshot: true))
        XCTAssertEqual(state.workingText, "Working…")
        state.apply(.activity(AgentActivity(kind: .toolcall, tool: "edit")))
        XCTAssertEqual(state.workingText, "Preparing edit…")
        state.apply(.activity(AgentActivity(kind: .tool, tool: "edit")))
        XCTAssertEqual(state.workingText, "Running edit")
        state.apply(.activity(nil))
        XCTAssertEqual(state.workingText, "Running edit", "unlabelled activity keeps the label")
    }

    func testQuestionOverridesAndIdleClears() {
        var state = AgentStatusState()
        state.apply(status(busy: true, AgentActivity(kind: .thinking)))
        state.apply(.questionCard(true))
        XCTAssertEqual(state.workingText, "Waiting for your answer")
        state.apply(.questionCard(false))
        XCTAssertEqual(state.workingText, "Thinking…")
        state.apply(status(busy: true, AgentActivity(kind: .question)))
        XCTAssertEqual(state.workingText, "Waiting for your answer")
        state.apply(status(busy: false, nil))
        XCTAssertNil(state.workingText)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.activitySince)
    }

    func testLocalCardShowsWaitingForAnswerOnOldServers() {
        var state = AgentStatusState()
        state.apply(.legacyBusy(true))
        state.apply(.activity(AgentActivity(kind: .tool, tool: "ask_user_question")))
        state.apply(.questionCard(true))
        XCTAssertEqual(state.workingText, "Waiting for your answer")
    }

    func testOptimisticSendThenServerActivity() {
        var state = AgentStatusState()
        let t0 = Date()
        state.apply(.optimisticSend, now: t0)
        XCTAssertEqual(state.workingText, "Waiting for response…")
        XCTAssertEqual(state.activitySince, t0)
        state.apply(status(busy: true, AgentActivity(kind: .waiting)), now: t0.addingTimeInterval(1))
        XCTAssertEqual(state.workingText, "Working…")
        XCTAssertEqual(state.activitySince, t0.addingTimeInterval(1))
    }

    func testElapsedClockRestartsOnlyOnKindOrToolChange() {
        var state = AgentStatusState()
        let t0 = Date()
        state.apply(status(busy: true, AgentActivity(kind: .compacting, percent: 10)), now: t0)
        XCTAssertEqual(state.activitySince, t0)
        state.apply(status(busy: true, AgentActivity(kind: .compacting, percent: 50)), now: t0.addingTimeInterval(5))
        XCTAssertEqual(state.activitySince, t0, "percent updates keep the clock")
        state.apply(status(busy: true, AgentActivity(kind: .tool, tool: "bash")), now: t0.addingTimeInterval(6))
        XCTAssertEqual(state.activitySince, t0.addingTimeInterval(6))
        state.apply(status(busy: true, AgentActivity(kind: .tool, tool: "bash", toolCount: 2)), now: t0.addingTimeInterval(7))
        XCTAssertEqual(state.activitySince, t0.addingTimeInterval(6), "tool count keeps the clock")
        state.apply(status(busy: true, AgentActivity(kind: .tool, tool: "read")), now: t0.addingTimeInterval(8))
        XCTAssertEqual(state.activitySince, t0.addingTimeInterval(8))
    }

    func testSnapshotSinceIsUsedOnlyWhenPlausible() {
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        var recent = AgentStatusState()
        recent.apply(status(busy: true, AgentActivity(kind: .thinking, since: nowMs - 30_000), snapshot: true), now: now)
        XCTAssertEqual(recent.activitySince?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 - 30, accuracy: 0.01)

        var future = AgentStatusState()
        future.apply(status(busy: true, AgentActivity(kind: .thinking, since: nowMs + 120_000), snapshot: true), now: now)
        XCTAssertEqual(future.activitySince, now, "server clock ahead → local time")

        var stale = AgentStatusState()
        stale.apply(status(busy: true, AgentActivity(kind: .thinking, since: nowMs - 7_200_000), snapshot: true), now: now)
        XCTAssertEqual(stale.activitySince, now)

        var live = AgentStatusState()
        live.apply(status(busy: true, AgentActivity(kind: .thinking, since: nowMs - 30_000)), now: now)
        XCTAssertEqual(live.activitySince, now, "non-snapshot transitions use the local clock")
    }

    // MARK: - Questionnaire answers (§8)

    func testQuestionAnswersUsePiShape() throws {
        let questions: [[String: Any]] = [
            ["question": "Pick one", "options": [["label": "A", "description": ""], ["label": "B", "description": ""]]],
            ["question": "Pick many", "multiSelect": true,
             "options": [["label": "X", "description": ""], ["label": "Y", "description": ""]]],
            ["question": "Say something", "options": [[String: Any]]()],
        ]
        let question = try XCTUnwrap(AgentQuestion(json: ["requestId": "r1", "questions": questions]))
        XCTAssertFalse(ChatViewModel.isComplete(question, selections: [0: ["A"]], text: [:]))
        XCTAssertFalse(ChatViewModel.isComplete(question, selections: [0: ["A"], 1: ["X"]], text: [2: "   "]))

        let selections: [Int: Set<String>] = [0: ["B"], 1: ["Y", "X"]]
        let text: [Int: String] = [1: "  both  ", 2: "free text"]
        XCTAssertTrue(ChatViewModel.isComplete(question, selections: selections, text: text))
        let answers = ChatViewModel.buildAnswers(question, selections: selections, text: text)
        XCTAssertEqual(answers.map(\.kind), ["option", "multi", "custom"])
        XCTAssertEqual(answers[0].answer, "B")
        XCTAssertNil(answers[0].selected)
        XCTAssertEqual(answers[1].selected ?? [], ["X", "Y"], "selected follows option order")
        XCTAssertEqual(answers[1].answer, "X, Y")
        XCTAssertEqual(answers[1].notes, "both")
        XCTAssertEqual(answers[2].answer, "free text")
        XCTAssertEqual(answers.map(\.questionIndex), [0, 1, 2])

        let chat = ChatViewModel.chatAnswers(question)
        XCTAssertEqual(chat.map(\.kind), ["chat", "chat", "chat"])
        XCTAssertEqual(chat.map(\.answer), Array(repeating: "Chat about this", count: 3))
    }

    // MARK: - Q&A rows (§9)

    func testQARowFromMessagesJSONIsVisible() throws {
        let json = #"{"id":"e9","role":"tool","toolName":"ask_user_question","text":"","timestamp":10,"qa":{"cancelled":false,"items":[{"question":"Color?","answer":"Blue — dark"}]}}"#
        let message = try JSONDecoder().decode(WireMessage.self, from: Data(json.utf8)).toChatMessage()
        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.qa?.items.first?.answer, "Blue — dark")
        XCTAssertTrue(ChatMessage.isVisibleInFocus(message))
        XCTAssertEqual(ChatViewModel.displayable([message]).count, 1)
        let item = ChatViewModel.transcriptItem(for: message, streaming: false)
        XCTAssertEqual(item.kind, .qa)
        XCTAssertEqual(item.text, "Q: Color?\nA: Blue — dark")
        XCTAssertEqual(item.statusText, "Answered")

        // A plain tool row and a malformed `qa` stay hidden (and never fail the page).
        let bad = #"{"id":"e10","role":"tool","toolName":"ask_user_question","text":"x","qa":"nope"}"#
        let hidden = try JSONDecoder().decode(WireMessage.self, from: Data(bad.utf8)).toChatMessage()
        XCTAssertNil(hidden.qa)
        XCTAssertFalse(ChatMessage.isVisibleInFocus(hidden))
        XCTAssertTrue(ChatViewModel.displayable([hidden]).isEmpty)
    }

    func testQARowFromSSEMergesWithServerCopy() throws {
        let raw: [String: Any] = [
            "role": "toolResult", "toolName": "ask_user_question", "timestamp": 1_000,
            "content": [["type": "text", "text": "User declined"]],
        ]
        let event: [String: Any] = ["type": "message_end", "message": raw,
                                    "qa": ["cancelled": true, "items": [[String: Any]]()]]
        let live = try XCTUnwrap(ChatViewModel.qaMessage(event: event, message: raw))
        XCTAssertEqual(live.qa?.cancelled, true)
        XCTAssertEqual(ChatViewModel.transcriptItem(for: live, streaming: false).text, "Question declined")
        XCTAssertNil(ChatViewModel.qaMessage(event: ["type": "message_end"], message: raw),
                     "older servers: no qa → tool row stays hidden")

        var rows = [live]
        let server = ChatMessage(entryId: "e1", role: .tool, text: "", thinking: nil, toolCalls: [],
                                 isError: false, toolName: "ask_user_question", isSystemNote: false,
                                 model: nil, errorMessage: nil, timestamp: 1_000,
                                 qa: QAInfo(cancelled: true, items: []))
        ChatMerger.merge(&rows, [server])
        XCTAssertEqual(rows.count, 1, "live + server copy are one row")
        XCTAssertEqual(rows[0].id, live.id, "row identity is stable")
        XCTAssertEqual(rows[0].entryId, "e1")
    }

    func testQARowSurvivesCacheRoundTrip() throws {
        let message = ChatMessage(entryId: "e1", role: .tool, text: "", thinking: nil, toolCalls: [],
                                  isError: false, toolName: "ask_user_question", isSystemNote: false,
                                  model: nil, errorMessage: nil, timestamp: 5,
                                  qa: QAInfo(cancelled: false, items: [.init(question: "Q", answer: "A")]))
        let data = try JSONEncoder().encode([message])
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        XCTAssertEqual(decoded.first?.qa, message.qa)
        XCTAssertTrue(ChatMessage.isVisibleInFocus(decoded[0]))
    }
}
