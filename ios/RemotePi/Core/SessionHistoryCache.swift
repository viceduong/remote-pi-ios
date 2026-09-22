import Foundation

/// On-disk per-session history snapshot: the last-known message page, queue
/// items and sync cursor. Opening a session renders the cache INSTANTLY
/// (dim lifts immediately), then the network refresh merges any delta.
/// Written after every successful load/refresh; bounded and atomic.
actor SessionHistoryCache {
    static let shared = SessionHistoryCache()

    struct Snapshot: Codable {
        var messages: [ChatMessage]
        var hasMore: Bool
        var cursor: String?
        var savedAt: Date
    }

    private let root: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userMask)[0]
        root = base.appendingPathComponent("RemotePi", isDirectory: true)
            .appendingPathComponent("HistoryCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fileURL(_ sessionId: String) -> URL {
        // Session ids are alnum+dashes; still hash to be safe.
        let digest = sessionId.hashValue.description
        return root.appendingPathComponent("\(digest).json")
    }

    func load(sessionId: String, maxAge: TimeInterval = 7 * 86400) -> Snapshot? {
        let url = fileURL(sessionId)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard Date().timeIntervalSince(snap.savedAt) < maxAge else { return nil }
        guard !snap.messages.isEmpty else { return nil }
        return snap
    }

    func save(sessionId: String, messages: [ChatMessage], hasMore: Bool, cursor: String?) {
        // Bound: keep the newest 300 messages (the rendered tail) — cache is
        // for instant-open, not archival.
        let tail = Array(messages.suffix(300))
        guard !tail.isEmpty else { return }
        let snap = Snapshot(messages: tail, hasMore: hasMore, cursor: cursor, savedAt: Date())
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let url = fileURL(sessionId)
        let tmp = url.appendingPathExtension("tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic, .completeFileProtection])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    func purge(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(sessionId))
    }

    func purgeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
