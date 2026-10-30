import XCTest
import SwiftUI
@testable import RemotePi

/// Visual review snapshots (PNG → `$SIMULATOR_HOST_HOME/remotepi-snapshots`,
/// uploaded by CI) for Settings → Notifications (§14). State is seeded
/// through a stub service — no network.
@MainActor
final class NotificationSettingsSnapshotTests: XCTestCase {
    private static let themes: [(String, AppTheme)] = [("dark", AppTheme.darkGrey), ("light", AppTheme.light)]

    private static let configured = NotifySettings(
        enabled: true, barkServer: "https://api.day.app", hasDeviceKey: true,
        encryption: .init(enabled: true, algorithm: "AES256", mode: "CBC", hasKey: false),
        level: "timeSensitive")

    private func host<V: View>(_ view: V, theme: AppTheme) -> some View {
        NavigationView { view }
            .navigationViewStyle(.stack)
            .environment(\.theme, theme)
            .preferredColorScheme(theme.scheme)
    }

    func testNotificationSettingsConfigured() {
        for (name, theme) in Self.themes {
            let stub = StubNotifyService(settings: Self.configured)
            let model = NotificationSettingsModel(service: stub)
            var draft = NotifyDraft(settings: Self.configured)
            draft.key = String(repeating: "k", count: 20)   // shows a length error
            model.seedForTesting(Self.configured, draft: draft, testOutcome: .sent)
            XCTAssertEqual(model.issues.key, "AES-256 needs a 32-character key (entered 20)")
            XCTAssertFalse(model.canSave)

            snapshot(host(NotificationSettingsView(model: model, serverName: "pi-host"), theme: theme),
                     name: "notification-settings-\(name)", size: CGSize(width: 390, height: 1500), settle: 1.0)
            XCTAssertEqual(stub.getCalls, 0, "appearing must not reload seeded state")
        }
    }

    func testNotificationSettingsUnsupportedServer() {
        let model = NotificationSettingsModel(service: StubNotifyService())
        model.seedForTesting(state: .unsupported)
        snapshot(host(NotificationSettingsView(model: model, serverName: "old-pi"), theme: .darkGrey),
                 name: "notification-settings-unsupported-dark", settle: 1.0)
        XCTAssertEqual(model.state, .unsupported)
    }
}
