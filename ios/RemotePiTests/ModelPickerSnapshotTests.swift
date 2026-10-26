import XCTest
import SwiftUI
import Combine
@testable import RemotePi

/// Visual review snapshots (PNG → `$SIMULATOR_HOST_HOME/remotepi-snapshots`,
/// uploaded by CI) for the §11 model chip + picker, the live tok/s strip and
/// the §10 send-now (⚡) button on a queued chip — plus the state behind each.
@MainActor
final class ModelPickerSnapshotTests: XCTestCase {
    private static let themes: [(String, AppTheme)] = [("dark", AppTheme.darkGrey), ("light", AppTheme.light)]

    private static var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private static let catalog: [ModelEntry] = [
        ModelEntry(provider: "anthropic", id: "claude-opus-4-1", name: "Claude Opus 4.1",
                   contextWindow: 200_000, reasoning: true),
        ModelEntry(provider: "anthropic", id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5",
                   contextWindow: 1_000_000, reasoning: true),
        ModelEntry(provider: "anthropic", id: "claude-haiku-4-5", name: "Claude Haiku 4.5",
                   contextWindow: 200_000),
        ModelEntry(provider: "openai", id: "gpt-5", name: "GPT-5", contextWindow: 400_000, reasoning: true),
        ModelEntry(provider: "openai", id: "gpt-5-mini", name: "GPT-5 mini", contextWindow: 400_000),
        ModelEntry(provider: "zai", id: "glm-5.3-flash", name: "GLM 5.3 Flash", contextWindow: 131_072),
    ]

