import XCTest
import SwiftUI
@testable import RemotePi

/// Visual review snapshots (PNG → `$SIMULATOR_HOST_HOME/remotepi-snapshots`,
/// uploaded by CI) for contract §16: the status line with the Background
/// button, the background-shells sheet and the output viewer. All state is
/// seeded through `StubShellService` — no network.
@MainActor
final class BackgroundShellsSnapshotTests: XCTestCase {
    private static let themes: [(String, AppTheme)] = [("dark", AppTheme.darkGrey), ("light", AppTheme.light)]

    private static var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private static func seededShells() -> [BackgroundShell] {
        let now = nowMs
        return [
            BackgroundShell(id: "bg-0000000a", command: "npm run dev -- --host 0.0.0.0 --port 5173",
                            status: .running, pid: 4242, startTime: now - 185_000, outputBytes: 18_400),
            BackgroundShell(id: "bg-0000000b",
                            command: "pytest -x tests/integration/test_sessions.py::test_background_shells --maxfail=1 -q",
                            status: .running, pid: 4310, startTime: now - 42_000, outputBytes: 2_100),
            BackgroundShell(id: "bg-0000000c", command: "cargo build --release", status: .completed, pid: 3999,
                            startTime: now - 3_700_000, endTime: now - 3_610_000, exitCode: 0,
                            durationMs: 90_000, outputBytes: 50_000),
            BackgroundShell(id: "bg-0000000d", command: "npm test", status: .failed, pid: 3800,
                            startTime: now - 7_300_000, endTime: now - 7_288_000, exitCode: 1,
                            durationMs: 12_000, outputBytes: 4_000),
            BackgroundShell(id: "bg-0000000e", command: "tail -f /var/log/system.log", status: .killed, pid: 3700,
                            startTime: now - 90_000_000, endTime: now - 89_000_000, exitCode: 137),
        ]
    }

    private static let ansiOutput = """
    \u{1B}[1m> remote-pi@5.20 dev\u{1B}[0m
    \u{1B}[2m> vite --host 0.0.0.0 --port 5173\u{1B}[0m

      \u{1B}[32m\u{1B}[1mVITE\u{1B}[22m v5.4.2\u{1B}[39m  ready in \u{1B}[1m412\u{1B}[22m ms

      \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m
      \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mNetwork\u{1B}[22m: \u{1B}[36mhttp://192.168.1.20:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m
    \u{1B}[33m[warn]\u{1B}[0m Port 24678 is in use, trying another one…
    \u{1B}[31m✗\u{1B}[0m src/App.tsx:12:7 \u{1B}[31mType 'string' is not assignable to type 'number'.\u{1B}[0m
    \u{1B}[38;5;244m12:41:07\u{1B}[0m \u{1B}[38;2;120;180;255m[hmr]\u{1B}[0m update /src/App.tsx
    \u{1B}[38;5;244m12:41:09\u{1B}[0m \u{1B}[38;2;120;180;255m[hmr]\u{1B}[0m update /src/components/ShellList.tsx
    """

    private func seededModel(_ list: [BackgroundShell]? = nil,
                             state: BackgroundShellsModel.ListState = .loaded) -> (BackgroundShellsModel, StubShellService) {
        let shells = list ?? Self.seededShells()
        let stub = StubShellService(shells: shells)
        let model = BackgroundShellsModel(service: stub, sessionId: "snapshot-shells")
        model.seedForTesting(shells, state: state)
        return (model, stub)
    }

    // MARK: Status line with the Background button

