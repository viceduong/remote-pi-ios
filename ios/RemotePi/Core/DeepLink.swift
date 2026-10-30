import Foundation
import SwiftUI

/// App URLs (`remotepi://…`, scheme registered in project.yml). Contract §14:
/// a Bark turn-end notification carries `remotepi://session/<sessionId>`.
enum DeepLink: Equatable {
    /// Bare `remotepi://` (the server's test push) — just bring the app up.
    case home
    case session(id: String)

    static let scheme = "remotepi"

    /// `remotepi://session/<id>` (also `remotepi:///session/<id>`);
    /// query/fragment ignored. Bare `remotepi://` → `.home`. nil for anything
    /// else, including ids the server would reject.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        var parts: [String] = []
        if let host = url.host, !host.isEmpty { parts.append(host) }
        parts += url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if parts.isEmpty { return .home }
        guard parts.count == 2, parts[0].lowercased() == "session" else { return nil }
        let id = parts[1]
        guard isValidSessionId(id) else { return nil }
        return .session(id: id)
    }

    private static let idAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")

    /// Mirrors the server's `^[0-9A-Za-z_.-]{1,128}$`; dot-only ids are
    /// refused so they can't turn into `/api/sessions/..`.
    static func isValidSessionId(_ id: String) -> Bool {
        guard (1...128).contains(id.unicodeScalars.count),
              id.unicodeScalars.allSatisfy({ idAllowed.contains($0) }) else { return false }
        return !id.allSatisfy { $0 == "." }
    }
}

/// Hands a deep link from `.onOpenURL` (app root) to the navigation stack:
/// `ServerListView` resolves `pendingSessionId` against the selected server
/// and `SessionListView` (for that server) pushes the chat from
/// `openRequest`. Kept as published state, so a link that arrives before the
/// views subscribe (cold launch) is not lost. Only touched from the main
/// thread (SwiftUI callbacks); not `@MainActor` so the shared instance can be
/// a plain property default in views.
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    struct OpenRequest: Equatable {
        let id = UUID()
        let serverId: String
        let session: SessionSummary
    }

    struct Banner: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// A session id from a link, waiting to be resolved against a server.
    @Published var pendingSessionId: String?
    /// A resolved session for `SessionListView(server.id == serverId)` to open.
    @Published var openRequest: OpenRequest?
    @Published var banner: Banner?

    func handle(_ url: URL) {
        guard let link = DeepLink.parse(url) else {
            show("Can't open this link: \(url.absoluteString)", isError: true)
            return
        }
        switch link {
        case .home:
            break
        case .session(let id):
            banner = nil
            pendingSessionId = id
        }
    }

    func show(_ text: String, isError: Bool) {
        banner = Banner(text: text, isError: isError)
    }

    func dismissBanner() {
        banner = nil
    }
}

/// Top-of-screen banner for deep-link progress / errors. Errors auto-hide
/// after a few seconds; tap to dismiss.
struct DeepLinkBannerView: View {
    @ObservedObject var router: DeepLinkRouter

    var body: some View {
        Group {
            if let banner = router.banner {
                HStack(alignment: .top, spacing: 10) {
                    if banner.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(banner.text)
                        .font(.footnote)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                        .shadow(color: Color.black.opacity(0.25), radius: 8, y: 2)
                )
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture { router.dismissBanner() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Dismiss")
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    guard banner.isError else { return }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled, router.banner?.id == banner.id else { return }
                    withAnimation { router.dismissBanner() }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: router.banner)
    }
}
