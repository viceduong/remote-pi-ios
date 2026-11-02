import XCTest
@testable import RemotePi

/// In-memory §16 endpoints (no network) for model + snapshot tests.
final class StubShellService: BackgroundShellService {
    var shells: [BackgroundShell]
    var listError: Error?
    var outputs: [String: ShellOutput] = [:]
    var outputError: Error?
    var outcome: Result<BackgroundBashOutcome, Error> = .success(.detached)
    var killError: Error?
    private(set) var listCalls = 0
    private(set) var outputCalls = 0
    private(set) var backgroundCalls = 0
    private(set) var killed: [String] = []

    init(shells: [BackgroundShell] = []) {
        self.shells = shells
    }

    func backgroundBash(_ sessionId: String) async throws -> BackgroundBashOutcome {
        backgroundCalls += 1
        return try outcome.get()
    }

    func listShells(_ sessionId: String) async throws -> [BackgroundShell] {
        listCalls += 1
        if let listError { throw listError }
        return shells
    }

    func shellOutput(_ sessionId: String, shellId: String, tail: Int) async throws -> ShellOutput {
        outputCalls += 1
        if let outputError { throw outputError }
        return outputs[shellId] ?? ShellOutput(text: "")
    }

    func killShell(_ sessionId: String, shellId: String) async throws {
        if let killError { throw killError }
        killed.append(shellId)
        shells = shells.map { $0.id == shellId ? $0.with(status: .killed) : $0 }
    }
}

// MARK: - Decoding

