import SwiftUI

/// Bottom-of-content marker: its maxY in the scroll coordinate space is the
/// REAL distance signal for auto-follow. Row onAppear/onDisappear flickered
/// during LazyVStack churn and caused the 'yanked back to bottom' bug.
private struct BottomMarkerKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Bottom marker + one-shot offset clamp, extracted into a tiny view so the
/// chat layout type-checks quickly.
private struct BottomMarkerAndClamp: View {
    let clampTrigger: Bool
    let onClamped: () -> Void

    var body: some View {
        Color.clear.frame(height: 1)
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: BottomMarkerKey.self,
                    value: g.frame(in: .named("chatScroll")).maxY
                )
            })
            .background(ScrollBottomClamp(trigger: clampTrigger, onClamped: onClamped))
    }
}

/// Chat conversation with streaming responses, tool activity and abort control.
@MainActor
struct ChatView: View {
    let server: ServerConfig
    let session: SessionSummary
    private let client: APIClient
    @AppStorage("chatTextScale") private var textScale: Double = 1.0
    @Environment(\.theme) private var theme

    @StateObject private var viewModel: ChatViewModel

    @State private var scrolledToBottom = false
    @State private var focusItem: ToolFocusItem?
    @State private var showScrollToBottom = false
    /// One-shot initial scroll + auto-follow throttle (offset-based follow).
    @State private var didInitialScroll = false
    @State private var lastAutoScroll = Date.distantPast
    /// Measured from the real scroll offset (bottom marker vs viewport).
    @State private var nearBottom = false
    /// Initial offset clamp done.
    @State private var didClampInitial = false
    /// True while the user is actively dragging — the follow must never fight
    /// an in-progress pan (that was the bottom stutter).
    @State private var isUserScrolling = false
    /// Live-refreshed host-ownership state (banner stays current).
    @State private var liveNow = false
    @State private var livePid: Int?
    @Environment(\.presentationMode) private var presentationMode
    /// Focus mode (default ON): hides tool output, calls, notes AND thinking.
    @AppStorage("hideToolsEnabled") private var hideTools = true

    /// Focus-mode list: tool messages, tool-call chips, system notes and
    /// thinking blocks hidden.
    private var visibleMessages: [ChatMessage] {
        if hideTools {
            return viewModel.messages
                .filter { $0.role != .tool && !$0.isSystemNote }
                .map { msg in
                    guard msg.thinking != nil else { return msg }
                    var m = msg
                    m.thinking = nil
                    return m
                }
        }
        return viewModel.messages
    }

