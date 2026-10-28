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

    /// The EXACT frame captured live off the wire, through the same
    /// JSONSerialization → [String: Any] → `AgentActivity(json:)` → reducer
    /// path `handleAgentStatus` uses. Guards the device regression where the
    /// banner showed only "Working…" and the timer counted only from open.
    func testLiveToolFrameParsesAndLabelsRunningBash() throws {
        let raw = #"{"type":"agent_status","phase":"streaming","busy":true,"working":true,"owner":"tui","activity":{"kind":"tool","since":1793014975650,"tool":"bash","toolCount":1},"questionId":null}"#
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let activityDict = try XCTUnwrap(obj["activity"] as? [String: Any])
        let parsed = try XCTUnwrap(AgentActivity(json: activityDict), "activity must not fail to parse")
        XCTAssertEqual(parsed.kind, .tool)
        XCTAssertEqual(parsed.tool, "bash")
        XCTAssertEqual(parsed.toolCount, 1)
        // Was truncated by NSNumber.intValue (Int32): 1793014975650 → garbage.
        XCTAssertEqual(parsed.since, 1_793_014_975_650, "ms epoch must survive 64-bit")
        XCTAssertEqual(parsed.label, "Running bash")

        var state = AgentStatusState()
        state.apply(.status(busy: true, owner: "tui", v2: true, isSnapshot: true,
                            activity: parsed, hasActivity: true))
        XCTAssertEqual(state.displayActivity?.kind, .tool)
        XCTAssertEqual(state.workingText, "Running bash")
    }

    func testReducerLabelsForEachKindFromParsedFrames() {
        func apply(_ json: [String: Any]) -> AgentStatusState {
            var state = AgentStatusState()
            state.apply(.status(busy: true, owner: "tui", v2: true, isSnapshot: true,
                                activity: AgentActivity(json: json), hasActivity: true))
            return state
        }
        XCTAssertEqual(apply(["kind": "thinking", "since": 1_793_014_975_650]).workingText, "Thinking…")
        XCTAssertEqual(apply(["kind": "writing"]).workingText, "Writing…")
        XCTAssertEqual(apply(["kind": "compacting", "percent": 42, "reason": "threshold"]).workingText,
                       "Compacting context… 42%")
        XCTAssertEqual(apply(["kind": "retrying", "attempt": 2, "maxAttempts": 3, "delayMs": 1500]).workingText,
                       "Retrying (2/3)…")
        XCTAssertEqual(apply(["kind": "toolcall", "tool": "edit"]).workingText, "Preparing edit…")
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

    func testBusySinceDrivesStableTimerAcrossSubActivities() {
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let busyStart = nowMs - 45_000               // working for 45s
        func frame(_ kind: AgentActivity.Kind, tool: String?, sub: Int) -> AgentStatusState.Event {
            // `since` (sub-activity start) moves; `busySince` is stable.
            .status(busy: true, owner: "tui", v2: true, isSnapshot: false,
                    activity: AgentActivity(kind: kind, since: nowMs - sub, busySince: busyStart,
                                            tool: tool),
                    hasActivity: true)
        }
        var state = AgentStatusState()
        state.apply(frame(.thinking, tool: nil, sub: 2_000), now: now)
        let start = state.activitySince
        XCTAssertEqual(start?.timeIntervalSince1970 ?? 0, TimeInterval(busyStart) / 1000, accuracy: 0.01)
        // Sub-activity transitions must NOT restart the timer.
        state.apply(frame(.tool, tool: "bash", sub: 500), now: now.addingTimeInterval(5))
        XCTAssertEqual(state.activitySince, start)
        state.apply(frame(.writing, tool: nil, sub: 100), now: now.addingTimeInterval(9))
        XCTAssertEqual(state.activitySince, start)

        // A new turn (new busySince) resets it.
        let newBusy = nowMs + 10_000
        state.apply(.status(busy: true, owner: "tui", v2: true, isSnapshot: false,
                            activity: AgentActivity(kind: .waiting, busySince: newBusy),
                            hasActivity: true), now: now.addingTimeInterval(10))
        XCTAssertEqual(state.activitySince?.timeIntervalSince1970 ?? 0,
                       TimeInterval(newBusy) / 1000, accuracy: 0.01)

        // Idle clears it.
        state.apply(.status(busy: false, owner: "tui", v2: true, isSnapshot: false,
                            activity: nil, hasActivity: true), now: now.addingTimeInterval(11))
        XCTAssertNil(state.activitySince)
    }

    func testBusySinceFallsBackWhenAbsentOrImplausible() {
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        // No busySince: fall back to local-clock, restart on kind change.
        var noBusy = AgentStatusState()
        noBusy.apply(.status(busy: true, owner: "tui", v2: true, isSnapshot: false,
                             activity: AgentActivity(kind: .tool, tool: "bash"), hasActivity: true), now: now)
        XCTAssertEqual(noBusy.activitySince, now)
        // busySince in the future is ignored (clock skew) → local fallback.
        var future = AgentStatusState()
        future.apply(.status(busy: true, owner: "tui", v2: true, isSnapshot: false,
                             activity: AgentActivity(kind: .tool, busySince: nowMs + 120_000, tool: "bash"),
                             hasActivity: true), now: now)
        XCTAssertEqual(future.activitySince, now)
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

        // §13: the Q&A row is keyed `tool:<toolCallId>` live and in history.
        var store = TranscriptStore()
        let keyedLive = ChatViewModel.identified(live, key: "tool:call-7")
        store.upsertLive(keyedLive)
        let server = ChatMessage(entryId: "e1", role: .tool, text: "", thinking: nil, toolCalls: [],
                                 isError: false, toolName: "ask_user_question", isSystemNote: false,
                                 model: nil, errorMessage: nil, timestamp: 1_000,
                                 qa: QAInfo(cancelled: true, items: []), key: "tool:call-7")
        store.merge([server], placement: .newer)
        XCTAssertEqual(store.rows.count, 1, "live + server copy are one row")
        XCTAssertEqual(store.rows[0].id, keyedLive.id, "row identity is stable")
        XCTAssertEqual(store.rows[0].entryId, "e1")

        // Pre-§13 server (no keys): both copies derive the same identity
        // from pi's timestamp — still one row, no text matching involved.
        var legacy = TranscriptStore()
        legacy.upsertLive(ChatViewModel.identified(live, key: nil))
        let legacyServer = ChatMessage(entryId: "e1", role: .tool, text: "", thinking: nil, toolCalls: [],
                                       isError: false, toolName: "ask_user_question", isSystemNote: false,
                                       model: nil, errorMessage: nil, timestamp: 1_000,
                                       qa: QAInfo(cancelled: true, items: []))
        legacy.merge(ChatViewModel.prepareHistory([legacyServer]), placement: .newer)
        XCTAssertEqual(legacy.rows.count, 1)
        XCTAssertEqual(legacy.rows[0].entryId, "e1")
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
