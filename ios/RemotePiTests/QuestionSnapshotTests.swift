import XCTest
import SwiftUI
import Combine
@testable import RemotePi

/// Renders the INLINE questionnaire card (the newest transcript row), the
/// status line and the Q&A transcript row from payloads captured live from
/// the real server (pi + ask_user_question), and writes PNGs for visual
/// review (`$SIMULATOR_HOST_HOME/remotepi-snapshots`, uploaded by CI) besides
/// asserting the parsed state. The chat composition is the real one: the
/// UIKit transcript (`ChatTranscriptArea`) bound to a `ChatViewModel`, with
/// `ChatBottomBar` docked below it.
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

    private static let questionRowId = "question:c3455b9e-e621-4d54-9431-c62990e83d06"

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
    }

    // MARK: - Frames

    private func frame(_ event: String, _ json: String) -> ParsedSSEFrame {
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: event, id: "e-1", payload: payload)
    }

    /// A transcript row pushed live (`file_update`, server-mapped shape).
    private func fileUpdate(_ messageJSON: String) -> ParsedSSEFrame {
        let message = (try? JSONSerialization.jsonObject(with: Data(messageJSON.utf8))) ?? [:]
        return ParsedSSEFrame(event: "file_update", id: "e-0",
                              payload: ["type": "file_update", "message": message])
    }

    private func userMessage(id: String, text: String, ts: Int) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"id":"\#(id)","role":"user","text":"\#(escaped)","isError":false,"timestamp":\#(ts)}"#
    }

    private func assistantMessage(id: String, text: String, ts: Int) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"id":"\#(id)","role":"assistant","text":"\#(escaped)","isError":false,"timestamp":\#(ts)}"#
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "snapshot"),
                      sessionId: "snapshot-session")
    }

    private func questionItems(_ vm: ChatViewModel) -> [TranscriptItem] {
        vm.transcript.value.filter { $0.kind == .question }
    }

    // MARK: - Harness (real chat composition in a window)

    private struct ChatScreen: View {
        @ObservedObject var vm: ChatViewModel
        let theme: AppTheme

        var body: some View {
            let model = vm
            ChatTranscriptArea(viewModel: vm, theme: theme, textScale: 1, contentSize: .large,
                               actions: TranscriptActions(
                                   nearBottomChanged: { model.setViewportNearBottom($0) },
                                   questionVisibilityChanged: { model.setQuestionRowVisible($0) }))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatBottomBar(viewModel: vm, status: vm.status)
                }
                .background(theme.background.ignoresSafeArea())
                .environment(\.theme, theme)
                .preferredColorScheme(theme.scheme)
        }
    }

    private func present(_ vm: ChatViewModel, theme: AppTheme) -> UIWindow {
        let controller = UIHostingController(rootView: ChatScreen(vm: vm, theme: theme))
        let window = makeSnapshotWindow(root: controller)
        windows.append(window)
        return window
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let match = find(type, in: sub) { return match }
        }
        return nil
    }

    private func transcript(in window: UIWindow) -> TranscriptContainerView? {
        find(TranscriptContainerView.self, in: window)
    }

    /// The question cell, when it is the newest row (row 0) and on screen.
    private func questionCell(in window: UIWindow) -> QuestionCell? {
        guard let table = transcript(in: window)?.tableView,
              table.numberOfSections > 0, table.numberOfRows(inSection: 0) > 0 else { return nil }
        return table.cellForRow(at: IndexPath(row: 0, section: 0)) as? QuestionCell
    }

    /// Feed the conversation + the live question frames; wait for the row.
    @discardableResult
    private func showQuestion(_ vm: ChatViewModel, in window: UIWindow, history: [String]) -> QuestionCell? {
        vm.ingestForTesting(history.map { fileUpdate($0) })
        XCTAssertTrue(waitUntil { vm.transcript.value.count == history.count }, "history rows must commit")
        vm.ingestForTesting([frame("agent_status", Self.statusQuestion), frame("agent_question", Self.question)])
        XCTAssertTrue(waitUntil { self.questionCell(in: window) != nil }, "question row must render")
        spin(0.4)
        return questionCell(in: window)
    }

    // MARK: - Inline card + status line (snapshots)

    func testInlineQuestionCardFromLivePayload() throws {
        for (name, theme) in [("dark", AppTheme.darkGrey), ("light", AppTheme.light)] {
            let vm = makeViewModel()
            let window = present(vm, theme: theme)
            showQuestion(vm, in: window, history: [Self.messages[0]])

            let q = try XCTUnwrap(vm.pendingQuestion, "agent_question frame must produce a card")
            XCTAssertEqual(q.items.count, 2)
            XCTAssertEqual(q.items[0].options.map(\.label), ["Red", "Blue"])
            XCTAssertEqual(q.items[0].options[0].preview, "```\nlet color = \"red\"\n```")
            XCTAssertTrue(q.items[1].multiSelect)
            XCTAssertEqual(vm.status.workingText, "Waiting for your answer")
            XCTAssertFalse(ChatViewModel.isComplete(q, selections: vm.questionSelections, text: vm.questionText))

            // Exactly one inline question row, and it is the newest row.
            let rows = questionItems(vm)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.id, Self.questionRowId)
            XCTAssertEqual(vm.transcript.value.last?.kind, .question)
            XCTAssertEqual(vm.transcript.value.first?.kind, .user)
            XCTAssertNotNil(questionCell(in: window))
            XCTAssertFalse(vm.showsQuestionWaitingPill, "no pill while the card is on screen")

            writeSnapshot(of: window, name: "question-inline-empty-\(name)")

            vm.questionSelections = [0: ["Red"], 1: ["Apple", "Cherry"]]
            XCTAssertTrue(ChatViewModel.isComplete(q, selections: vm.questionSelections, text: vm.questionText))
            spin(0.4)
            writeSnapshot(of: window, name: "question-inline-answered-\(name)")

            // Answered elsewhere (terminal / another device) → row + status clear.
            vm.ingestForTesting([frame("agent_question_resolved", Self.resolved), frame("agent_status", Self.statusIdle)])
            XCTAssertNil(vm.pendingQuestion)
            XCTAssertNil(vm.status.workingText)
            vm.commitNow()
            XCTAssertEqual(questionItems(vm).count, 0, "resolved question must leave the transcript")
            XCTAssertTrue(waitUntil { self.questionCell(in: window) == nil }, "question cell must go away")
            window.isHidden = true
        }
    }

    /// Scrolled up when the question arrives: the "Question waiting" pill
    /// shows above the composer; tapping it (its action) returns to the card.
    func testQuestionWaitingPillWhenScrolledUp() throws {
        for (name, theme) in [("dark", AppTheme.darkGrey), ("light", AppTheme.light)] {
            let vm = makeViewModel()
            let window = present(vm, theme: theme)
            var history: [String] = []
            for i in 0..<24 {
                let ts = 1_793_033_600_000 + i * 1_000
                history.append(i % 2 == 0
                    ? userMessage(id: "u\(i)", text: "Message \(i): what about the next step?", ts: ts)
                    : assistantMessage(id: "a\(i)", text: "Reply \(i).\nHere is a longer answer with a second line,\nand a third one for height.", ts: ts))
            }
            showQuestion(vm, in: window, history: history)
            let container = try XCTUnwrap(transcript(in: window))
            let table = container.tableView

            // Scroll up (inverted table: larger offset = older rows).
            let top = table.contentSize.height + table.contentInset.bottom - table.bounds.height
            XCTAssertGreaterThan(top, 400, "history must be scrollable")
            table.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            XCTAssertTrue(waitUntil { vm.showsQuestionWaitingPill }, "pill must show when the card is off screen")
            spin(0.3)
            writeSnapshot(of: window, name: "question-inline-scrolled-\(name)")

            // The pill's action: back to the newest row; the pill hides.
            vm.scrollTranscriptToBottom()
            XCTAssertTrue(waitUntil { !vm.showsQuestionWaitingPill }, "pill must hide at the bottom")
            XCTAssertNotNil(questionCell(in: window))
            window.isHidden = true
        }
    }

    // MARK: - Interaction (runs on the iOS 15 job too)

    func testInlineQuestionRowInteraction() throws {
        let theme = AppTheme.darkGrey
        let vm = makeViewModel()
        let window = present(vm, theme: theme)
        let cell = try XCTUnwrap(showQuestion(vm, in: window, history: [Self.messages[0]]))
        let container = try XCTUnwrap(transcript(in: window))
        let table = container.tableView
        let question = try XCTUnwrap(vm.pendingQuestion)

        // Height: non-zero and == the card's natural height at the table width.
        let rowHeight = table.rectForRow(at: IndexPath(row: 0, section: 0)).height
        let style = TranscriptStyle(theme: theme, textScale: 1, contentSize: .large)
        let measurer = UIHostingController(rootView: QuestionRowContent.measuring(
            AnyView(QuestionCardView(viewModel: vm, question: question)), style: style, width: table.bounds.width))
        let measured = ceil(measurer.sizeThatFits(in: CGSize(width: table.bounds.width,
                                                             height: .greatestFiniteMagnitude)).height)
        XCTAssertGreaterThan(measured, 150, "card content must have a real height")
        XCTAssertGreaterThanOrEqual(rowHeight, measured - 0.5)
        XCTAssertLessThanOrEqual(rowHeight, measured + 1)
        XCTAssertEqual(cell.host.view.bounds.height, rowHeight, accuracy: 0.5)

        // Upright: the hosted view maps to the window with identity scale
        // (table flip × contentView flip cancel) and lies on screen.
        let origin = cell.host.view.convert(CGPoint(x: 0, y: 0), to: window)
        let below = cell.host.view.convert(CGPoint(x: 10, y: 100), to: window)
        XCTAssertEqual(below.y - origin.y, 100, accuracy: 0.5, "hosted card must not be flipped")
        XCTAssertEqual(below.x - origin.x, 10, accuracy: 0.5)
        XCTAssertTrue(window.bounds.contains(CGPoint(x: origin.x + 1, y: max(origin.y, 0) + 1)))
        XCTAssertNotNil(cell.host.parent, "hosting controller must be a child view controller")

        let contentKey = cell.contentKey
        XCTAssertNotNil(contentKey)

        // Select an option through the card's accessibility element (a real
        // button activation); fall back to view-model state if SwiftUI's
        // accessibility tree isn't exposed in this environment.
        if let red = accessibilityElement(labeled: "Red. warm", in: cell.host.view), red.accessibilityActivate() {
            if !waitUntil(2, { vm.questionSelections[0] == ["Red"] }) {
                NSLog("[question] accessibility activation did not select; selecting via view model")
            }
        } else {
            NSLog("[question] accessibility tree unavailable; selecting via view model")
        }
        if vm.questionSelections[0] != ["Red"] { vm.questionSelections[0] = ["Red"] }
        vm.questionSelections[1] = ["Apple", "Cherry"]
        spin(0.4)
        XCTAssertTrue(vm.questionIsComplete)
        XCTAssertNotNil(vm.pendingQuestion, "selecting must not submit")

        // Selecting never reloads/reconfigures the row.
        XCTAssertTrue(questionCell(in: window) === cell, "selection must not reload the question row")
        XCTAssertEqual(cell.contentKey, contentKey)
        XCTAssertEqual(table.rectForRow(at: IndexPath(row: 0, section: 0)).height, rowHeight, accuracy: 0.5,
                       "selection must not change the row height")

        // Focus survives typing + unrelated transcript updates (the composer
        // stays usable: a normal message lands while the card waits).
        let field = find(UITextField.self, in: cell.host.view)
        let focused = field?.becomeFirstResponder() ?? false
        if !focused { NSLog("[question] text field not focusable here; skipping focus assertions") }
        vm.questionText[1] = "no bananas"
        vm.ingestForTesting([fileUpdate(userMessage(id: "u-late", text: "Also: keep it short.", ts: 1_793_033_690_000))])
        XCTAssertTrue(waitUntil { table.numberOfRows(inSection: 0) == 3 }, "new message row must land")
        spin(0.3)
        XCTAssertEqual(vm.transcript.value.last?.kind, .question, "question stays the newest row")
        XCTAssertTrue(questionCell(in: window) === cell, "transcript updates must not reload the question row")
        XCTAssertEqual(cell.contentKey, contentKey)
        if focused, let field {
            XCTAssertTrue(field.isFirstResponder, "typing focus must survive transcript updates")
            field.resignFirstResponder()
        }
        window.isHidden = true
    }

    func testStaleCardDroppedByQuestionId() {
        let vm = makeViewModel()
        vm.ingestForTesting([frame("agent_status", Self.statusQuestion), frame("agent_question", Self.question)])
        XCTAssertNotNil(vm.pendingQuestion)
        vm.commitNow()
        XCTAssertEqual(questionItems(vm).count, 1)
        // No resolved frame (e.g. missed while disconnected): status alone clears it.
        vm.ingestForTesting([frame("agent_status", Self.statusIdle)])
        XCTAssertNil(vm.pendingQuestion)
        vm.commitNow()
        XCTAssertEqual(questionItems(vm).count, 0)
    }

    func testQuestionItemShape() throws {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.question.utf8)) as? [String: Any])
        let question = try XCTUnwrap(AgentQuestion(json: payload))
        let item = ChatViewModel.questionItem(question)
        XCTAssertEqual(item.id, Self.questionRowId)
        XCTAssertEqual(item.kind, .question)
        XCTAssertEqual(item.actionId, question.requestId)
        XCTAssertEqual(item.question, question)
        XCTAssertTrue(item.text.contains("Pick a color"))
        XCTAssertTrue(item.text.contains("• Banana — yellow"))
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

    // MARK: - Accessibility lookup

    /// Depth-first search of the (SwiftUI) accessibility tree under `root`.
    private func accessibilityElement(labeled label: String, in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 40 else { return nil }
        if root.accessibilityLabel == label { return root }
        var children: [NSObject] = []
        if let elements = root.accessibilityElements as? [NSObject] {
            children = elements
        } else {
            let count = root.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for i in 0..<count {
                    if let element = root.accessibilityElement(at: i) as? NSObject { children.append(element) }
                }
            }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children where child !== root {
            if let match = accessibilityElement(labeled: label, in: child, depth: depth + 1) { return match }
        }
        return nil
    }
}