    init(server: ServerConfig, session: SessionSummary) {
        self.server = server
        self.session = session
        let client = APIClient(baseURL: server.url ?? URL(string: "http://localhost")!,
                               token: server.token)
        self.client = client
        _liveNow = State(initialValue: session.live == true)
        _livePid = State(initialValue: session.livePid)
        _viewModel = StateObject(wrappedValue: ChatViewModel(client: client, sessionId: session.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if liveNow {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("Running in host terminal — external pi process\(livePid.map { " (pid \($0))" } ?? "")")
                        .font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.accent.opacity(0.15))
            }
            GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty && viewModel.isLoadingHistory {
                            HStack {
                                ProgressView()
                                Text("Loading messages…")
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }
                        if hideTools && viewModel.messages.contains(where: { $0.role == .tool || $0.isSystemNote }) {
                            Button {
                                withAnimation { hideTools = false }
                            } label: {
                                Label("Tool output, thinking & notes hidden — tap to show", systemImage: "hammer")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(viewModel.queuedItems) { item in
                            QueuedBubble(item: item) {
                                Task { await viewModel.cancelQueued(item.id) }
                            }
                        }
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            MessageBubble(message: message, isStreaming: isStreaming(message),
                                          hideToolCalls: hideTools,
                                          onFocus: { item in focusItem = item },
                                          onDiagnose: { diagnose($0) },
                                          onFork: { forkFrom($0) })
                            .id(message.id)
                            .onAppear {
                                // Prefetch the previous page before the user
                                // reaches the very top (smooth pagination).
                                if index < 8 {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    // Bottom marker + reliable open-at-bottom clamp (extracted
                    // so the type checker isn't overwhelmed).
                    .background(BottomMarkerAndClamp(
                        clampTrigger: !didClampInitial && !viewModel.messages.isEmpty,
                        onClamped: { didClampInitial = true }
                    ))

                    // Gesture-aware follow: never jump while the user drags.
                    Color.clear.frame(height: 1)
                        .background(ScrollPanDetector { active in
                            isUserScrolling = active
                        })
                }
                .coordinateSpace(name: "chatScroll")
                .overlay(alignment: .bottomTrailing) {
                    if showScrollToBottom {
                        Button {
                            scrollToBottom(proxy, animated: true)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .background(theme.secondaryBackground.opacity(0.95))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(theme.border, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                    }
                }
                // At-bottom is measured from the REAL scroll offset (bottom
                // marker vs viewport height) — immune to LazyVStack row
                // onAppear/onDisappear flicker, so scrolling up is never yanked
                // back. Follow: one-shot initial, then throttled 250ms, both
                // non-animated, only while within 200pt of the bottom.
                // Marker only updates STATE (nearBottom for the gate + button
                // visibility) — it must NOT drive scrolling: programmatic
                // scrolls move the marker, which would self-trigger follow
                // forever (the infinite-scroll-on-open loop).
                .onPreferenceChange(BottomMarkerKey.self) { markerY in
                    let distance = markerY - geo.size.height
                    nearBottom = distance <= 200
                    let showBtn = distance > 200
                    if showBtn != showScrollToBottom { showScrollToBottom = showBtn }
                }
                // Follow fires ONLY on real new messages (count change), gated
                // by being near the bottom and the user not scrolling. The
                // one-shot didInitialScroll lands the first page at the bottom.
                .onChange(of: viewModel.messages.count) { _ in
                    guard nearBottom, !isUserScrolling else { return }
                    if !didInitialScroll {
                        didInitialScroll = true
                        scrollToBottom(proxy, animated: false)
                    } else if Date().timeIntervalSince(lastAutoScroll) > 0.25 {
                        lastAutoScroll = Date()
                        scrollToBottom(proxy, animated: false)
                    }
                }
            }
            }

        }
        // Composer + status bars live in the bottom safe-area inset: iOS 15
        // keyboard avoidance is clean (no blank band below the input), and the
        // fixed-height reservation above the input stops viewport jumps.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let work = viewModel.workingText {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.accent)
                        Text(work)
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accent.opacity(0.10))
                } else {
                    Color.clear.frame(height: 28)
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
                } else if viewModel.workingText == nil {
                    // Collapse the empty queued slot when the working banner is
                    // showing — no 26pt gap between it and the input.
                    Color.clear.frame(height: 26)
                }

                ComposerView(viewModel: viewModel)
            }
        }
        .environment(\.chatTextScale, textScale)
        .background(theme.background)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Menu {
                        Button {
                            forkFrom(nil)
                        } label: {
                            Label("Fork at latest message", systemImage: "arrow.branch")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    Button {
                        withAnimation { hideTools.toggle() }
                    } label: {
                        Image(systemName: hideTools ? "hammer" : "hammer.circle")
                            .foregroundColor(hideTools ? .orange : .secondary)
                    }
                    if viewModel.isStreaming {
                        Button {
                            Task { await viewModel.abort() }
                        } label: {
                            Image(systemName: "stop.circle")
                                .foregroundColor(.red)
                        }
                    } else {
                        statusDot
                    }
                }
            }
        }
        .task { await viewModel.start() }
        .task {
            // Keep the host-ownership banner current.
            while !Task.isCancelled {
                if let summary = try? await client.fetchSession(session.id) {
                    liveNow = summary.live == true
                    livePid = summary.livePid
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onDisappear { viewModel.stop() }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Session is live on host", isPresented: $viewModel.confirmLiveResume) {
            Button("Resume anyway", role: .destructive) { viewModel.confirmResumeLive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An external pi process is using this session right now. Resuming writes the same session file from two agents — let it finish first if possible.")
        }
        .fullScreenCover(item: $focusItem) { item in
            ToolFocusView(item: item)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(viewModel.connectionState == .connected ? Color.green : Color.orange)
            .frame(width: 10, height: 10)
    }

    private func isStreaming(_ message: ChatMessage) -> Bool {
        viewModel.isStreaming && message.id == viewModel.messages.last?.id
    }

    /// Long-press on a bubble copies its classification to the clipboard so
    /// misrenderings can be reported precisely (role/toolName/text head).
    private func diagnose(_ message: ChatMessage) {
        let head = String(message.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
        let diag = "role=\(message.role.rawValue) toolName=\(message.toolName ?? "nil") isError=\(message.isError) text=\(head)"
        UIPasteboard.general.string = diag
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        viewModel.errorMessage = "Copied: \(diag)"
    }

    /// Fork the session from a message (entryId) or the latest user message.
    private func forkFrom(_ message: ChatMessage?) {
        Task {
            do {
                let (forked, text) = try await client.forkSession(
                    session.id,
                    entryId: message?.entryId,
                    name: "fork of \(session.name)"
                )
                viewModel.errorMessage = "Forked → \(forked.name)" + (text.map { ": \(String($0.prefix(40)))" } ?? "")
                // Pop back to the session list — it refreshes on appear.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if let last = visibleMessages.last {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// One message bubble: user right, assistant/tool left, markdown rendering.
struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    var hideToolCalls = false
    var onFocus: (ToolFocusItem) -> Void = { _ in }
    var onDiagnose: (ChatMessage) -> Void = { _ in }
    var onFork: (ChatMessage) -> Void = { _ in }
    @State private var noteExpanded = false
    @Environment(\.chatTextScale) private var textScale
    @Environment(\.theme) private var theme
    /// Parsed markdown (off-main, cached by text) — avoids first-frame stutter
    /// when opening a session with many markdown-heavy messages.
    @State private var parsedText: AttributedString?

    private func scaled(_ base: CGFloat) -> CGFloat { base * CGFloat(textScale) }

    init(message: ChatMessage, isStreaming: Bool, hideToolCalls: Bool = false,
         onFocus: @escaping (ToolFocusItem) -> Void = { _ in },
         onDiagnose: @escaping (ChatMessage) -> Void = { _ in },
         onFork: @escaping (ChatMessage) -> Void = { _ in }) {
        self.message = message
        self.isStreaming = isStreaming
        self.hideToolCalls = hideToolCalls
        self.onFocus = onFocus
        self.onDiagnose = onDiagnose
        self.onFork = onFork
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isSystemNote {
                systemNoteView
            } else {
                if message.role == .user { Spacer(minLength: 60) }

                if message.role == .user {
                    userBubble
                } else if message.role == .tool {
                    toolBubble
                } else {
                    assistantBubble
                }

                if message.role != .user { Spacer(minLength: 24) }
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture {
            onDiagnose(message)
        }
        .contextMenu {
            if message.role == .user && message.entryId != nil {
                Button {
                    onFork(message)
                } label: {
                    Label("Fork from here", systemImage: "arrow.branch")
                }
            }
            Button {
                onFocus(.result(message))
            } label: {
                Label("Open details", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                onDiagnose(message)
            } label: {
                Label("Copy classification", systemImage: "doc.on.doc")
            }
        }
    }

    /// pi background-shell notification / prune summary — rendered like a
    /// tool call: left-aligned monospace block with icon + expandable output.
    private var systemNoteView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "note.text")
                .font(.caption)
                .foregroundColor(.teal)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(noteTitle)
                        .font(.caption.weight(.bold))
                    Spacer(minLength: 8)
                    Button {
                        withAnimation { noteExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(noteExpanded ? "less" : "more")
                            Image(systemName: noteExpanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: scaled(11), design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(noteExpanded ? nil : 6)
                        .padding(8)
                        .background(theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var noteTitle: String {
        if message.text.contains("[bg-") { return "Background shell" }
        if message.text.contains("Tool Call") { return "Prune summary" }
        return "System note"
    }

    private var userBubble: some View {
        Text(message.text)
            .font(.system(size: scaled(17)))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.userBubble)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .textSelection(.enabled)
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thinking = message.thinking, !thinking.isEmpty {
                ThinkingView(text: thinking)
            }
            if !message.text.isEmpty {
                if isStreaming {
                    // Plain text while streaming: markdown re-parse per delta is
                    // O(n²) and causes scroll lag on long messages.
                    Text(message.text)
                        .font(.system(size: scaled(17)))
                        .textSelection(.enabled)
                } else {
                    Text(displayText)
                        .font(.system(size: scaled(17)))
                        .textSelection(.enabled)
                        .onAppear { loadParsedText() }
                }
            } else if isStreaming && message.thinking?.isEmpty != false {
                StreamingDots()
            }
            if !message.toolCalls.isEmpty && !hideToolCalls {
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, call in
                    ToolCallChip(call: call) {
                        onFocus(.call(name: call.name, arguments: call.argumentsText))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    /// Tool output — monospace block, mirrors the pi terminal's tool section.
    /// Rows stay light: inline preview capped, full output opens in focus mode.
    private var toolBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "hammer.fill")
                .font(.caption)
                .foregroundColor(message.isError ? .red : .orange)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(message.toolName ?? "tool")
                        .font(.caption.weight(.bold))
                    Spacer(minLength: 8)
                    if isStreaming && message.text.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
                    if message.isError {
                        Text("failed")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    Button {
                        onFocus(.result(message))
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    if isStreaming {
                        Text(message.text)
                            .font(.system(size: scaled(11), design: .monospaced))
                            .foregroundColor(message.isError ? .red : .primary)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(theme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        TerminalText(text: message.text, color: message.isError ? .red : theme.terminalText, fontSize: scaled(11))
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(theme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.isError ? Color.red.opacity(0.08) : theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onFocus(.result(message))
        }
    }

    /// Plain text until the off-main markdown parse lands (cached by text).
    private var displayText: AttributedString {
        parsedText ?? AttributedString(message.text)
    }

    private static let markdownCache = NSCache<NSString, NSAttributedString>()

    private func loadParsedText() {
        if parsedText != nil { return }
        let text = message.text
        if let cached = Self.markdownCache.object(forKey: text as NSString) {
            parsedText = AttributedString(cached)
            return
        }
        Task.detached(priority: .userInitiated) {
            let parsed = MessageBubble.parseMarkdown(text)
            let boxed = NSAttributedString(attributedString: parsed)
            Self.markdownCache.setObject(boxed, forKey: text as NSString)
            await MainActor.run { self.parsedText = AttributedString(boxed) }
        }
    }

    private static func parseMarkdown(_ text: String) -> NSAttributedString {
        NSAttributedString((try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text))
    }

    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: AttributedString.MarkdownParsingOptions(
                                   interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Collapsible thinking block (iOS 15: manual expander).
struct ThinkingView: View {
    let text: String
    @State private var expanded = false
    @Environment(\.chatTextScale) private var textScale
    @Environment(\.theme) private var theme

    private func scaled(_ base: CGFloat) -> CGFloat { base * CGFloat(textScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .foregroundColor(.secondary)
            }
            if expanded {
                TerminalText(text: text, color: theme.secondaryText, fontSize: scaled(11))
                    .padding(8)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Tool-call chip with collapsible arguments + focus-mode expand.
struct ToolCallChip: View {
    let call: ToolCall
    var onFocus: () -> Void = {}
    @State private var expanded = false
    @Environment(\.chatTextScale) private var textScale
    @Environment(\.theme) private var theme

    private func scaled(_ base: CGFloat) -> CGFloat { base * CGFloat(textScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "hammer")
                    .font(.system(size: 10))
                Text(call.name)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    onFocus()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
            }
            if expanded && !call.argumentsText.isEmpty {
                TerminalText(text: call.argumentsText, color: theme.secondaryText, fontSize: scaled(11))
                    .lineLimit(8)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { expanded.toggle() }
        }
    }
}

/// Typing indicator while a stream has no text yet.
struct StreamingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever()
                        .delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
        .padding(.vertical, 6)
    }
}

/// Composer: text field + send/stop button + connection hint.
struct ComposerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message…", text: $viewModel.pendingText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    Task { await viewModel.send(viewModel.pendingText) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(viewModel.pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || viewModel.connectionState == .disconnected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(theme.secondaryBackground)
    }
}


/// A queued user prompt held server-side (never vanished, never duplicated).
struct QueuedBubble: View {
    let item: QueueItem
    var onCancel: () -> Void = {}
    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(item.status == "running" ? "sending" : "queued")
                        .font(.caption2.weight(.semibold))
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.orange)
                Text(item.message)
                    .font(.system(size: 17 * CGFloat(textScale)))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.25))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}
