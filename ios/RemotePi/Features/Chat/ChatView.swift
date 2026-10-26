import SwiftUI
import UIKit
import Combine

/// Chat conversation screen: SwiftUI chrome around the UIKit transcript.
///
/// Observation is split so views only re-render for what they show:
/// - this view observes `ChatViewModel` (low-frequency state only);
/// - the status banner / stats / toolbar control observe `ChatLiveStatus`;
/// - the composer keeps its text in local `@State`;
/// - transcript rows bypass SwiftUI entirely (Combine → UITableView).
@MainActor
struct ChatView: View {
    let server: ServerConfig
    let session: SessionSummary
    private let client: APIClient
    @AppStorage("chatTextScale") private var textScale: Double = 1.0
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var viewModel: ChatViewModel
    @State private var selectedText: SelectableText?

    init(server: ServerConfig, session: SessionSummary) {
        self.server = server
        self.session = session
        let client = APIClient(baseURL: server.url ?? URL(string: "http://localhost")!,
                               token: server.token)
        self.client = client
        _viewModel = StateObject(wrappedValue: ChatViewModel(client: client, sessionId: session.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HostOwnershipBanner(status: viewModel.status, client: client, sessionId: session.id,
                                initialLive: session.live == true, initialPid: session.livePid)
            TranscriptView(viewModel: viewModel,
                           theme: theme,
                           textScale: textScale,
                           contentSize: dynamicTypeSize.uiContentSizeCategory,
                           actions: transcriptActions)
                .overlay { loadingOverlay }
        }
        // Composer + status bars live in the bottom safe-area inset: they stay
        // docked above the keyboard and the transcript ends exactly at their
        // top edge (no reserved blank slots → no gaps).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatBottomBar(viewModel: viewModel, status: viewModel.status)
        }
        .background(theme.background)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            viewModel.requestFork(entryId: nil, name: "fork of \(session.name)")
                        } label: {
                            Label("Fork at latest message", systemImage: "arrow.branch")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More actions")
                    ToolbarStatusControl(status: viewModel.status,
                                         connected: viewModel.connectionState == .connected,
                                         onAbort: { viewModel.abort() })
                }
            }
        }
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { phase in
            // Only a real background transition suspends the network:
            // `.inactive` (control centre, app switcher peek, alerts) must not
            // drop the stream or disable sending.
            switch phase {
            case .background:
                viewModel.suspendNetwork()
            case .active:
                viewModel.resumeNetwork()
            default:
                break
            }
        }
        .onChange(of: viewModel.shouldDismiss) { dismiss in
            if dismiss { presentationMode.wrappedValue.dismiss() }
        }
        .onDisappear { viewModel.stop() }
        .alert(alertTitle, isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? viewModel.infoMessage ?? "")
        }
        .sheet(item: $selectedText) { selection in
            SelectableTextSheet(text: selection.text, theme: theme,
                                fontSize: 17 * CGFloat(textScale))
        }
    }

    private var transcriptActions: TranscriptActions {
        let vm = viewModel
        let forkName = "fork of \(session.name)"
        let selection = $selectedText
        return TranscriptActions(
            loadMore: { vm.loadMore() },
            nearBottomChanged: { vm.setViewportNearBottom($0) },
            cancelQueued: { vm.cancelQueued($0) },
            steerQueued: { vm.steerQueued($0) },
            discardOffline: { id in
                if let uuid = UUID(uuidString: id) { vm.discardOffline(uuid) }
            },
            fork: { entryId in vm.requestFork(entryId: entryId, name: forkName) },
            selectText: { text in selection.wrappedValue = SelectableText(text: text) }
        )
    }

    /// Small centered spinner only while there is no data yet; retry UI on
    /// failure; nothing at all once rows exist (no opaque cover).
    @ViewBuilder
    private var loadingOverlay: some View {
        if viewModel.transcriptIsEmpty {
            switch viewModel.loadPhase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading conversation")
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("Couldn't load the conversation")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(theme.text)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Retry") { viewModel.retryLoad() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(24)
            case .loaded:
                Text("No messages yet")
                    .font(.footnote)
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private var alertTitle: String {
        viewModel.errorMessage != nil ? "Error" : "Remote Pi"
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil || viewModel.infoMessage != nil },
            set: { presented in
                if !presented {
                    viewModel.errorMessage = nil
                    viewModel.infoMessage = nil
                }
            }
        )
    }
}

