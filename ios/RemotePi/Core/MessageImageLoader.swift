import UIKit

/// Fetches the raw bytes for one message image. The app wires `APIClient` in;
/// tests can stub it.
protocol MessageImageFetching: Sendable {
    func imageData(_ sessionId: String, entryId: String, index: Int) async throws -> Data
}

extension APIClient: MessageImageFetching {}

/// Lazily loads and caches user-message image thumbnails.
///
/// Images are fetched once per stable key ("sessionId/entryId/index"),
/// decoded off the main thread and cached in-memory (`NSCache`, so memory
/// pressure can evict them). Concurrent requests for the same key share one
/// fetch (dedupe) — a fast scroll never fires N requests for one visible row.
///
/// `@MainActor` so the cache bookkeeping and the UIImage hand-off need no
/// extra hops; the network + decode happen inside a detached task.
@MainActor
final class MessageImageLoader {
    private let fetcher: MessageImageFetching
    private let sessionId: String
    private let cache = NSCache<NSString, UIImage>()
    /// In-flight fetches, keyed the same as the cache, so concurrent callers
    /// await the same task instead of issuing duplicate requests.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(fetcher: MessageImageFetching, sessionId: String) {
        self.fetcher = fetcher
        self.sessionId = sessionId
        cache.countLimit = 120
    }

    static func key(entryId: String, index: Int) -> String {
        "\(entryId)/\(index)"
    }

    /// Cached image for this key, if already loaded (no fetch).
    func cachedImage(entryId: String, index: Int) -> UIImage? {
        cache.object(forKey: Self.cacheKey(entryId: entryId, index: index))
    }

    private static func cacheKey(entryId: String, index: Int) -> NSString {
        key(entryId: entryId, index: index) as NSString
    }

    /// Returns the image for (entryId, index), fetching + decoding + caching
    /// on first request. Returns nil on failure (the caller keeps the
    /// placeholder). Concurrent callers for the same key share one fetch.
    func image(entryId: String, index: Int) async -> UIImage? {
        let nsKey = Self.cacheKey(entryId: entryId, index: index)
        if let cached = cache.object(forKey: nsKey) { return cached }
        let key = Self.key(entryId: entryId, index: index)
        if let existing = inFlight[key] { return await existing.value }

        let sessionId = self.sessionId
        let fetcher = self.fetcher
        let task = Task<UIImage?, Never> {
            do {
                let data = try await fetcher.imageData(sessionId, entryId: entryId, index: index)
                // Decode off the main thread — large images would stutter.
                return await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: nsKey) }
        return image
    }
}
