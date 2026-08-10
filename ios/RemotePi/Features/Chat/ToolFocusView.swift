import SwiftUI

/// What the tool focus view shows.
enum ToolFocusItem: Identifiable {
    /// A tool call (assistant-side block): full arguments.
    case call(name: String, arguments: String)
    /// A tool result message: full output.
    case result(ChatMessage)

    var id: String {
        switch self {
        case .call(let name, let args): return "call-\(name)-\(args)"
        case .result(let m): return "result-\(m.toolName ?? "tool")-\(m.id)"
        }
    }
}

/// Full-screen, terminal-style focus view for a tool call or result.
/// Mirrors pi's "focus" on a tool execution: monospace, dark, maximal content.
struct ToolFocusView: View {
    let item: ToolFocusItem
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch item {
        case .call(let name, _): return "⚙️ \(name)"
        case .result(let m): return "⚙️ \(m.toolName ?? "tool")"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch item {
                    case .call(let name, let args):
                        HStack(spacing: 8) {
                            Image(systemName: "hammer.fill")
                                .foregroundColor(.orange)
                            Text(name)
                                .font(.headline)
                            Spacer()
                        }
                        if !args.isEmpty {
                            section("Arguments", text: args)
                        }
                    case .result(let m):
                        HStack(spacing: 8) {
                            Image(systemName: m.isError ? "exclamationmark.triangle.fill" : "hammer.fill")
                                .foregroundColor(m.isError ? .red : .orange)
                            Text(m.toolName ?? "tool")
                                .font(.headline)
                            if m.isError {
                                Text("failed")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.25))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        if !m.text.isEmpty {
                            section("Output", text: m.text)
                        } else {
                            ProgressView("running…")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
            .background(theme.terminalBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private func section(_ heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            TerminalText(text: text, color: theme.terminalText, fontSize: 12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(theme.terminalBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