// MARK: - Bottom bar (question card, status banner, queue note, stats, composer)

struct ChatBottomBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var status: ChatLiveStatus
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if let question = viewModel.pendingQuestion {
                QuestionCardView(viewModel: viewModel, question: question)
            }
            if let work = status.workingText {
                WorkingBanner(text: work, kind: status.activityKind, since: status.activitySince)
            }
            if let note = viewModel.queuedNote {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(note)
                        .font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
                .accessibilityElement(children: .combine)
            }
            // pi 0.85 stats strip: context % + tokens + cost. Only rendered
            // when data exists — zero chrome otherwise.
            if status.stats != nil || status.hasUsage {
                HStack(spacing: 10) {
                    if let pct = status.stats?.contextPercent {
                        Label("\(Int(pct))%", systemImage: "gauge.medium")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(pct > 90 ? .red : pct > 70 ? .orange : theme.secondaryText)
                            .accessibilityLabel("Context \(Int(pct)) percent used")
                    }
                    if let tokens = status.stats?.totalTokens, tokens > 0 {
                        Text("\(tokens.formatted()) tok")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(theme.secondaryText)
                    }
                    if let cost = status.stats?.cost, cost > 0 {
                        Text(String(format: "$%.2f", cost))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(theme.secondaryText)
                    }
                    if let tps = status.tokensPerSecond, tps > 0 {
                        Text("\(tps) tok/s")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(theme.secondaryText)
                            .accessibilityLabel("\(tps) tokens per second")
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
            ComposerView { text in viewModel.send(text) }
        }
    }
}

/// Stop button while the agent works, otherwise the connection dot.
struct ToolbarStatusControl: View {
    @ObservedObject var status: ChatLiveStatus
    let connected: Bool
    let onAbort: () -> Void

    var body: some View {
        if status.isBusy {
            Button(action: onAbort) {
                Image(systemName: "stop.circle")
                    .foregroundColor(.red)
            }
            .accessibilityLabel("Stop the agent")
        } else {
            Circle()
                .fill(connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityLabel(connected ? "Connected" : "Connecting")
        }
    }
}

/// "Running in host terminal" banner. Driven by contract-v2
/// `agent_status.owner` when available, plus a slow (30s), equality-gated
/// session poll for v1 servers — it re-renders only itself.
struct HostOwnershipBanner: View {
    @ObservedObject var status: ChatLiveStatus
    let client: APIClient
    let sessionId: String
    @Environment(\.theme) private var theme
    @State private var live: Bool
    @State private var pid: Int?

    init(status: ChatLiveStatus, client: APIClient, sessionId: String, initialLive: Bool, initialPid: Int?) {
        _status = ObservedObject(wrappedValue: status)
        self.client = client
        self.sessionId = sessionId
        _live = State(initialValue: initialLive)
        _pid = State(initialValue: initialPid)
    }