    private func makeViewModel(model: String?) -> ChatViewModel {
        ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "snapshot"),
                      sessionId: "snapshot-models", initialModel: model)
    }

    private func frame(_ event: String, _ json: String) -> ParsedSSEFrame {
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: event, id: "e-1", payload: payload)
    }

    private func usage(_ output: Int) -> SessionUsage {
        SessionUsage(json: ["input": 12_000, "output": output])!
    }

    private func bottomBar(_ vm: ChatViewModel, theme: AppTheme) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatBottomBar(viewModel: vm, status: vm.status)
        }
        .background(theme.background.ignoresSafeArea())
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme)
    }

    // MARK: (a) stats strip: model chip + context % + tok/s while streaming

    func testStatsStripWithModelChipAndRateWhileStreaming() throws {
        for (name, theme) in Self.themes {
            let vm = makeViewModel(model: "anthropic/claude-sonnet-4-5")
            vm.seedModelsForTesting(ModelListing(models: Self.catalog, current: nil))
            XCTAssertEqual(vm.currentModel?.name, "Claude Sonnet 4.5")

            let now = Self.nowMs
            vm.ingestForTesting([frame("agent_status", #"{"type":"agent_status","phase":"streaming","busy":true,"owner":"bridge","activity":{"kind":"writing","since":\#(now - 3_000),"busySince":\#(now - 45_000)},"questionId":null}"#)])
            vm.status.setStats(SessionStats(json: ["tokens": ["total": 48_210], "cost": 0.42,
                                                   "contextUsage": ["percent": 37.0]]))
            let t0 = Date()
            vm.status.setUsage(usage(400), at: t0)
            vm.status.setUsage(usage(462), at: t0.addingTimeInterval(1))

            XCTAssertTrue(vm.status.isStreamingOutput)
            XCTAssertEqual(vm.status.tokensPerSecond, 62)
            XCTAssertEqual(vm.status.workingText, "Writing…")
            XCTAssertEqual(vm.status.activitySince?.timeIntervalSince1970 ?? 0,
                           TimeInterval(now - 45_000) / 1000, accuracy: 0.01,
                           "banner timer runs from busySince")

            snapshot(bottomBar(vm, theme: theme), name: "stats-strip-streaming-\(name)")

            // Tool run: tok/s disappears, model chip + stats stay.
            vm.ingestForTesting([frame("agent_status", #"{"type":"agent_status","phase":"streaming","busy":true,"owner":"bridge","activity":{"kind":"tool","tool":"bash","since":\#(now),"busySince":\#(now - 45_000)},"questionId":null}"#)])
            XCTAssertNil(vm.status.tokensPerSecond)
            vm.stop()
        }
    }

    func testModelChipVisibleBeforeAnyStats() {
        for (name, theme) in Self.themes {
            let vm = makeViewModel(model: "zai/glm-5.3-flash")
            XCTAssertNil(vm.status.stats)
            XCTAssertFalse(vm.status.hasUsage)
            XCTAssertEqual(ModelPicker.displayName(current: vm.currentModel, models: vm.availableModels),
                           "glm-5.3-flash")
            snapshot(bottomBar(vm, theme: theme), name: "stats-strip-no-stats-\(name)")
            vm.stop()
        }
    }

    // MARK: (b) model picker sheet

    func testModelPickerSheet() {
        for (name, theme) in Self.themes {
            let vm = makeViewModel(model: nil)
            vm.seedModelsForTesting(ModelListing(models: Self.catalog,
                                                 current: ModelRef(provider: "openai", id: "gpt-5")))
            XCTAssertEqual(vm.currentModel?.name, "GPT-5")
            let groups = ModelPicker.groups(vm.availableModels, query: "")
            XCTAssertEqual(groups.map(\.provider), ["anthropic", "openai", "zai"])
            XCTAssertEqual(groups.flatMap(\.models).filter { vm.currentModel?.matches($0) ?? false }.map(\.id),
                           ["gpt-5"], "exactly one row is checked")

            snapshot(ModelPickerSheet(viewModel: vm, status: vm.status, theme: theme),
                     name: "model-picker-\(name)", settle: 1.0)
            // The sheet's refresh (unreachable server) must keep the list.
            if case .loaded(let models) = vm.modelList {
                XCTAssertEqual(models.count, Self.catalog.count)
            } else {
                XCTFail("a failed refresh must not replace a loaded list")
            }
            vm.stop()
        }
    }

    func testModelPickerLoadingAndErrorStates() {
        let theme = AppTheme.darkGrey
        let vm = makeViewModel(model: "zai/glm-5.3-flash")
        XCTAssertEqual(vm.modelList, .idle)
        // First open against an unreachable server: loading → failed (retry UI).
        snapshot(ModelPickerSheet(viewModel: vm, status: vm.status, theme: theme),
                 name: "model-picker-first-load-dark", settle: 0.3)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .failed = vm.modelList { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if case .failed = vm.modelList {
            snapshot(ModelPickerSheet(viewModel: vm, status: vm.status, theme: theme),
                     name: "model-picker-error-dark", settle: 0.3)
        }
        vm.stop()
    }

    // MARK: (c) queued chip with the ⚡ send-now button

    func testQueuedChipWithSendNowButton() throws {
        let vm = makeViewModel(model: nil)
        let queuedAt = Self.nowMs - 125_000
        vm.ingestForTesting([frame("queue_update", #"{"type":"queue_update","items":[{"id":"srv-1","clientMessageId":"c1","message":"Also add a regression test for the parser","status":"queued","queuedAt":\#(queuedAt)}]}"#)])
        vm.commitNow()
        let chip = try XCTUnwrap(vm.transcript.value.first { $0.kind == .queued })
        XCTAssertTrue(chip.canSteer)
        XCTAssertTrue(chip.cancellable)
        XCTAssertEqual(chip.statusText, "queued · 2m")

        let items = [
            TranscriptItem(id: "u1", kind: .user, text: "Refactor the SSE parser to stream frames."),
            TranscriptItem(id: "a1", kind: .assistant,
                           text: "Working on it — splitting `EventSource` into a parser and a transport…",
                           streaming: true),
        ] + vm.transcript.value

        for (name, theme) in Self.themes {
            let style = TranscriptStyle(theme: theme, textScale: 1, contentSize: .large)
            let transcript = TranscriptContainerView(style: style)
            let subject = CurrentValueSubject<[TranscriptItem], Never>(items)
            transcript.bind(transcript: subject.eraseToAnyPublisher(),
                            scrollRequests: Empty<Void, Never>().eraseToAnyPublisher())
            let host = UIViewController()
            host.view.backgroundColor = style.background
            transcript.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
            host.view.addSubview(transcript)
            snapshot(controller: host, size: CGSize(width: 390, height: 420),
                     name: "queued-chip-send-now-\(name)", settle: 1.5)
            XCTAssertEqual(transcript.tableView.numberOfRows(inSection: 0), 3)
            transcript.teardown()
        }
        vm.stop()
    }
}
