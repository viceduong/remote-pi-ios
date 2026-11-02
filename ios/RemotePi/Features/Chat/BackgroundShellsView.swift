import SwiftUI
import UIKit

// MARK: - Status line: "Background" (Ctrl+B) button + notice

/// Capsule button in the working banner while the agent runs `bash`
/// (contract §16): detaches the running command like Ctrl+B in the TUI.
@MainActor
struct BackgroundBashButton: View {
    @ObservedObject var model: BackgroundShellsModel
    @Environment(\.theme) private var theme

    var body: some View {
        if model.supported != false {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                _ = model.requestBackground()
            } label: {
                HStack(spacing: 4) {
                    if model.isBackgrounding {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            .tint(theme.accent)
                    } else {
                        Image(systemName: "arrow.down.right.square")
                            .font(.caption2.weight(.semibold))
                    }
                    Text("Background")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundColor(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.accent.opacity(model.isBackgrounding ? 0.08 : 0.16))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(model.isBackgrounding)
            .accessibilityLabel("Move to background")
            .accessibilityHint("Keeps the running bash command going in the background, like Ctrl+B in the terminal")
        }
    }
}

/// Transient result of a Background tap ("Nothing running", the server's
/// 502 message …). Auto-hides; tap ✕ to dismiss early.
@MainActor
struct BackgroundNoticeBanner: View {
    @ObservedObject var model: BackgroundShellsModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: symbol(notice.kind))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(tint(notice.kind))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(notice.text)
                        .font(.caption)
                        .foregroundColor(theme.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.dismissNotice()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(theme.secondaryText)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(tint(notice.kind).opacity(0.14))
                .transition(.opacity)
                .accessibilityElement(children: .contain)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }

    private func symbol(_ kind: BackgroundShellsModel.Notice.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func tint(_ kind: BackgroundShellsModel.Notice.Kind) -> Color {
        switch kind {
        case .info: return theme.accent
        case .success: return .green
        case .error: return .orange
        }
    }
}

// MARK: - Chat ⋯ menu (with the running-shells badge)

/// The chat toolbar's ⋯ menu. Observes only the shells model, so a badge
/// change re-renders just this control.
@MainActor
struct ChatActionsMenu: View {
    @ObservedObject var shells: BackgroundShellsModel
    let workdir: String?
    let onFork: @MainActor () -> Void
    let onShowShells: @MainActor () -> Void

    var body: some View {
        let running = shells.showsMenuEntry ? shells.runningCount : 0
        Menu {
            Button {
                onFork()
            } label: {
                Label("Fork at latest message", systemImage: "arrow.branch")
            }
            if let workdir, !workdir.isEmpty {
                Button {
                    UIPasteboard.general.string = workdir
                } label: {
                    Label("Copy folder path", systemImage: "doc.on.doc")
                }
            }
            if shells.showsMenuEntry {
                Button {
                    onShowShells()
                } label: {
                    Label(ShellMenuText.title(running: running), systemImage: "terminal")
                }
            }
        } label: {
            ShellBadgeIcon(count: running)
        }
        .accessibilityLabel(ShellMenuText.accessibility(running: running))
    }
}

enum ShellMenuText {
    static func title(running: Int) -> String {
        running > 0 ? "Background shells (\(running) running)" : "Background shells"
    }

    static func accessibility(running: Int) -> String {
        switch running {
        case 0: return "More actions"
        case 1: return "More actions, 1 background shell running"
        default: return "More actions, \(running) background shells running"
        }
    }

    static func badge(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }
}

/// ⋯ icon with a small green count badge.
struct ShellBadgeIcon: View {
    let count: Int

    var body: some View {
        Image(systemName: "ellipsis.circle")
            .overlay(alignment: .topTrailing) {
                if let text = ShellMenuText.badge(count) {
                    Text(text)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.green))
                        .offset(x: 8, y: -7)
                        .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - Shared status styling

enum ShellStyle {
    static func color(_ shell: BackgroundShell, accent: Color) -> Color {
        switch shell.status {
        case .running: return accent
        case .completed:
            if let code = shell.exitCode, code != 0 { return .red }
            return .green
        case .failed: return .red
        case .killed: return .orange
        case .unknown: return .secondary
        }
    }

    static func symbol(_ shell: BackgroundShell) -> String {
        if case .completed = shell.status, let code = shell.exitCode, code != 0 {
            return "exclamationmark.circle.fill"
        }
        return shell.status.symbolName
    }

    static var outputFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
    }
}

// MARK: - Shells sheet

@MainActor
struct BackgroundShellsSheet: View {
    @ObservedObject var model: BackgroundShellsModel
    let theme: AppTheme
    /// Snapshot tests seed the model and skip the appear-refresh.
    var refreshOnAppear = true
    @Environment(\.dismiss) private var dismiss
    @State private var pendingKill: BackgroundShell?

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Background shells")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme)
        .task {
            if refreshOnAppear { await model.refresh() }
        }
        .alert("Background shells", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })
    }

