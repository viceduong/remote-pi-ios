import CryptoKit
import Foundation

/// On-disk per-session history snapshot: the last-known message tail and sync
/// cursor. Opening a session renders the cache instantly, then the network
/// refresh merges any delta.
///
/// - File names are a SHA-256 of the session id (stable across launches —
///   `String.hashValue` is randomly seeded per process and never hit).
/// - Writes are skipped when the content signature didn't change, run on the
///   actor (off the main thread) and are atomic.
/// - The directory is pruned to the `maxFiles` most recently written files.
actor SessionHistoryCache {
    static let shared = SessionHistoryCache()
    static let maxFiles = 40
    static let maxMessages = 300

    struct Snapshot: Codable {
        var messages: [ChatMessage]
        var hasMore: Bool
        var cursor: String?
        var savedAt: Date
    }

    private let root: URL
    private var lastSignature: [String: Int] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("RemotePi", isDirectory: true)
            .appendingPathComponent("HistoryCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Stable, filesystem-safe file name for a session id.
    static func fileName(for sessionId: String) -> String {
        let digest = SHA256.hash(data: Data(sessionId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Cheap content signature: identity, cursor and text sizes of the tail.
    static func signature(messages: [ChatMessage], hasMore: Bool, cursor: String?) -> Int {
        var h = Hasher()
        h.combine(hasMore)
        h.combine(cursor)
        h.combine(messages.count)
        for m in messages.suffix(maxMessages) {
            h.combine(m.id)
            h.combine(m.entryId)
            h.combine(m.text.utf8.count)
            h.combine(m.isError)
        }
        return h.finalize()
    }

    private func fileURL(_ sessionId: String) -> URL {
        root.appendingPathComponent(Self.fileName(for: sessionId))
    }

    func load(sessionId: String, maxAge: TimeInterval = 7 * 86400) -> Snapshot? {
        let url = fileURL(sessionId)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard Date().timeIntervalSince(snap.savedAt) < maxAge else { return nil }
        guard !snap.messages.isEmpty else { return nil }
        lastSignature[sessionId] = Self.signature(messages: snap.messages, hasMore: snap.hasMore, cursor: snap.cursor)
        return snap
    }

    func save(sessionId: String, messages: [ChatMessage], hasMore: Bool, cursor: String?) {
        // Bound: the newest rows only — cache is for instant-open, not archival.
        let tail = Array(messages.suffix(Self.maxMessages))
        guard !tail.isEmpty else { return }
        let signature = Self.signature(messages: tail, hasMore: hasMore, cursor: cursor)
        guard lastSignature[sessionId] != signature else { return }
        let snap = Snapshot(messages: tail, hasMore: hasMore, cursor: cursor, savedAt: Date())
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let url = fileURL(sessionId)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            lastSignature[sessionId] = signature
        } catch {
            return
        }
        prune()
    }

    /// Keep only the `maxFiles` most recently written snapshots.
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]),
              files.count > Self.maxFiles else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, date ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxFiles) {
            try? fm.removeItem(at: url)
        }
    }

    func purge(sessionId: String) {
        lastSignature[sessionId] = nil
        try? FileManager.default.removeItem(at: fileURL(sessionId))
    }

    func purgeAll() {
        lastSignature.removeAll()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
