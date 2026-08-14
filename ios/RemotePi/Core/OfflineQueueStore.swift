import CryptoKit
import Foundation

/// Durable per-session outbox storage. Individual session files avoid a single
/// global UserDefaults blob and atomic replacement prevents torn writes.
actor OfflineQueueStore {
    private let fileURL: URL

    init(sessionId: String) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemotePi", isDirectory: true)
            .appendingPathComponent("OfflineQueue", isDirectory: true)
        let digest = SHA256.hash(data: Data(sessionId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.fileURL = root.appendingPathComponent("\(digest).json", isDirectory: false)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func load() -> [OfflineMessage]? {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([OfflineMessage].self, from: data) else {
            return nil
        }
        return Array(items.prefix(100))
    }

    func save(_ items: [OfflineMessage]) {
        guard let data = try? JSONEncoder().encode(Array(items.prefix(100))) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