    private func frame(_ json: String) -> ParsedSSEFrame {
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: "agent_status", id: "e-1", payload: payload)
    }

    func testStatusLineWithBackgroundButton() {
        for (name, theme) in Self.themes {
            let vm = ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "snapshot"),
                                   sessionId: "snapshot-bg", initialModel: "anthropic/claude-sonnet-4-5")
            let (shells, stub) = seededModel()
            let now = Self.nowMs
            vm.ingestForTesting([frame(#"{"type":"agent_status","phase":"streaming","busy":true,"owner":"bridge","activity":{"kind":"tool","tool":"bash","since":\#(now - 20_000),"busySince":\#(now - 65_000)},"questionId":null}"#)])
            XCTAssertEqual(vm.status.workingText, "Running bash")
            XCTAssertTrue(BackgroundBashRule.isVisible(kind: vm.status.activityKind, tool: vm.status.activityTool))

            let bar = VStack(spacing: 0) {
                Spacer(minLength: 0)
                ChatBottomBar(viewModel: vm, status: vm.status, shells: shells)
            }
            .background(theme.background.ignoresSafeArea())
            .environment(\.theme, theme)
            .preferredColorScheme(theme.scheme)
            snapshot(bar, name: "status-line-background-\(name)", size: CGSize(width: 390, height: 300))

            // With a 502 notice above the banner.
            shells.show(.error, "Ctrl+B isn't available in this pi — reload the TUI")
            snapshot(bar, name: "status-line-background-notice-\(name)", size: CGSize(width: 390, height: 300))

            // Another tool: no Background button.
            vm.ingestForTesting([frame(#"{"type":"agent_status","phase":"streaming","busy":true,"owner":"bridge","activity":{"kind":"tool","tool":"read","since":\#(now),"busySince":\#(now - 65_000)},"questionId":null}"#)])
            XCTAssertFalse(BackgroundBashRule.isVisible(kind: vm.status.activityKind, tool: vm.status.activityTool))
            XCTAssertEqual(stub.backgroundCalls, 0, "rendering never calls the server")
            shells.teardown()
            vm.stop()
        }
    }

    // MARK: Shells sheet

    func testShellsSheet() {
        for (name, theme) in Self.themes {
            let (model, stub) = seededModel()
            XCTAssertEqual(model.runningCount, 2)
            XCTAssertEqual(model.shells.map(\.id), ["bg-0000000b", "bg-0000000a", "bg-0000000c",
                                                    "bg-0000000d", "bg-0000000e"])
            snapshot(BackgroundShellsSheet(model: model, theme: theme, refreshOnAppear: false),
                     name: "background-shells-\(name)", settle: 1.0)
            XCTAssertEqual(stub.listCalls, 0, "seeded sheet must not refetch")
        }
    }

    func testShellsSheetEmptyAndErrorStates() {
        for (name, theme) in Self.themes {
            let (empty, _) = seededModel([])
            snapshot(BackgroundShellsSheet(model: empty, theme: theme, refreshOnAppear: false),
                     name: "background-shells-empty-\(name)", settle: 0.8)

            let (failed, _) = seededModel([], state: .failed("Cannot reach server"))
            snapshot(BackgroundShellsSheet(model: failed, theme: theme, refreshOnAppear: false),
                     name: "background-shells-error-\(name)", settle: 0.8)
        }
    }

    func testChatMenuBadge() {
        for (name, theme) in Self.themes {
            let (model, _) = seededModel()
            let view = HStack(spacing: 12) {
                ChatActionsMenu(shells: model, workdir: "/Users/pi/projects/remote-pi",
                                onFork: {}, onShowShells: {})
            }
            .font(.title3)
            .foregroundColor(theme.accent)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .environment(\.theme, theme)
            .preferredColorScheme(theme.scheme)
            snapshot(view, name: "chat-menu-shells-badge-\(name)", size: CGSize(width: 200, height: 100))
        }
    }

    // MARK: Output viewer

    func testOutputViewerRunning() {
        for (name, theme) in Self.themes {
            let (model, stub) = seededModel()
            let output = ShellOutputModel(shellId: "bg-0000000a", shells: model)
            output.seedForTesting(ShellOutput(text: Self.ansiOutput, truncated: true, size: 1_258_291),
                                  state: .loaded)
            let view = NavigationView {
                ShellOutputView(shells: model, shellId: "bg-0000000a", theme: theme,
                                seeded: output, autoRefresh: false)
            }
            .navigationViewStyle(.stack)
            .environment(\.theme, theme)
            .preferredColorScheme(theme.scheme)
            snapshot(view, name: "shell-output-running-\(name)", settle: 1.0)
            XCTAssertEqual(stub.outputCalls, 0, "seeded viewer must not fetch")
        }
    }

    func testOutputViewerFinishedAndError() {
        let theme = AppTheme.darkGrey
        let (model, _) = seededModel()

        let finished = ShellOutputModel(shellId: "bg-0000000d", shells: model)
        finished.seedForTesting(ShellOutput(text: "\u{1B}[31mFAIL\u{1B}[0m src/parser.test.ts\n  ✕ parses frames (12 ms)\n\nTests: 1 failed, 41 passed\n",
                                            truncated: false, size: 96), state: .loaded)
        snapshot(NavigationView {
            ShellOutputView(shells: model, shellId: "bg-0000000d", theme: theme, seeded: finished, autoRefresh: false)
        }
        .navigationViewStyle(.stack)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme),
                 name: "shell-output-finished-dark", settle: 1.0)

        let failed = ShellOutputModel(shellId: "bg-0000000c", shells: model)
        failed.seedForTesting(nil, state: .failed("Server error 404: unknown shell"))
        snapshot(NavigationView {
            ShellOutputView(shells: model, shellId: "bg-0000000c", theme: theme, seeded: failed, autoRefresh: false)
        }
        .navigationViewStyle(.stack)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.scheme),
                 name: "shell-output-error-dark", settle: 0.8)
    }
}
