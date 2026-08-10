import SwiftUI

@main
@MainActor
struct RemotePiApp: App {
    @StateObject private var serverStore = ServerStore()
    @AppStorage("themeName") private var themeName = "darkGrey"

    var body: some Scene {
        WindowGroup {
            NavigationView {
                ServerListView()
                    .navigationTitle("Remote Pi")
            }
            .navigationViewStyle(.stack)
            .environmentObject(serverStore)
            .environment(\.theme, AppTheme.named(themeName))
            .preferredColorScheme(AppTheme.named(themeName).scheme)
            .onAppear { applyNavBarTheme(AppTheme.named(themeName)) }
            .onChange(of: themeName) { _ in applyNavBarTheme(AppTheme.named(themeName)) }
        }
    }

    /// iOS 15 scroll-edge nav bars are transparent at the top — force an
    /// always-opaque bar matching the active theme.
    private func applyNavBarTheme(_ theme: AppTheme) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(theme.background)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(theme.text)]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor(theme.text)]
        // Hairline under the header so it doesn't blend into the content.
        appearance.shadowColor = UIColor(theme.border)
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.tintColor = UIColor(theme.accent)

        // iOS 15 List keeps the system grouped background (pure black) unless
        // the table view is themed — match it to the palette so the main page
        // doesn't show a mismatched panel.
        let table = UITableView.appearance()
        table.backgroundColor = UIColor(theme.background)
        table.separatorColor = UIColor(theme.border)
        UITableViewCell.appearance().backgroundColor = .clear
    }
}
