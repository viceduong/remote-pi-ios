import XCTest
import SwiftUI
@testable import RemotePi

/// Visual review snapshots (PNG → `$SIMULATOR_HOST_HOME/remotepi-snapshots`,
/// uploaded by CI) for the §12 new-session sheet and its folder browser.
/// State is seeded through a stub service — no network.
@MainActor
final class NewSessionSnapshotTests: XCTestCase {
    private static let themes: [(String, AppTheme)] = [("dark", AppTheme.darkGrey), ("light", AppTheme.light)]

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    private static let roots = DirRoots(
        roots: ["D:\\"],
        recent: [
            RecentDir(path: "D:\\ai-ching", lastUsedAt: nowMs - 120_000, sessions: 14),
            RecentDir(path: "D:\\projects\\weather-dashboard", lastUsedAt: nowMs - 86_400_000, sessions: 3),
            RecentDir(path: "D:\\work\\clients\\acme\\billing-service", lastUsedAt: nowMs - 3 * 86_400_000,
                      sessions: 1),
        ],
        defaultDir: "D:\\ai-ching")

    private static let aiChing = DirListing(
        path: "D:\\ai-ching", parent: "D:\\",
        entries: ["builds", "cli", "docs", "ios", "server", "tools"].map {
            DirEntry(name: $0, path: "D:\\ai-ching\\\($0)")
        })

    private func makeStub() -> StubWorkdirService {
        let stub = StubWorkdirService(roots: Self.roots)
        stub.listings["d:\\ai-ching"] = Self.aiChing
        return stub
    }

    func testNewSessionSheetWithRecentAndWillCreate() {
        for (name, theme) in Self.themes {
            let stub = makeStub()
            let model = NewSessionModel(api: stub,
                                        memory: WorkdirMemory(serverKey: "snapshot", defaults: freshDefaults()),
                                        debounceNanos: 0)
            model.seedForTesting(roots: Self.roots, path: "D:\\projects\\new-app",
                                 status: .willCreate, name: "New app")
            XCTAssertEqual(model.status, .willCreate)
            XCTAssertEqual(model.status.text, "Will be created")
            XCTAssertTrue(model.canCreate)
            XCTAssertEqual(model.recent.map(\.name), ["ai-ching", "weather-dashboard", "billing-service"])

            snapshot(NewSessionSheet(model: model, theme: theme, onCreated: { _ in }),
                     name: "new-session-sheet-\(name)", settle: 1.0)
            XCTAssertEqual(model.status, .willCreate, "appearing must not reload seeded state")
            XCTAssertTrue(stub.createCalls.isEmpty)
        }
    }

    func testNewSessionSheetNotAllowed() {
        let theme = AppTheme.darkGrey
        let model = NewSessionModel(api: makeStub(),
                                    memory: WorkdirMemory(serverKey: "snapshot", defaults: freshDefaults()),
                                    debounceNanos: 0)
        model.seedForTesting(roots: Self.roots, path: "C:\\Windows\\Temp",
                             status: .notAllowed(roots: ["D:\\"]))
        XCTAssertFalse(model.canCreate)
        snapshot(NewSessionSheet(model: model, theme: theme, onCreated: { _ in }),
                 name: "new-session-sheet-not-allowed-dark", settle: 1.0)
    }

    func testFolderBrowserList() {
        for (name, theme) in Self.themes {
            let model = FolderBrowserModel(api: makeStub(), roots: Self.roots.roots, start: "D:\\ai-ching")
            model.seedForTesting(Self.aiChing)
            XCTAssertEqual(model.title, "ai-ching")
            XCTAssertEqual(model.upDestination ?? nil, "D:\\")
            XCTAssertTrue(model.canUse)

            let view = NavigationView {
                FolderBrowserView(model: model, onPick: { _ in })
            }
            .navigationViewStyle(.stack)
            .environment(\.theme, theme)
            .preferredColorScheme(theme.scheme)
            snapshot(view, name: "folder-browser-\(name)", settle: 1.0)
            XCTAssertEqual(model.listing?.entries.count, 6, "appearing must not reload seeded state")
        }
    }
}