final class BackgroundShellDecodingTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testDecodesFullShellList() throws {
        let shells = try APIClient.decodeShellList(data(#"""
        {"shells":[
          {"id":"bg-0000000a","command":"npm run dev","status":"running","pid":4242,
           "startTime":1767000000000,"outputBytes":2048},
          {"id":"bg-0000000b","command":"pytest -x","status":"failed","pid":77,
           "startTime":1766990000000,"endTime":1766990012000,"exitCode":1,"durationMs":12000,"outputBytes":900}
        ]}
        """#))
        XCTAssertEqual(shells.count, 2)
        XCTAssertEqual(shells[0].id, "bg-0000000a")
        XCTAssertEqual(shells[0].command, "npm run dev")
        XCTAssertEqual(shells[0].status, .running)
        XCTAssertEqual(shells[0].pid, 4242)
        XCTAssertEqual(shells[0].startTime, 1_767_000_000_000)
        XCTAssertNil(shells[0].endTime)
        XCTAssertNil(shells[0].exitCode)
        XCTAssertEqual(shells[0].outputBytes, 2048)
        XCTAssertEqual(shells[1].status, .failed)
        XCTAssertEqual(shells[1].exitCode, 1)
        XCTAssertEqual(shells[1].durationMs, 12_000)
        XCTAssertEqual(shells[1].endTime, 1_766_990_012_000)
    }

    func testShellListIsTolerant() throws {
        let shells = try APIClient.decodeShellList(data(#"""
        {"shells":[
          {"command":"no id — dropped"},
          "garbage",
          {"id":"bg-00000001","status":"RUNNING","pid":"12","startTime":1767000000,"exitCode":null},
          {"id":"bg-00000002","status":"zombie","startTime":"2026-01-01T00:00:00.500Z","durationMs":1500.7},
          {"id":"bg-00000003"}
        ],"extra":true}
        """#))
        XCTAssertEqual(shells.map(\.id), ["bg-00000001", "bg-00000002", "bg-00000003"])
        XCTAssertEqual(shells[0].status, .running, "status is case-insensitive")
        XCTAssertEqual(shells[0].pid, 12, "numeric strings are accepted")
        XCTAssertEqual(shells[0].startTime, 1_767_000_000_000, "seconds epoch is promoted to ms")
        XCTAssertNil(shells[0].exitCode)
        XCTAssertEqual(shells[1].status, .unknown("zombie"))
        XCTAssertEqual(shells[1].startTime, 1_767_225_600_500, "ISO-8601 start time")
        XCTAssertEqual(shells[1].durationMs, 1500)
        XCTAssertEqual(shells[2].command, "")
        XCTAssertEqual(shells[2].status, .unknown(""))
    }

    func testShellListShapes() throws {
        XCTAssertEqual(try APIClient.decodeShellList(data(#"{"shells":[]}"#)), [])
        XCTAssertEqual(try APIClient.decodeShellList(data(#"{"ok":true}"#)), [], "missing key = empty")
        XCTAssertEqual(try APIClient.decodeShellList(data(#"[{"id":"bg-00000009","status":"completed"}]"#)).map(\.id),
                       ["bg-00000009"], "a bare array is accepted")
        XCTAssertThrowsError(try APIClient.decodeShellList(data("<html>proxy</html>")))
        XCTAssertThrowsError(try APIClient.decodeShellList(Data()))
    }

    func testDecodesShellOutput() throws {
        let out = try APIClient.decodeShellOutput(data(#"{"text":"\u001b[32mok\u001b[0m\n","truncated":true,"size":524288}"#))
        XCTAssertEqual(out.text, "\u{1B}[32mok\u{1B}[0m\n")
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.size, 524_288)

        let sparse = try APIClient.decodeShellOutput(data(#"{"size":"12"}"#))
        XCTAssertEqual(sparse, ShellOutput(text: "", truncated: false, size: 12))
        XCTAssertThrowsError(try APIClient.decodeShellOutput(data("nope")))
    }

    func testBackgroundOutcomeMapping() throws {
        func outcome(_ status: Int, _ json: String) throws -> BackgroundBashOutcome {
            try APIClient.backgroundOutcome(status: status, data: Data(json.utf8))
        }
        XCTAssertEqual(try outcome(200, #"{"ok":true,"detached":true}"#), .detached)
        XCTAssertEqual(try outcome(200, #"{"ok":true,"detached":false}"#), .notDetached)
        XCTAssertEqual(try outcome(200, #"{"ok":true,"detached":null}"#), .requested)
        XCTAssertEqual(try outcome(200, #"{"ok":true}"#), .requested)
        XCTAssertEqual(try outcome(200, ""), .requested)
        if case .failed(let message) = try outcome(200, #"{"ok":true,"detached":false,"unsupported":true}"#) {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("unsupported:true must surface as a failure")
        }
        XCTAssertEqual(try outcome(409, #"{"error":"nothing running"}"#), .nothingRunning)
        XCTAssertEqual(try outcome(404, #"{"error":"Not found"}"#), .unsupportedServer)
        XCTAssertEqual(try outcome(502, #"{"error":"Ctrl+B unsupported — reload the TUI"}"#),
                       .failed("Ctrl+B unsupported — reload the TUI"))
        XCTAssertEqual(try outcome(502, #"{"error":{"message":"transport gone"}}"#), .failed("transport gone"))
        if case .failed(let message) = try outcome(502, "") {
            XCTAssertTrue(message.contains("reload the TUI"), message)
        } else {
            XCTFail("502 must be a failure outcome")
        }
        XCTAssertThrowsError(try outcome(500, #"{"error":"boom"}"#)) { error in
            XCTAssertEqual(error as? APIError, .http(500, "boom", nil))
        }
    }
}

// MARK: - Pure logic

final class BackgroundShellLogicTests: XCTestCase {
    func testBackgroundButtonVisibilityRule() {
        XCTAssertTrue(BackgroundBashRule.isVisible(kind: .tool, tool: "bash"))
        XCTAssertTrue(BackgroundBashRule.isVisible(kind: .tool, tool: "Bash"))
        XCTAssertTrue(BackgroundBashRule.isVisible(kind: .tool, tool: " BASH "))
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: .toolcall, tool: "bash"), "only while it runs")
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: .tool, tool: "read"))
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: .tool, tool: "bash_background"))
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: .tool, tool: nil))
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: .writing, tool: "bash"))
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: nil, tool: "bash"))
    }

    func testStatusMapping() {
        XCTAssertEqual(BackgroundShell.Status(raw: "running"), .running)
        XCTAssertEqual(BackgroundShell.Status(raw: "Running"), .running)
        XCTAssertEqual(BackgroundShell.Status(raw: "completed"), .completed)
        XCTAssertEqual(BackgroundShell.Status(raw: "done"), .completed)
        XCTAssertEqual(BackgroundShell.Status(raw: "failed"), .failed)
        XCTAssertEqual(BackgroundShell.Status(raw: "ERROR"), .failed)
        XCTAssertEqual(BackgroundShell.Status(raw: "killed"), .killed)
        XCTAssertEqual(BackgroundShell.Status(raw: "terminated"), .killed)
        XCTAssertEqual(BackgroundShell.Status(raw: nil), .unknown(""))
        XCTAssertEqual(BackgroundShell.Status(raw: "paused"), .unknown("paused"))
        XCTAssertEqual(BackgroundShell.Status.unknown("paused").label, "Paused")
        XCTAssertEqual(BackgroundShell.Status.running.label, "Running")
    }

    func testSortingRunningFirstThenNewest() {
        let list = [
            BackgroundShell(id: "a", command: "old done", status: .completed, startTime: 1_000),
            BackgroundShell(id: "b", command: "old running", status: .running, startTime: 2_000),
            BackgroundShell(id: "c", command: "new done", status: .failed, startTime: 5_000),
            BackgroundShell(id: "d", command: "no start", status: .killed),
            BackgroundShell(id: "e", command: "new running", status: .running, startTime: 9_000),
        ]
        XCTAssertEqual(ShellListLogic.sorted(list).map(\.id), ["e", "b", "c", "a", "d"])
        XCTAssertEqual(ShellListLogic.runningCount(list), 2)
        // Ties fall back to the id (stable across polls).
        let tied = [BackgroundShell(id: "y", command: "", status: .completed, startTime: 1),
                    BackgroundShell(id: "x", command: "", status: .completed, startTime: 1)]
        XCTAssertEqual(ShellListLogic.sorted(tied).map(\.id), ["x", "y"])
    }

    func testFormatting() {
        XCTAssertEqual(ShellFormat.ago(2), "just now")
        XCTAssertEqual(ShellFormat.ago(42), "42s ago")
        XCTAssertEqual(ShellFormat.ago(185), "3m ago")
        XCTAssertEqual(ShellFormat.ago(7300), "2h ago")
        XCTAssertEqual(ShellFormat.ago(200_000), "2d ago")
        XCTAssertEqual(ShellFormat.duration(0.3), "<1s")
        XCTAssertEqual(ShellFormat.duration(12), "12s")
        XCTAssertEqual(ShellFormat.duration(185), "3m 05s")
        XCTAssertEqual(ShellFormat.duration(3720), "1h 02m")

        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = 1_000_000_000
        let running = BackgroundShell(id: "r", command: "x", status: .running, startTime: nowMs - 185_000)
        XCTAssertEqual(ShellFormat.subtitle(running, now: now), "Running · started 3m ago · 3m 05s")
        let failed = BackgroundShell(id: "f", command: "x", status: .failed, startTime: nowMs - 7_300_000,
                                     endTime: nowMs - 7_288_000, exitCode: 2)
        XCTAssertEqual(ShellFormat.subtitle(failed, now: now), "Failed · started 2h ago · took 12s · exit 2")
        let durationWins = BackgroundShell(id: "d", command: "x", status: .completed, startTime: nowMs - 60_000,
                                           endTime: nowMs - 50_000, exitCode: 0, durationMs: 9_000)
        XCTAssertEqual(ShellFormat.subtitle(durationWins, now: now), "Completed · started 1m ago · took 9s · exit 0")
        let bare = BackgroundShell(id: "u", command: "x", status: .unknown(""))
        XCTAssertEqual(ShellFormat.subtitle(bare, now: now), "Unknown")
    }

    func testOutputTextNormalizationAndCopy() {
        XCTAssertEqual(ShellOutputText.normalize("a\r\nb\r\n"), "a\nb\n")
        XCTAssertEqual(ShellOutputText.normalize("10%\r50%\r100%\ndone"), "100%\ndone")
        XCTAssertEqual(ShellOutputText.normalize("progress\r"), "progress")
        XCTAssertEqual(ShellOutputText.normalize("plain"), "plain")
        XCTAssertEqual(ShellOutputText.stripANSI("\u{1B}[1;32mPASS\u{1B}[0m tests \u{1B}[2K\u{1B}[?25lok"),
                       "PASS tests ok")
        XCTAssertEqual(ShellOutputText.stripANSI("no escapes"), "no escapes")
    }

    func testMenuText() {
        XCTAssertEqual(ShellMenuText.title(running: 0), "Background shells")
        XCTAssertEqual(ShellMenuText.title(running: 2), "Background shells (2 running)")
        XCTAssertNil(ShellMenuText.badge(0))
        XCTAssertEqual(ShellMenuText.badge(3), "3")
        XCTAssertEqual(ShellMenuText.badge(12), "9+")
    }
}

// MARK: - Models (stub service, no network)

@MainActor
final class BackgroundShellsModelTests: XCTestCase {
    private static let nowMs = Int(Date().timeIntervalSince1970 * 1000)

    private func frame(_ json: String) -> ParsedSSEFrame {
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: "agent_status", id: "e-1", payload: payload)
    }

    func testLiveStatusExposesToolForTheButtonRule() {
        let vm = ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t"),
                               sessionId: "bg-rule")
        let now = Self.nowMs
        vm.ingestForTesting([frame(#"{"type":"agent_status","phase":"streaming","busy":true,"owner":"bridge","activity":{"kind":"tool","tool":"Bash","since":\#(now)},"questionId":null}"#)])
        XCTAssertEqual(vm.status.activityKind, .tool)
        XCTAssertEqual(vm.status.activityTool, "Bash")
        XCTAssertTrue(BackgroundBashRule.isVisible(kind: vm.status.activityKind, tool: vm.status.activityTool))

        vm.ingestForTesting([frame(#"{"type":"agent_status","phase":"streaming","busy":true,"owner":"bridge","activity":{"kind":"writing","since":\#(now)},"questionId":null}"#)])
        XCTAssertNil(vm.status.activityTool)
        XCTAssertFalse(BackgroundBashRule.isVisible(kind: vm.status.activityKind, tool: vm.status.activityTool))

        vm.ingestForTesting([frame(#"{"type":"agent_status","phase":"idle","busy":false,"owner":"bridge","activity":null,"questionId":null}"#)])
        XCTAssertNil(vm.status.activityKind)
        XCTAssertNil(vm.status.activityTool)
        vm.stop()
    }

    func testRefreshSortsAndCountsRunning() async {
        let stub = StubShellService(shells: [
            BackgroundShell(id: "bg-00000001", command: "make", status: .completed, startTime: 1_000),
            BackgroundShell(id: "bg-00000002", command: "npm run dev", status: .running, startTime: 500),
        ])
        let model = BackgroundShellsModel(service: stub, sessionId: "s")
        XCTAssertNil(model.supported)
        XCTAssertFalse(model.showsMenuEntry)
        await model.refresh()
        XCTAssertEqual(model.shells.map(\.id), ["bg-00000002", "bg-00000001"])
        XCTAssertEqual(model.runningCount, 1)
        XCTAssertEqual(model.supported, true)
        XCTAssertTrue(model.showsMenuEntry)
        XCTAssertEqual(model.listState, .loaded)
    }

    func testOldServer404HidesFeatures() async {
        let stub = StubShellService()
        stub.listError = APIError.http(404, "Not Found", nil)
        let model = BackgroundShellsModel(service: stub, sessionId: "s")
        await model.refresh()
        XCTAssertEqual(model.supported, false)
        XCTAssertEqual(model.listState, .unsupported)
        XCTAssertFalse(model.showsMenuEntry)
        // Polling never starts against an unsupported server.
        model.start()
        XCTAssertEqual(stub.listCalls, 1)
        model.teardown()
    }

    func testRefreshFailureKeepsLastList() async {
        let stub = StubShellService(shells: [BackgroundShell(id: "bg-00000001", command: "x", status: .running)])
        let model = BackgroundShellsModel(service: stub, sessionId: "s")
        await model.refresh()
        stub.listError = APIError.offline
        await model.refresh()
        XCTAssertEqual(model.shells.count, 1)
        if case .failed = model.listState {} else { XCTFail("expected a failed state") }
        XCTAssertEqual(model.supported, true, "a transient failure keeps the feature visible")
    }

    func testBackgroundOutcomesProduceNotices() async {
        let stub = StubShellService()
        let model = BackgroundShellsModel(service: stub, sessionId: "s")

        stub.outcome = .success(.nothingRunning)
        let first = model.requestBackground()
        XCTAssertNotNil(first)
        XCTAssertTrue(model.isBackgrounding)
        XCTAssertNil(model.requestBackground(), "disabled while the request is in flight")
        await first?.value
        XCTAssertFalse(model.isBackgrounding)
        XCTAssertEqual(stub.backgroundCalls, 1)
        XCTAssertEqual(model.notice?.kind, .info)
        XCTAssertEqual(model.notice?.text, "Nothing running")

        stub.outcome = .success(.failed("Ctrl+B unsupported — reload the TUI"))
        await model.requestBackground()?.value
        XCTAssertEqual(model.notice?.kind, .error)
        XCTAssertEqual(model.notice?.text, "Ctrl+B unsupported — reload the TUI")

        stub.outcome = .success(.detached)
        await model.requestBackground()?.value
        XCTAssertEqual(model.notice?.kind, .success)
        XCTAssertEqual(model.supported, true)

        stub.outcome = .success(.unsupportedServer)
        await model.requestBackground()?.value
        XCTAssertEqual(model.supported, false, "404 hides the button")

        stub.outcome = .failure(APIError.offline)
        await model.requestBackground()?.value
        XCTAssertEqual(model.notice?.kind, .error)

        model.dismissNotice()
        XCTAssertNil(model.notice)
        model.teardown()
    }

    func testKillMarksShellKilled() async {
        let stub = StubShellService(shells: [BackgroundShell(id: "bg-00000001", command: "sleep 99", status: .running)])
        let model = BackgroundShellsModel(service: stub, sessionId: "s")
        await model.refresh()
        let task = model.kill("bg-00000001")
        XCTAssertTrue(model.killing.contains("bg-00000001"))
        XCTAssertNil(model.kill("bg-00000001"), "no double kill")
        await task?.value
        XCTAssertEqual(stub.killed, ["bg-00000001"])
        XCTAssertEqual(model.shells.first?.status, .killed)
        XCTAssertEqual(model.runningCount, 0)
        XCTAssertTrue(model.killing.isEmpty)
        XCTAssertNil(model.actionError)
    }

    func testKillFailureSurfacesError() async {
        let stub = StubShellService(shells: [BackgroundShell(id: "bg-00000001", command: "x", status: .running)])
        stub.killError = APIError.http(409, "not running", nil)
        let model = BackgroundShellsModel(service: stub, sessionId: "s")
        await model.refresh()
        await model.kill("bg-00000001")?.value
        XCTAssertEqual(model.actionError, "That shell is no longer running.")
        XCTAssertTrue(model.killing.isEmpty)
    }

    func testOutputModelFetchesOnceForFinishedShell() async {
        let stub = StubShellService(shells: [BackgroundShell(id: "bg-00000001", command: "x", status: .completed)])
        stub.outputs["bg-00000001"] = ShellOutput(text: "hello\n", truncated: false, size: 6)
        let shells = BackgroundShellsModel(service: stub, sessionId: "s")
        await shells.refresh()
        let output = ShellOutputModel(shellId: "bg-00000001", shells: shells)
        await output.run()
        XCTAssertEqual(stub.outputCalls, 1, "a finished shell is not polled")
        XCTAssertEqual(output.output?.text, "hello\n")
        XCTAssertEqual(output.state, .loaded)
    }

    func testOutputModelErrorState() async {
        let stub = StubShellService()
        stub.outputError = APIError.http(404, "unknown shell", nil)
        let shells = BackgroundShellsModel(service: stub, sessionId: "s")
        let output = ShellOutputModel(shellId: "bg-0000000f", shells: shells)
        await output.load()
        XCTAssertEqual(output.state, .failed("unknown shell"))
        XCTAssertNil(output.output)
    }
}
