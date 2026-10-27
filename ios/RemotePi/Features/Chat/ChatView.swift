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
        _viewModel = StateObject(wrappedValue: ChatViewModel(client: client, sessionId: session.id,
                                                             initialModel: session.model))
    }

    var body: some View {
        VStack(spacing: 0) {
            HostOwnershipBanner(status: viewModel.status, client: client, sessionId: session.id,
                                initialLive: session.live == true, initialPid: session.livePid)
            ChatTranscriptArea(viewModel: viewModel,
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
            ToolbarItem(placement: .principal) {
                ChatTitleView(title: session.name, workdir: session.workdir)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            viewModel.requestFork(entryId: nil, name: "fork of \(session.name)")
                        } label: {
                            Label("Fork at latest message", systemImage: "arrow.branch")
                        }
                        if let workdir = session.workdir, !workdir.isEmpty {
                            Button {
                                UIPasteboard.general.string = workdir
                            } label: {
                                Label("Copy folder path", systemImage: "doc.on.doc")
                            }
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
            selectText: { text in selection.wrappedValue = SelectableText(text: text) },
            questionVisibilityChanged: { vm.setQuestionRowVisible($0) }
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

// MARK: - Transcript area (UIKit transcript + "Question waiting" pill)

/// The transcript plus the non-blocking "Question waiting" pill shown above
/// the composer while a question is pending and its inline card (the newest
/// transcript row) is scrolled out of view. Shared by `ChatView` and tests.
struct ChatTranscriptArea: View {
    @ObservedObject var viewModel: ChatViewModel
    let theme: AppTheme
    let textScale: Double
    let contentSize: UIContentSizeCategory
    let actions: TranscriptActions

    var body: some View {
        TranscriptView(viewModel: viewModel,
                       theme: theme,
                       textScale: textScale,
                       contentSize: contentSize,
                       actions: actions)
            .overlay(alignment: .bottom) {
                if viewModel.showsQuestionWaitingPill {
                    QuestionWaitingPill {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        viewModel.scrollTranscriptToBottom()
                    }
                    .padding(.bottom, 10)
                }
            }
    }
}

/// Small capsule that jumps to the pending question card.
struct QuestionWaitingPill: View {
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.caption.weight(.semibold))
                Text("Question waiting")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.accent))
            .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question waiting")
        .accessibilityHint("Scrolls to the agent's question")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Bottom bar (status banner, stats, composer)

/// The pending question is NOT shown here: it is an inline transcript row
/// (`QuestionCell`), so the composer stays fully usable while it waits.
struct ChatBottomBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var status: ChatLiveStatus
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if let work = status.workingText {
                WorkingBanner(text: work, kind: status.activityKind, since: status.activitySince)
            }
            ChatStatsStrip(viewModel: viewModel, status: status)
            ComposerView { text in viewModel.send(text) }
        }
    }
}

/// Session strip: the current model as a tappable chip (contract §11; always
/// shown so the picker is reachable before any stats exist) + pi 0.85 stats
/// (context %, tokens, cost) + live tok/s while the model streams output.
struct ChatStatsStrip: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var status: ChatLiveStatus
    @Environment(\.theme) private var theme
    @State private var showModelPicker = false

    var body: some View {
        HStack(spacing: 10) {
            ModelChip(name: ModelPicker.displayName(current: viewModel.currentModel,
                                                    models: viewModel.availableModels)) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showModelPicker = true
            }
            if let pct = status.stats?.contextPercent {
                Label("\(Int(pct))%", systemImage: "gauge.medium")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(pct > 90 ? .red : pct > 70 ? .orange : theme.secondaryText)
                    .fixedSize()
                    .accessibilityLabel("Context \(Int(pct)) percent used")
            }
            if let tokens = status.stats?.totalTokens, tokens > 0 {
                Text("\(tokens.formatted()) tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.secondaryText)
                    .fixedSize()
                    .accessibilityLabel("\(tokens.formatted()) tokens used")
            }
            if let cost = status.stats?.cost, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.secondaryText)
                    .fixedSize()
                    .accessibilityLabel(String(format: "Cost %.2f dollars", cost))
            }
            if let tps = status.tokensPerSecond, tps > 0 {
                Text("\(tps) tok/s")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(theme.secondaryText)
                    .fixedSize()
                    .accessibilityLabel("\(tps) tokens per second")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(viewModel: viewModel, status: viewModel.status, theme: theme)
        }
    }
}

/// Compact capsule naming the current model; truncates before the stats do.
struct ModelChip: View {
    let name: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2.weight(.semibold))
                Text(name ?? "Model")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.accent.opacity(0.12))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.map { "Model: \($0)" } ?? "Choose model")
        .accessibilityHint("Opens the model picker")
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

/// Ask-user-question card (contract §8), shown INLINE as the newest
/// transcript row (hosted by `QuestionCell`): single/multi select, option
/// descriptions and previews, optional typed answer, Submit / "Chat about
/// this" / Cancel. It renders at its natural height and scrolls with the
/// conversation (no inner scroll view, no height cap).
///
/// Its height must NOT depend on interactive state (the table uses exact,
/// precomputed row heights and reloading the row would drop the text
/// field's focus): the typed-answer fields stay single-line, selection
/// glyphs have a fixed frame, and errors surface as alerts, not inline text.
struct QuestionCardView: View {
    @ObservedObject var viewModel: ChatViewModel
    let question: AgentQuestion
    @Environment(\.theme) private var theme
    /// Selection glyph box (scales with Dynamic Type, never with selection).
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 20

    private var isComplete: Bool {
        ChatViewModel.isComplete(question, selections: viewModel.questionSelections,
                                 text: viewModel.questionText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(question.items.enumerated()), id: \.element.id) { position, item in
                    section(item, position: position)
                }
            }
            .padding(.vertical, 2)
            footer
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.secondaryBackground))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, TranscriptMetrics.hPad)
        .padding(.vertical, TranscriptMetrics.vPad)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
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
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.background)
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
                    .background(theme.background)
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
                        // Fixed glyph box: selecting never changes the
                        // card's height (the row height is precomputed).
                        .frame(width: glyphSize, height: glyphSize)
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
        let lines = Self.displayText(text).reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        return CGFloat(lines) * lineHeight + 16
    }

    /// Previews are markdown; a block that is one fenced code block shows
    /// just its code (no ``` fence lines).
    static func displayText(_ raw: String) -> String {
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        guard lines.count >= 2,
              lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return raw }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
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
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue(text)
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

/// Navigation-bar title: session name + its working folder (contract §12),
/// so the chat screen shows where the agent runs (same path as the session
/// list row, middle-truncated).
struct ChatTitleView: View {
    let title: String
    let workdir: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundColor(theme.text)
                .lineLimit(1)
            if let workdir, !workdir.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(workdir)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(theme.secondaryText)
            }
        }
        .frame(maxWidth: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
    }

    private var accessibilityText: String {
        guard let workdir, !workdir.isEmpty else { return title }
        return "\(title), folder \(workdir)"
    }
}