    var body: some View {
        VStack(spacing: 0) {
            if live || status.hostOwned {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("Running in host terminal — external pi process\(pid.map { " (pid \($0))" } ?? "")")
                        .font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.accent.opacity(0.15))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            while !Task.isCancelled {
                if let summary = try? await client.fetchSession(sessionId) {
                    let isLive = summary.live == true
                    if live != isLive { live = isLive }
                    if pid != summary.livePid { pid = summary.livePid }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}

/// Working/activity banner (contract §7). Re-renders only on label / kind /
/// transition changes; the elapsed counter ticks inside its own
/// `TimelineView`, so nothing else in the bar re-renders every second.
struct WorkingBanner: View {
    let text: String
    let kind: AgentActivity.Kind?
    let since: Date?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = symbolName {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            }
            Text(text)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let since {
                ElapsedLabel(since: since)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.accent.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    /// Spinner for plain "working"/optimistic states, a symbol otherwise.
    private var symbolName: String? {
        guard let kind, kind != .waiting else { return nil }
        return AgentActivity(kind: kind).symbolName
    }
}

/// "· 12s" / "· 1m 05s" since the activity started (hidden below 3s).
struct ElapsedLabel: View {
    let since: Date
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(ElapsedFormatter.label(context.date.timeIntervalSince(since)) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

/// Ask-user-question card (contract §8): renders the pending questionnaire
/// above the composer — single/multi select, option descriptions and
/// previews, optional typed answer. The questions area is sized to its
/// content up to ~60% of the space above the keyboard and scrolls beyond
/// that; Submit / "Chat about this" stay pinned at the card bottom.
struct QuestionCardView: View {
    @ObservedObject var viewModel: ChatViewModel
    let question: AgentQuestion
    @Environment(\.theme) private var theme
    @State private var contentHeight: CGFloat = 0
    @State private var keyboardHeight: CGFloat = 0

    /// Header + footer + paddings around the questions area.
    private static let chromeHeight: CGFloat = 104

    private var isComplete: Bool {
        ChatViewModel.isComplete(question, selections: viewModel.questionSelections,
                                 text: viewModel.questionText)
    }

    private var scrollCap: CGFloat {
        let available = max(0, UIScreen.main.bounds.height - keyboardHeight)
        return max(96, available * 0.6 - Self.chromeHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            questionsArea
            footer
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.6))
        .overlay(Rectangle().frame(height: 1).foregroundColor(theme.accent.opacity(0.25)),
                 alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
                return
            }
            keyboardHeight = max(0, UIScreen.main.bounds.height - frame.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .accessibilityElement(children: .contain)
    }

    /// The questions render at their NATURAL height and only become a bounded,
    /// scrollable region once they would exceed `scrollCap`. Crucially, until
    /// the content is measured (`contentHeight == 0`) the natural branch is
    /// used, so on first appearance the questions are always fully laid out —
    /// never trapped at ~1pt. (A fixed-height `ScrollView` seeded from a 0/1
    /// `@State` + `onPreferenceChange` frequently never settles on iOS 15, so
    /// the card would show only its header + footer with no visible content.)
    @ViewBuilder
    private var questionsArea: some View {
        let questions = VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(question.items.enumerated()), id: \.element.id) { position, item in
                section(item, position: position)
            }
        }
        .padding(.vertical, 2)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: QuestionCardHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(QuestionCardHeightKey.self) { contentHeight = $0 }

        if contentHeight > scrollCap {
            ScrollView { questions }
                .frame(height: scrollCap)
        } else {
            questions
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble")
                .accessibilityHidden(true)
            Text(question.items.count > 1 ? "Agent question · \(question.items.count) questions" : "Agent question")
                .font(.caption.weight(.semibold))
            Spacer()
            Button {
                viewModel.cancelQuestionAction()
            } label: {
                Text("Cancel").font(.caption)
            }
            .accessibilityLabel("Decline the question")
        }
        .foregroundColor(theme.accent)
    }

    private func section(_ item: AgentQuestion.Item, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if question.items.count > 1 || !item.header.isEmpty {
                HStack(spacing: 6) {
                    if question.items.count > 1 {
                        Text("QUESTION \(position + 1) OF \(question.items.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(theme.secondaryText)
                    }
                    if !item.header.isEmpty {
                        Text(item.header.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundColor(theme.accent)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text(item.question)
                .font(.subheadline)
                .foregroundColor(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(item.options) { option in
                optionRow(item: item, option: option)
            }
            TextField(placeholder(for: item), text: typedBinding(for: item))
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(item.multiSelect ? "Note for question \(position + 1)"
                                                     : "Typed answer for question \(position + 1)")
        }
    }

    private func placeholder(for item: AgentQuestion.Item) -> String {
        if item.multiSelect { return "Add a note (optional)…" }
        return item.options.isEmpty ? "Type your answer…" : "Or type your own answer…"
    }

    /// Single-select: typing replaces the picked option (sent as `custom`);
    /// multi-select: typed text is a note on the selection.
    private func typedBinding(for item: AgentQuestion.Item) -> Binding<String> {
        let vm = viewModel
        return Binding(
            get: { vm.questionText[item.index] ?? "" },
            set: { newValue in
                vm.questionText[item.index] = newValue
                if !item.multiSelect, newValue.hasVisibleCharacters,
                   !(vm.questionSelections[item.index] ?? []).isEmpty {
                    vm.questionSelections[item.index] = []
                }
            })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                viewModel.chatAboutQuestionAction()
            } label: {
                Text("Chat about this")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityHint("Skips the questions so you can reply in the chat")
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                viewModel.submitQuestionAction()
            } label: {
                Text("Submit")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(theme.accent.opacity(isComplete ? 0.18 : 0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(!isComplete)
            .accessibilityLabel("Submit answers")
            .accessibilityHint(isComplete ? "Sends your answers to the agent" : "Answer every question first")
        }
    }

    private func optionRow(item: AgentQuestion.Item, option: AgentQuestion.Option) -> some View {
        let isSelected = (viewModel.questionSelections[item.index] ?? []).contains(option.label)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                var current = viewModel.questionSelections[item.index] ?? []
                if item.multiSelect {
                    if current.contains(option.label) { current.remove(option.label) }
                    else { current.insert(option.label) }
                } else {
                    current = [option.label]
                    viewModel.questionText[item.index] = ""
                }
                viewModel.questionSelections[item.index] = current
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isSelected
                          ? (item.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                          : (item.multiSelect ? "square" : "circle"))
                        .foregroundColor(isSelected ? theme.accent : theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.text)
                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.caption2)
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(option.description.isEmpty ? option.label : "\(option.label). \(option.description)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(item.multiSelect ? "Toggles this option" : "Selects this option")
            if let preview = option.preview {
                QuestionPreviewBlock(text: preview)
                    .padding(.leading, 26)
            }
        }
    }
}

/// Option `preview` (contract §8): monospaced, horizontally scrollable for
/// wide ASCII art, at most `maxHeight` tall with its own vertical scroll.
struct QuestionPreviewBlock: View {
    let text: String
    @Environment(\.theme) private var theme

    static let maxHeight: CGFloat = 180

    /// Natural height of the text in the caption2 monospaced font.
    private var naturalHeight: CGFloat {
        let size = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        let lineHeight = ceil(UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight) + 1
        let lines = text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        return CGFloat(lines) * lineHeight + 16
    }

    /// Previews are markdown; a block that is one fenced code block shows
    /// just its code (no ``` fence lines).
    static func displayText(_ raw: String) -> String {
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "
")
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return raw }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "
")
    }

    var body: some View {
        // A two-axis ScrollView centres content smaller than itself; pin it
        // to the top-leading corner via a min-size frame.
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(Self.displayText(text))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(theme.text)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(height: min(Self.maxHeight, naturalHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue(text)
    }
}

private struct QuestionCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Composer: the draft lives in LOCAL state, so typing re-renders only this
/// view (never the chat screen or the transcript).
struct ComposerView: View {
    let onSend: (String) -> Void
    @State private var text = ""
    @Environment(\.theme) private var theme

    init(onSend: @escaping (String) -> Void) {
        self.onSend = onSend
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message…", text: $text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Message")

                Button {
                    let draft = text
                    text = ""
                    onSend(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(theme.secondaryBackground)
    }
}

// MARK: - Select Text sheet

struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

/// Full-text sheet with native selection (the transcript rows themselves
/// carry no competing gestures).
struct SelectableTextSheet: View {
    let text: String
    let theme: AppTheme
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            SelectableTextView(text: text, fontSize: fontSize,
                               textColor: UIColor(theme.text),
                               background: UIColor(theme.background))
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(theme.scheme)
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: UIColor
    let background: UIColor

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = [.link]
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: fontSize))
        view.textColor = textColor
        view.backgroundColor = background
    }
}

// MARK: - Dynamic Type bridge

extension DynamicTypeSize {
    /// SwiftUI → UIKit content size category (iOS 15-safe manual mapping).
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
