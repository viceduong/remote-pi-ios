import XCTest
import SwiftUI
import Combine
@testable import RemotePi

/// Renders the questionnaire card, status line and Q&A transcript row from
/// payloads captured live from the real server (pi + ask_user_question), and
/// writes PNGs for visual review (`$SIMULATOR_HOST_HOME/remotepi-snapshots`,
/// uploaded by CI) besides asserting the parsed state.
@MainActor
final class QuestionSnapshotTests: XCTestCase {
    // Captured verbatim from GET /events?skeleton=1 and /messages?visible=1.
    static let statusQuestion = #"{"type":"agent_status","phase":"streaming","busy":true,"working":true,"owner":"bridge","activity":{"kind":"question","since":1793033684856},"questionId":"c3455b9e-e621-4d54-9431-c62990e83d06"}"#
    static let question = #"{"type":"agent_question","requestId":"c3455b9e-e621-4d54-9431-c62990e83d06","questions":[{"index":0,"header":"Color","question":"Pick a color","multiSelect":false,"options":[{"label":"Red","description":"warm","preview":"```\nlet color = \"red\"\n```"},{"label":"Blue","description":"cool"}]},{"index":1,"header":"Fruit","question":"Pick fruits","multiSelect":true,"options":[{"label":"Apple","description":"crisp"},{"label":"Banana","description":"yellow"},{"label":"Cherry","description":"sweet"}]}]}"#
    static let resolved = #"{"type":"agent_question_resolved","requestId":"c3455b9e-e621-4d54-9431-c62990e83d06"}"#
    static let statusIdle = #"{"type":"agent_status","phase":"idle","busy":false,"working":false,"owner":"bridge","activity":null,"questionId":null}"#
    static let messages = [
        #"{"id":"2a0f2518","role":"user","text":"Ask me two quick questions, please.","toolName":null,"isError":false,"timestamp":1793033681031}"#,
        #"{"id":"632b24f5","role":"tool","text":"User has answered your questions: \"Pick a color\"=\"Red\". \"Pick fruits\"=\"Apple, Cherry\". You can now continue with the user's answers in mind.","toolName":"ask_user_question","isError":false,"timestamp":1793033686036,"qa":{"cancelled":false,"items":[{"question":"Pick a color","answer":"Red"},{"question":"Pick fruits","answer":"Apple, Cherry"}]}}"#,
        #"{"id":"d37ba502","role":"assistant","text":"You picked Red, plus Apple and Cherry as your fruits.","toolName":null,"isError":false,"model":"zai/glm-5.3-flash","timestamp":1793033686040}"#,
    ]

    private func frame(_ event: String, _ json: String) -> ParsedSSEFrame {
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: event, id: "e-1", payload: payload)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "snapshot"),
                      sessionId: "snapshot-session")
    }

    // MARK: - Card + status line

    func testQuestionCardFromLivePayload() throws {
        for (name, theme) in [("dark", AppTheme.darkGrey), ("light", AppTheme.light)] {
            let vm = makeViewModel()
            vm.ingestForTesting([frame("agent_status", Self.statusQuestion), frame("agent_question", Self.question)])

            let q = try XCTUnwrap(vm.pendingQuestion, "agent_question frame must produce a card")
            XCTAssertEqual(q.items.count, 2)
            XCTAssertEqual(q.items[0].options.map(\.label), ["Red", "Blue"])
            XCTAssertEqual(q.items[0].options[0].preview, "```\nlet color = \"red\"\n```")
            XCTAssertTrue(q.items[1].multiSelect)
            XCTAssertEqual(vm.status.workingText, "Waiting for your answer")
            XCTAssertFalse(ChatViewModel.isComplete(q, selections: vm.questionSelections, text: vm.questionText))

            snapshot(bottomBar(vm, theme: theme), name: "question-card-empty-\(name)")

            vm.questionSelections = [0: ["Red"], 1: ["Apple", "Cherry"]]
            XCTAssertTrue(ChatViewModel.isComplete(q, selections: vm.questionSelections, text: vm.questionText))
            snapshot(bottomBar(vm, theme: theme), name: "question-card-answered-\(name)")

            // Answered elsewhere (terminal / another device) → card + status clear.
            vm.ingestForTesting([frame("agent_question_resolved", Self.resolved), frame("agent_status", Self.statusIdle)])
            XCTAssertNil(vm.pendingQuestion)
            XCTAssertNil(vm.status.workingText)
        }
    }

    func testStaleCardDroppedByQuestionId() {
        let vm = makeViewModel()
        vm.ingestForTesting([frame("agent_status", Self.statusQuestion), frame("agent_question", Self.question)])
        XCTAssertNotNil(vm.pendingQuestion)
        // No resolved frame (e.g. missed while disconnected): status alone clears it.
        vm.ingestForTesting([frame("agent_status", Self.statusIdle)])
        XCTAssertNil(vm.pendingQuestion)
    }

    // MARK: - Q&A transcript row

    func testQARowRendersInTranscript() throws {
        let decoded = try Self.messages.map {
            try JSONDecoder().decode(WireMessage.self, from: Data($0.utf8)).toChatMessage()
        }
        let visible = ChatViewModel.displayable(decoded)
        XCTAssertEqual(visible.count, 3, "user, Q&A and assistant rows must all be visible")
        let items = visible.map { ChatViewModel.transcriptItem(for: $0, streaming: false) }
        XCTAssertEqual(items[1].kind, .qa)

        for (name, theme) in [("dark", AppTheme.darkGrey), ("light", AppTheme.light)] {
            let style = TranscriptStyle(theme: theme, textScale: 1, contentSize: .large)
            let transcript = TranscriptContainerView(style: style)
            let subject = CurrentValueSubject<[TranscriptItem], Never>(items)
            transcript.bind(transcript: subject.eraseToAnyPublisher(),
                            scrollRequests: Empty<Void, Never>().eraseToAnyPublisher())
            let host = UIViewController()
            host.view.backgroundColor = style.background
            transcript.frame = CGRect(x: 0, y: 0, width: 390, height: 520)
            host.view.addSubview(transcript)
            snapshot(controller: host, size: CGSize(width: 390, height: 520), name: "qa-transcript-\(name)", settle: 1.5)
            XCTAssertGreaterThan(transcript.tableView.numberOfRows(inSection: 0), 2)
            transcript.teardown()
        }
    }

    // MARK: - Rendering helpers

    private func bottomBar(_ vm: ChatViewModel, theme: AppTheme) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ChatBottomBar(viewModel: vm, status: vm.status)
        }
        .background(theme.background.ignoresSafeArea())
        .environment(\.theme, theme)
        .preferredColorScheme(theme.name == AppTheme.light.name ? .light : .dark)
    }

    private func snapshot<V: View>(_ view: V, name: String) {
        let controller = UIHostingController(rootView: view)
        snapshot(controller: controller, size: CGSize(width: 390, height: 844), name: name, settle: 0.6)
    }

    private func snapshot(controller: UIViewController, size: CGSize, name: String, settle: TimeInterval) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() {
            let root = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSTemporaryDirectory()
            let dir = URL(fileURLWithPath: root).appendingPathComponent("remotepi-snapshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.isHidden = true
    }
}