    private var killBinding: Binding<Bool> {
        Binding(get: { pendingKill != nil },
                set: { if !$0 { pendingKill = nil } })
    }

    private var content: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            stateView
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if model.shells.isEmpty {
            switch model.listState {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading shells…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            case .failed(let message):
                messageList(symbol: "exclamationmark.triangle", tint: .orange,
                            title: "Couldn't load shells", detail: message, retry: true)
            case .unsupported:
                messageList(symbol: "exclamationmark.triangle", tint: .secondary,
                            title: "Not supported",
                            detail: "This server doesn't support background shells yet. Update the Remote Pi server.",
                            retry: false)
            case .loaded:
                messageList(symbol: "terminal", tint: .secondary,
                            title: "No background shells",
                            detail: "While the agent runs a bash command, tap Background in the status line (like Ctrl+B in the terminal) to keep it running here.",
                            retry: false)
            }
        } else {
            shellList
        }
    }

    private func messageList(symbol: String, tint: Color, title: String, detail: String,
                             retry: Bool) -> some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.largeTitle)
                        .foregroundColor(tint)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if retry {
                        Button("Retry") { Task { await model.refresh() } }
                            .font(.body.weight(.semibold))
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }

    private var shellList: some View {
        let running = model.shells.filter { $0.isRunning }
        let finished = model.shells.filter { !$0.isRunning }
        return List {
            if case .failed(let message) = model.listState {
                Section {
                    Label("Couldn't refresh: \(message)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            if !running.isEmpty {
                Section(header: Text("Running")) {
                    ForEach(running) { row($0) }
                }
            }
            if !finished.isEmpty {
                Section(header: Text("Finished"),
                        footer: running.isEmpty ? nil : Text("Swipe a running shell to kill it.")) {
                    ForEach(finished) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .confirmationDialog("Kill this shell?", isPresented: killBinding, titleVisibility: .visible,
                            presenting: pendingKill) { shell in
            Button("Kill", role: .destructive) { _ = model.kill(shell.id) }
            Button("Cancel", role: .cancel) {}
        } message: { shell in
            Text(shell.command.isEmpty ? shell.id : shell.command)
        }
    }

    private func row(_ shell: BackgroundShell) -> some View {
        NavigationLink(destination: ShellOutputView(shells: model, shellId: shell.id, theme: theme)) {
            ShellRow(shell: shell, killing: model.killing.contains(shell.id))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if shell.isRunning {
                Button {
                    pendingKill = shell
                } label: {
                    Label("Kill", systemImage: "xmark.octagon")
                }
                .tint(.red)
            }
        }
    }
}

struct ShellRow: View {
    let shell: BackgroundShell
    let killing: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ShellStyle.symbol(shell))
                .font(.body)
                .foregroundColor(ShellStyle.color(shell, accent: theme.accent))
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(shell.command.isEmpty ? shell.id : shell.command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                ShellSubtitle(shell: shell)
            }
            Spacer(minLength: 0)
            if killing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "Running · started 3m ago · 3m 05s" — ticks every second while running.
struct ShellSubtitle: View {
    let shell: BackgroundShell

    var body: some View {
        if shell.isRunning {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                text(now: context.date)
            }
        } else {
            text(now: Date())
        }
    }

    private func text(now: Date) -> some View {
        Text(ShellFormat.subtitle(shell, now: now))
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Output viewer

@MainActor
struct ShellOutputView: View {
    @ObservedObject var shells: BackgroundShellsModel
    @StateObject private var model: ShellOutputModel
    let theme: AppTheme
    private let autoRefresh: Bool
    @State private var confirmKill = false
    @State private var copied = false

    init(shells: BackgroundShellsModel, shellId: String, theme: AppTheme,
         seeded: ShellOutputModel? = nil, autoRefresh: Bool = true) {
        _shells = ObservedObject(wrappedValue: shells)
        _model = StateObject(wrappedValue: seeded ?? ShellOutputModel(shellId: shellId, shells: shells))
        self.theme = theme
        self.autoRefresh = autoRefresh
    }

    private var shell: BackgroundShell? { shells.shell(id: model.shellId) }

    private var displayText: String {
        ShellOutputText.normalize(model.output?.text ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            outputArea
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .navigationTitle("Output")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(displayText.isEmpty)
                .accessibilityLabel(copied ? "Copied" : "Copy output")
                if shell?.isRunning == true {
                    Button {
                        confirmKill = true
                    } label: {
                        Text("Kill").foregroundColor(.red)
                    }
                    .disabled(shells.killing.contains(model.shellId))
                    .accessibilityLabel("Kill shell")
                }
            }
        }
        .task {
            if autoRefresh { await model.run() }
        }
        .confirmationDialog("Kill this shell?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Kill", role: .destructive) { _ = shells.kill(model.shellId) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(shell?.command ?? model.shellId)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shell.map { $0.command.isEmpty ? $0.id : $0.command } ?? model.shellId)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(4)
                .textSelection(.enabled)
            if let shell {
                HStack(spacing: 6) {
                    Image(systemName: ShellStyle.symbol(shell))
                        .font(.caption)
                        .foregroundColor(ShellStyle.color(shell, accent: theme.accent))
                        .accessibilityHidden(true)
                    ShellSubtitle(shell: shell)
                    Spacer(minLength: 0)
                    if shell.isRunning {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green))
                            .accessibilityLabel("Refreshing live")
                    }
                }
            }
            if let output = model.output, output.truncated {
                Text(truncationNote(output))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func truncationNote(_ output: ShellOutput) -> String {
        let shown = ShellFormat.bytes(BackgroundShellsModel.outputTail)
        if let size = output.size, size > 0 {
            return "Showing the last \(shown) of \(ShellFormat.bytes(size))"
        }
        return "Showing the last \(shown)"
    }

    @ViewBuilder
    private var outputArea: some View {
        if model.output == nil {
            switch model.state {
            case .loading, .loaded:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading output")
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text("Couldn't load the output")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await model.load() } }
                        .font(.body.weight(.semibold))
                        .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if displayText.isEmpty {
            Text(shell?.isRunning == true ? "No output yet…" : "No output")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ANSIOutputTextView(text: displayText,
                               font: ShellStyle.outputFont,
                               textColor: UIColor(theme.text),
                               background: UIColor(theme.surface))
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityLabel("Shell output")
        }
    }

    private func copy() {
        UIPasteboard.general.string = ShellOutputText.stripANSI(displayText)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// Read-only, selectable UITextView rendering ANSI colours. Follows the
/// tail (scrolls to the bottom on new output) unless the user scrolled up.
struct ANSIOutputTextView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: UIColor
    let background: UIColor

    /// Distance from the bottom that still counts as "following".
    static let followSlack: CGFloat = 48

    final class Coordinator {
        var renderedText: String?
        var renderedColor: UIColor?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 24, right: 8)
        view.backgroundColor = background
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.backgroundColor != background { view.backgroundColor = background }
        let coordinator = context.coordinator
        guard coordinator.renderedText != text || coordinator.renderedColor != textColor else { return }
        let firstRender = coordinator.renderedText == nil
        let visibleBottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
        let nearBottom = visibleBottom >= view.contentSize.height - Self.followSlack
        let follow = firstRender || nearBottom
        coordinator.renderedText = text
        coordinator.renderedColor = textColor
        let savedOffset = view.contentOffset
        view.attributedText = ANSIParser.attributed(text, baseFont: font, baseColor: textColor)
        if follow {
            // Layout settles after this update pass (first render: bounds).
            Task { @MainActor [weak view] in
                guard let view else { return }
                view.layoutIfNeeded()
                let insets = view.adjustedContentInset
                let maxY = view.contentSize.height - view.bounds.height + insets.bottom
                view.setContentOffset(CGPoint(x: 0, y: max(-insets.top, maxY)), animated: false)
            }
        } else {
            view.setContentOffset(savedOffset, animated: false)
        }
    }
}
