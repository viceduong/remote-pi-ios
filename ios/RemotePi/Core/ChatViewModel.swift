import Foundation
import Combine

/**
 * Chat state for one session: message list, streaming reconciliation of
 * assistant text deltas, tool execution activity, and SSE lifecycle.
 *
 * All mutation happens on the main actor; the EventSource delivers frames on
 * the main queue, so no locking is needed.
 */
@MainActor
final class ChatViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var hasMore = false
    /// Server-owned queued prompts (durable outbox — rendered as pending
    /// bubbles with cancel; never vanish, survive navigation/restart).
    @Published private(set) var queuedItems: [QueueItem] = []
    /// Server-owned queued prompts (rendered as pending bubbles — never vanish).
    @Published private(set) var isLoadingHistory = true
    /// Bumped every time history is (re)loaded wholesale — ChatView re-arms
    /// the initial bottom clamp on change so a replaced message array always
    /// lands at absolute bottom.
    @Published private(set) var historyEpoch = 0
    /// True when a cached snapshot was rendered at open — ChatView lifts the
    /// dim cover immediately when this fires.
    @Published private(set) var cacheLoaded = false
    private var viewModelLoadedFromCache = false
    /// Live "what the assistant is doing" label (Working/Thinking/Running tool…).
    @Published private(set) var workingText: String?
    @Published var errorMessage: String?
    @Published var pendingText = ""
    @Published var queuedNote: String?
    private var loadingMore = false
    /// Last host-activity push time (for the file-driven working indicator).
    private var fileActivityAt: Date?
    /// True after the first SSE connection (reconnects reconcile history).
    private var hasConnectedOnce = false
    /// Oldest timestamp actually fetched (pagination baseline, survives eviction).
    private var lowestFetchedTs: Int?
    /// Server-derived working flag (works for mirror sessions too — RPC
    /// events never reach clients there, so the file state is the signal).
    @Published private(set) var working = false
    /// Latest cumulative provider usage from message_update (pi 0.85).
    @Published private(set) var liveUsage: SessionUsage?
    /// Session token/cost stats from get_session_stats (pi 0.85).
    @Published private(set) var stats: SessionStats?
    /// Last-resort blank guard: set when focus mode would render nothing
    /// (session tail is one huge tool loop). ChatView disables focus mode so
    /// the tool rows show instead of a blank screen.
    @Published private(set) var focusModeFallback = false
    /// Locally-queued sends while offline (persisted, flushed on reconnect).
    @Published private(set) var offlinePending: [OfflineMessage] = []
    private var flushingOffline = false
    private let offlineStore: OfflineQueueStore
    /// Coalesced streamed deltas: batched flushes (~90ms) keep scrolling
    /// smooth instead of re-rendering per token.
    private var pendingDelta = ""
    private var pendingDeltaIndex: Int?
    private var flushTask: Task<Void, Never>?
    /// Batched file_update pushes (avoid render storms right after open).
    private var pendingFileMessages: [ChatMessage] = []
    private var fileFlushTask: Task<Void, Never>?
    /// Set when older messages are prepended — the list scrolls back to this
    /// anchor so pagination doesn't visually jump.
    @Published var prependAnchor: String?

    private let client: APIClient
    private let sessionId: String
    private var eventSource: EventSource?
    private var pollTask: Task<Void, Never>?
    private var lifecycleActive = false
    /// Viewport signal used for safe retention: live tails may evict old rows
    /// only while the user is following the bottom.
    private var viewportNearBottom = true

    /// Index of the assistant bubble currently receiving deltas.
    private var streamingIndex: Int?
    /// toolCallId currently executing (tool_execution_update correlation).
    private var activeToolCallId: String?
    /// Durable entry-id cursor for cheap reconnects (?since= fetch).
    private var lastSeenEntryId: String?
    private var lastFrameTime = Date()

    init(client: APIClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
        self.offlineStore = OfflineQueueStore(sessionId: sessionId)
    }

    // MARK: - Lifecycle

    func start() async {
        lifecycleActive = true
        // Instant open: render the on-disk snapshot, then reconcile over the
        // network. The dim cover lifts on the snapshot so the session appears
        // fully loaded immediately.
        if messages.isEmpty, !viewModelLoadedFromCache {
            if let snap = await SessionHistoryCache.shared.load(sessionId: sessionId) {
                messages = snap.messages
                hasMore = snap.hasMore
                lastSeenEntryId = snap.cursor
                historyEpoch += 1
                viewModelLoadedFromCache = true
                applyWorkingIndicator()
                // Snapshot is on screen — lift the cover instantly; the
                // network refresh merges any delta below.

            }
        }
        await loadHistory()
        guard lifecycleActive else { return }
        await loadQueue()
        guard lifecycleActive else { return }
        openStream()
        startPolling()
    }

    func stop() {
        lifecycleActive = false
        suspendNetwork()
        flushTask?.cancel()
        flushTask = nil
        fileFlushTask?.cancel()
        fileFlushTask = nil
        pendingDelta = ""
        pendingDeltaIndex = nil
        pendingFileMessages.removeAll()
        streamingIndex = nil
    }

    /// iOS may suspend arbitrary long-lived sockets in the background. Stop
    /// transport while inactive and reconcile from server truth on resume.
    func suspendNetwork() {
        eventSource?.stop()
        eventSource = nil
        pollTask?.cancel()
        pollTask = nil
    }

    /// Resume transport after foregrounding. History reconciliation covers
    /// events missed while the app was suspended.
    func resumeNetwork() {
        guard lifecycleActive, eventSource == nil else { return }
        openStream()
        startPolling()
        Task { await refreshFromServer(); await loadQueue(); await flushOfflineQueue() }
    }

    /// Host-terminal / other-client activity reaches the app via the server's
    /// file-watch push (`file_update` SSE events). Polling is only a slow
    /// safety net in case the watcher is unavailable on the server.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self, self.lifecycleActive else { return }
                // Since-cursor refresh is cheap (only new rows). Run it on
                // EVERY poll tick: SSE can silently drop frames, and the old
                // "only if silent 30s" gate let intermittent misses persist
                // until manual reload.
                await self.refreshFromServer()
                // pi 0.85 stats: refresh context/cost periodically.
                if let stats = try? await self.client.fetchStats(self.sessionId) {
                    self.stats = stats
                }
            }
        }
    }

    /// Derive the working indicator from the server-derived flag: shows for
    /// mirror sessions (no RPC events) and bridge sessions alike; never fights
    /// the live streaming state.
    private func applyWorkingIndicator() {
        if working {
            if workingText == nil && !isStreaming {
                workingText = "Writing…"
                fileActivityAt = Date()
            }
        } else if !isStreaming {
            workingText = nil
        }
    }

    private func refreshFromServer() async {
        guard lifecycleActive else { return }
        // Cursor reconnect: fetch only entries after the last one we hold.
        // Falls back to a full 200-row refetch when the cursor is unknown
        // (compaction/branch switch server-side).
        let page: (messages: [ChatMessage], hasMore: Bool, total: Int, pending: [String], working: Bool)
        if let lastId = lastSeenEntryId,
           let delta = try? await client.fetchMessages(sessionId, limit: 200, since: lastId),
           !delta.messages.isEmpty {
            page = delta
        } else if let full = try? await client.fetchMessages(sessionId, limit: 200) {
            page = full
        } else {
            return
        }
        guard lifecycleActive else { return }
        // Watchdog: clear the indicator if the host agent has been quiet for a
        // while AND the server no longer reports it as working.
        if let t = fileActivityAt, Date().timeIntervalSince(t) > 25, !page.working {
            workingText = nil
            isStreaming = false
            fileActivityAt = nil
        }
        working = page.working
        applyWorkingIndicator()
        // Include same-entry updates so fuller server copies replace partial
        // streamed bubbles; filtering duplicates first discarded replacements.
        let newestLocal = messages.compactMap { $0.timestamp }.max() ?? 0
        let knownIds = Set(messages.compactMap { $0.entryId })
        let fresh = page.messages.filter { message in
            if let id = message.entryId, knownIds.contains(id) { return true }
            // nil-timestamp rows would be dropped by the >= newestLocal check
            // (0 >= newest is false) — treat them as fresh and let the merger
            // dedupe them.
            guard message.timestamp != nil else { return !isDuplicate(message) }
            return (message.timestamp ?? 0) >= newestLocal && !isDuplicate(message)
        }
        if !fresh.isEmpty { appendTail(fresh) }
        // Advance the reconnect cursor to the newest server entry id.
        if let last = page.messages.last(where: { $0.entryId != nil })?.entryId {
            lastSeenEntryId = last
        }
        // Keep the instant-open cache warm.
        await SessionHistoryCache.shared.save(
            sessionId: sessionId, messages: messages, hasMore: hasMore,
            cursor: lastSeenEntryId)
    }

    func setViewportNearBottom(_ value: Bool) {
        viewportNearBottom = value
    }

    // MARK: - Actions

    func send(_ text: String, force: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingText = ""
        let clientMessageId = UUID().uuidString
        // UX: the message renders as a QUEUED chip first, and becomes a real
        // blue bubble only when the server confirms delivery (user echo via
        // message_end / refreshFromServer). No optimistic bubble — it caused
        // doubles on reopen (echo + optimistic copy with no entryId link).
        let pendingChip = QueueItem(id: "pending:\(clientMessageId)", clientMessageId: clientMessageId,
                                    message: trimmed, status: "queued",
                                    queuedAt: Int(Date().timeIntervalSince1970 * 1000),
                                    startedAt: nil, completedAt: nil, error: nil)
        queuedItems.append(pendingChip)
        queuedNote = queuedItems.count > 1
            ? "⏳ \(queuedItems.count) messages queued"
            : nil
        let wasStreaming = isStreaming
        // Immediate feedback: the response can take a second to start, and the
        // first SSE event may lag — show a waiting state right away.
        if !isStreaming {
            isStreaming = true
            workingText = "Waiting for response…"
            fileActivityAt = Date()
        }
        do {
            let resp = try await client.sendTurn(sessionId, message: trimmed, force: force,
                                                 clientMessageId: clientMessageId)
            // Replace the pending chip with the durable server item (or drop
            // it — the server echo will render the real bubble).
            queuedItems.removeAll { $0.id == pendingChip.id }
            if resp.queued && resp.dispatched != true {
                // TRULY queued (agent busy, item held in the durable outbox).
                let depth = resp.queueDepth ?? 1
                queuedNote = depth > 3
                    ? "⏳ Queued — \(depth) messages ahead of yours"
                    : "⏳ Queued — agent is busy, your message will go in when it finishes"
                if let id = resp.queueItemId,
                   !queuedItems.contains(where: { $0.id == id }) {
                    queuedItems.append(QueueItem(id: id, clientMessageId: clientMessageId,
                                                 message: trimmed, status: "queued",
                                                 queuedAt: Int(Date().timeIntervalSince1970 * 1000),
                                                 startedAt: nil, completedAt: nil, error: nil))
                }
            } else {
                // Idempotent retry may resolve to an already-completed queue
                // item — the server echo (via refresh) renders the real bubble.
                await refreshFromServer()
            }
        } catch {
            // Drop the pending chip on any failure — error paths below decide
            // whether the text goes to the offline outbox.
            queuedItems.removeAll { $0.id == pendingChip.id }
            if queuedItems.isEmpty { queuedNote = nil }
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                // Swift Task cancellation (view disappeared, app backgrounded, or
                // explicit Task.cancel). Don't discard the user's text — keep it
                // as an offline pending bubble; it retries on reconnect.
                if !wasStreaming { isStreaming = false; workingText = nil }
                if offlinePending.count < 100, !offlinePending.contains(where: { $0.id.uuidString == clientMessageId }) {
                    offlinePending.append(OfflineMessage(text: trimmed, id: UUID(uuidString: clientMessageId) ?? UUID()))
                    Task { await saveOfflineQueue() }
                }
                return
            }
            if !wasStreaming { isStreaming = false; workingText = nil }
            if case APIError.offline = error {
                guard offlinePending.count < 100 else {
                    errorMessage = "Offline queue is full (100 messages). Reconnect or discard one first."
                    return
                }
                offlinePending.append(OfflineMessage(
                    text: trimmed,
                    id: UUID(uuidString: clientMessageId) ?? UUID()
                ))
                await saveOfflineQueue()
            } else if case APIError.http(409, _, "session_live") = error {
                if !force {
                    // One-shot force takeover: retry with ?force=1 which converts
                    // the read-only mirror into a bridge-owned agent.
                    await send(text, force: true)
                    return
                }
                errorMessage = "Host Pi owns this session — stop it in the terminal before sending here."
            } else if isCancellation(error) {
                // View disappeared / app backgrounded mid-request — not an error.
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func abort() async {
        do {
            try await client.abortTurn(sessionId)
            isStreaming = false
            workingText = nil
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - History (lazy, last-N pages)

    private func loadHistory() async {
        guard lifecycleActive else { return }
        isLoadingHistory = true
        await loadOfflineQueue()
        defer { isLoadingHistory = false }
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100)
            guard lifecycleActive else { return }
            messages = page.messages
            historyEpoch += 1
            // History may already contain previously queued prompts — clear stale chips
            reconcileQueued(page.messages)
            if queuedItems.isEmpty { queuedNote = nil }
            // Reopen-double fix: drop offline-pending items the server already
            // delivered (send succeeded but the response was lost — the text
            // was retried into the outbox even though the server has it).
            let deliveredTexts = Set(page.messages.filter { $0.role == .user }.map { $0.text })
            let before = offlinePending.count
            offlinePending.removeAll { deliveredTexts.contains($0.text) }
            if offlinePending.count != before { Task { await saveOfflineQueue() } }
            working = page.working
            applyWorkingIndicator()
            hasMore = page.hasMore
            lowestFetchedTs = page.messages.compactMap { $0.timestamp }.min()
            // Seed the reconnect cursor from the newest entry.
            if let last = page.messages.last(where: { $0.entryId != nil })?.entryId {
                lastSeenEntryId = last
            }
            // Blank-page guard: a session tail that is one long tool loop can
            // be 100% hidden in focus mode (thousands of empty tool-call
            // assistants + tool outputs). The server's ?visible=1 filter
            // returns the newest RENDERABLE rows in one call — refetch with
            // it when the initial page is all-hidden.
            if Self.hasVisibleContent(messages) == false, hasMore,
               let visible = try? await client.fetchMessages(sessionId, limit: 100, visibleOnly: true),
               !visible.messages.isEmpty {
                // MERGE, don't replace: the visible page spans a much wider
                // time range than the raw 100-row page. Replacing dropped
                // rows the prefetch had already loaded (missing-messages bug).
                let known = Set(messages.compactMap { $0.entryId })
                let fresh = visible.messages.filter { $0.entryId == nil || !known.contains($0.entryId!) }
                if !fresh.isEmpty {
                    messages.insert(contentsOf: fresh, at: 0)
                    historyEpoch += 1
                }
                hasMore = visible.hasMore
                lowestFetchedTs = min(lowestFetchedTs ?? Int.max,
                                      visible.messages.compactMap { $0.timestamp }.min() ?? Int.max)
                if let last = visible.messages.last(where: { $0.entryId != nil })?.entryId {
                    lastSeenEntryId = last
                }
            }
            // Last-resort blank guard: if the session STILL has no renderable
            // content in focus mode, surface the tool rows (focus off) so the
            // user sees the tool loop instead of a blank screen.
            if Self.hasVisibleContent(messages) == false {
                focusModeFallback = true
            }
            // Persist for instant-open next time.
            await SessionHistoryCache.shared.save(
                sessionId: sessionId, messages: messages, hasMore: hasMore,
                cursor: lastSeenEntryId)
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    /// True when at least one message would render in focus mode (non-tool,
    /// non-empty text/thinking). Used by the blank-page guard in loadHistory.
    private static func hasVisibleContent(_ messages: [ChatMessage]) -> Bool {
        messages.contains { m in
            if m.role == .tool || m.isSystemNote { return false }
            if m.role == .assistant,
               m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (m.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return true
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// Bound live-tail memory without evicting freshly fetched history. When
    /// the user follows the bottom, discard oldest rows; while reading history,
    /// retain the visible/older side and reconcile the newest tail on return.
    private func evictLiveTailIfNeeded() {
        let maxRetained = 800
        let trigger = 1_000
        guard messages.count > trigger, viewportNearBottom else { return }
        let dropped = messages.count - maxRetained
        messages.removeFirst(dropped)
        if let index = streamingIndex { streamingIndex = max(0, index - dropped) }
        if let index = pendingDeltaIndex { pendingDeltaIndex = max(0, index - dropped) }
    }

    private func evictHistoryTailWhileBrowsing() {
        let maxRetained = 2_000
        guard !viewportNearBottom, messages.count > maxRetained else { return }
        messages.removeLast(messages.count - maxRetained)
        if let index = streamingIndex, index >= messages.count { streamingIndex = nil }
        if let index = pendingDeltaIndex, index >= messages.count { pendingDeltaIndex = nil }
    }

    /// Fetch the next older page and prepend it (triggered at scroll top).
    func loadMore() async {
        guard lifecycleActive, hasMore, !loadingMore,
              let earliest = (messages.compactMap { $0.timestamp }.min()) ?? lowestFetchedTs else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100, before: earliest)
            guard lifecycleActive else { return }
            guard !page.messages.isEmpty else {
                hasMore = false
                return
            }
            let known = Set(messages.compactMap { $0.entryId })
            let fresh = page.messages.filter { $0.entryId == nil || !known.contains($0.entryId!) }
            guard !fresh.isEmpty else {
                // The cursor may land on a page containing only already-known
                // rows because several entries share a timestamp. Keep the
                // cursor alive and let the next scroll retry.
                hasMore = page.hasMore
                return
            }
            // Remember the current top so the view can keep its position.
            prependAnchor = messages.first(where: { $0.role != .tool && !$0.isSystemNote })?.id
                ?? messages.first?.id
            if let index = streamingIndex { streamingIndex = index + fresh.count }
            if let index = pendingDeltaIndex { pendingDeltaIndex = index + fresh.count }
            messages.insert(contentsOf: fresh, at: 0)
            hasMore = page.hasMore
            lowestFetchedTs = min(lowestFetchedTs ?? Int.max, page.messages.compactMap { $0.timestamp }.min() ?? Int.max)
            evictHistoryTailWhileBrowsing()
        } catch {
            // transient — leave hasMore as-is so a later scroll retries
        }
    }

    /// Called after the view scrolls back to the prepend anchor.
    func consumePrependAnchor() {
        prependAnchor = nil
    }

    // MARK: - SSE

    private func openStream() {
        eventSource?.stop()
        var components = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: true)!
        components.path += "/api/sessions/\(sessionId)/events"
        components.queryItems = [URLQueryItem(name: "skeleton", value: "1")]
        let base = components.url!
        let source = EventSource(url: base, token: client.token)
        source.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connected:
                    self?.connectionState = .connected
                    // file_update events are NOT replayed on reconnect (they are
                    // excluded from the server ring), so a reconnect can miss
                    // messages written while disconnected. Reconcile from the
                    // server truth immediately.
                    if self?.hasConnectedOnce == true {
                        await self?.refreshFromServer()
                        await self?.flushOfflineQueue()
                    } else {
                        await self?.flushOfflineQueue()
                    }
                    self?.hasConnectedOnce = true
                case .connecting: self?.connectionState = .connecting
                case .disconnected: self?.connectionState = .disconnected
                }
            }
        }
        source.onFrame = { [weak self] frame in
            // Parse off-main: JSON decoding of per-token deltas was hopping to
            // the main actor ~100x/sec during streaming.
            let obj = frame.data.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Task { @MainActor in
                self?.handleParsed(frame: frame, obj: obj)
            }
        }
        source.onError = { [weak self] message in
            guard message.contains("401") || message.contains("403") || message.contains("404") else { return }
            Task { @MainActor in
                self?.errorMessage = "Event stream unavailable: \(message)"
            }
        }
        eventSource = source
        source.start()
    }

    private func handleParsed(frame: SSEFrame, obj: [String: Any]?) {
        lastFrameTime = Date()
        guard let obj else { return }
        defer { evictLiveTailIfNeeded() }
        switch frame.event {
        case "agent_start", "turn_start":
            isStreaming = true
            errorMessage = nil
            queuedNote = nil
            workingText = "Working…"
            fileActivityAt = Date()
        case "turn_end":
            // Server keeps ownership reserved through the internal gap before
            // agent_end; keep the UI busy as well.
            isStreaming = true
            workingText = "Finishing…"
        case "agent_end":
            isStreaming = false
            working = false
            workingText = nil
        case "agent_settled":
            // pi 0.85: the FULL run is settled — no retry, compaction retry,
            // or queued continuation remains. This is the authoritative
            // "done" signal; clears the working indicator immediately
            // instead of waiting on the 25s file-activity watchdog.
            isStreaming = false
            working = false
            workingText = nil
            fileActivityAt = nil
        case "tool_execution_start":
            // Status-only: no bubble (message events render the result), but
            // the user sees what the agent is doing right now.
            if let name = obj["toolName"] as? String {
                workingText = "Running \(name)…"
                fileActivityAt = Date()
                activeToolCallId = obj["toolCallId"] as? String
            }
        case "tool_execution_update":
            // pi 0.85: streams tool progress with the ACCUMULATED partial
            // result (not a delta) keyed by toolCallId. Render live output
            // into the tool bubble while the command runs.
            handleToolExecutionUpdate(obj)
        case "tool_execution_end":
            activeToolCallId = nil
            if let name = obj["toolName"] as? String {
                workingText = "Running \(name)…"
            }
        case "message_start":
            if let msg = obj["message"] as? [String: Any] {
                if (msg["role"] as? String) == "user" {
                    // The queued prompt just went live — drop its chip now.
                    // (RPC path: file_update never fires for bridge sessions,
                    // so without this the chip stayed stuck at "queued".)
                    if let text = msg["text"] as? String, !text.isEmpty {
                        if let idx = queuedItems.firstIndex(where: { $0.message == text }) {
                            queuedItems.remove(at: idx)
                        }
                        if queuedItems.isEmpty { queuedNote = nil }
                    }
                    break
                }
                if Self.isToolMessage(msg) { upsertTool(from: msg, finalize: false) }
                else { upsertAssistant(from: msg, finalize: false) }
            }
        case "message_update":
            handleUpdate(obj)
        case "message_end":
            flushPendingDelta()
            if let msg = obj["message"] as? [String: Any] {
                if (msg["role"] as? String) == "user" {
                    // Server echoed the user prompt — replace the optimistic
                    // copy with the canonical one and drop any matching chip.
                    if let text = msg["text"] as? String, !text.isEmpty {
                        if let idx = queuedItems.firstIndex(where: { $0.message == text }) {
                            queuedItems.remove(at: idx)
                        }
                        if queuedItems.isEmpty { queuedNote = nil }
                        messages.removeAll { $0.role == .user && $0.entryId == nil && $0.text == text && $0.id != (msg["id"] as? String).map { "entry:\($0)" } }
                    }
                    break
                }
                if Self.isToolMessage(msg) { upsertTool(from: msg, finalize: true) }
                else { upsertAssistant(from: msg, finalize: true) }
            }
        case "agent_exited":
            isStreaming = false
            connectionState = .disconnected
        case "queue_update":
            // pi 0.85 native shape: { steering: [text], followUp: [text] }.
            // Bridge legacy shape: { items: [QueueItem] }.
            if let steering = obj["steering"] as? [String],
               let followUp = obj["followUp"] as? [String] {
                var parsed: [QueueItem] = []
                for (i, text) in steering.enumerated() {
                    parsed.append(QueueItem(id: "steer-\(i)", clientMessageId: nil,
                                            message: text, status: "queued",
                                            queuedAt: nil, startedAt: nil, completedAt: nil, error: nil))
                }
                for (i, text) in followUp.enumerated() {
                    parsed.append(QueueItem(id: "followup-\(i)", clientMessageId: nil,
                                            message: text, status: "queued",
                                            queuedAt: nil, startedAt: nil, completedAt: nil, error: nil))
                }
                queuedItems = parsed
                queuedNote = parsed.isEmpty ? nil : "\(parsed.count) message\(parsed.count > 1 ? "s" : "") queued — agent is busy"
            } else if let items = obj["items"] as? [[String: Any]] {
                let parsed = items.compactMap { d -> QueueItem? in
                    guard let id = d["id"] as? String, let message = d["message"] as? String else { return nil }
                    return QueueItem(id: id, clientMessageId: d["clientMessageId"] as? String,
                                     message: message, status: d["status"] as? String ?? "queued",
                                     queuedAt: (d["queuedAt"] as? NSNumber)?.intValue,
                                     startedAt: (d["startedAt"] as? NSNumber)?.intValue,
                                     completedAt: (d["completedAt"] as? NSNumber)?.intValue,
                                     error: d["error"] as? String)
                }
                queuedItems = parsed.filter { $0.status != "done" && $0.status != "failed" }
                if queuedItems.isEmpty { queuedNote = nil }
            }
        case "agent_status":
            // Server-derived authoritative status (skeleton clients don't see
            // tool events, so this is the accurate running/waiting signal).
            let working = (obj["working"] as? Bool) ?? false
            let error = obj["error"] as? String
            self.working = working
            if working {
                isStreaming = true
                workingText = "Working…"
                fileActivityAt = Date()
            } else {
                isStreaming = false
                workingText = nil
                fileActivityAt = nil
            }
            if let error, !error.isEmpty {
                errorMessage = "Agent error: \(error)"
            }
        case "agent_crashed":
            // Server auto-respawns; surface it instead of a silent stop.
            isStreaming = false
            working = false
            workingText = "Agent crashed — restarting…"
            fileActivityAt = Date()
        case "file_update":
            // Host/other-client activity pushed by the server's file watcher.
            working = (obj["working"] as? Bool) ?? working
            applyWorkingIndicator()
            if let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? ""
                if role == "user" {
                    let text = (msg["text"] as? String) ?? ""
                    if !text.isEmpty {
                        if let idx = queuedItems.firstIndex(where: { $0.message == text }) {
                            queuedItems.remove(at: idx)
                        }
                        if queuedItems.isEmpty { queuedNote = nil }
                    }
                } else {
                    fileActivityAt = Date()
                }
                // Batch bursts (open-time replay + live host writes) into one
                // append to avoid a render storm on the first frames.
                pendingFileMessages.append(ChatMessage.fromAgentMessage(msg))
                if fileFlushTask == nil {
                    fileFlushTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.fileFlushTask = nil
                        let batch = self.pendingFileMessages
                        self.pendingFileMessages = []
                        self.appendTail(batch)
                    }
                }
            }
        default:
            break
        }
    }

    /// A message is a duplicate if its entry id already exists, or it matches
    /// an existing message by role + text head + near-identical timestamp
    /// (covers optimistic copies vs server echoes via SSE/file_update/poll).
    private func isDuplicate(_ m: ChatMessage) -> Bool {
        ChatMerger.isDuplicate(m, in: messages)
    }

    /// Append server-sourced messages — merge semantics live in ChatMerger
    /// (dedupe by entryId, replace-on-continuation) so every path behaves
    /// identically and the logic is unit-tested.
    private func appendTail(_ tail: [ChatMessage]) {
        ChatMerger.append(&messages, tail)
        reconcileQueued(tail)
        evictLiveTailIfNeeded()
    }

    /// Remove queued chips once their prompt actually streams in as a message.
    private func reconcileQueued(_ newMessages: [ChatMessage]) {
        guard !queuedItems.isEmpty else { return }
        for m in newMessages where m.role == .user {
            // Match by clientMessageId first (durable identity), fall back to
            // exact text. Text-only matching caused the same message to appear
            // twice locally (optimistic bubble + queued chip) when the server
            // echoed it under a different clientMessageId.
            var removed = false
            if let cid = m.clientMessageId,
               let idx = queuedItems.firstIndex(where: { $0.clientMessageId == cid }) {
                queuedItems.remove(at: idx)
                removed = true
            }
            if !removed, let idx = queuedItems.firstIndex(where: { $0.message == m.text }) {
                queuedItems.remove(at: idx)
                removed = true
            }
            if removed {
                // Also drop the optimistic copy if a server copy arrived —
                // prevents double bubbles for the same clientMessageId.
                if let cid = m.clientMessageId {
                    messages.removeAll { $0.id == "client:\(cid)" && m.id != $0.id }
                }
            }
        }
        if queuedItems.isEmpty { queuedNote = nil }
    }

    /// Server truth from /queue (durable outbox) — fetch on open so queued
    /// messages survive navigation.
    func loadQueue() async {
        if let items = try? await client.fetchQueue(sessionId) {
            queuedItems = items.filter { $0.status != "done" && $0.status != "failed" }
            // Reopen-double guard: a queued item whose text already exists as
            // a delivered user message in history was dispatched but the
            // queue file wasn't updated (dispatch race). Drop the chip —
            // the history bubble is authoritative.
            let historyTexts = Set(messages.filter { $0.role == .user }.map { $0.text })
            queuedItems.removeAll { historyTexts.contains($0.message) }
            if !queuedItems.isEmpty {
                queuedNote = "\(queuedItems.count) message\(queuedItems.count > 1 ? "s" : "") queued — agent is busy"
            } else {
                queuedNote = nil
            }
        } else {
            // Keep last known queue on fetch failure; don't show stale note if we know it's empty
            if queuedItems.isEmpty { queuedNote = nil }
        }
        // pi 0.85 stats: tokens/cost/context (best-effort, mirror sessions skip).
        if let stats = try? await client.fetchStats(sessionId) {
            self.stats = stats
        }
    }

    /// Persisted offline queue helpers.
    private func loadOfflineQueue() async {
        if let stored = await offlineStore.load() {
            offlinePending = stored
            return
        }
        // Migrate the original UserDefaults queue without losing messages.
        let legacyKey = "offlineQueue.\(sessionId)"
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([OfflineMessage].self, from: data) {
            offlinePending = Array(decoded.prefix(100))
            await saveOfflineQueue()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } else if let legacy = UserDefaults.standard.array(forKey: legacyKey) as? [String] {
            offlinePending = legacy.prefix(100).map { OfflineMessage(text: $0) }
            await saveOfflineQueue()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private func saveOfflineQueue() async {
        await offlineStore.save(offlinePending)
    }

    func flushOfflineQueue() async {
        guard !flushingOffline else { return }
        flushingOffline = true
        defer { flushingOffline = false }
        while let item = offlinePending.first {
            do {
                let response = try await client.sendTurn(sessionId, message: item.text,
                                                         clientMessageId: item.id.uuidString)
                offlinePending.removeFirst()
                if response.queued { await loadQueue() }
            } catch {
                if isCancellation(error) { break }
                // Poison-message handling: permanent failures (4xx — too long,
                // malformed, auth) would otherwise block the whole queue
                // forever. Drop the item, surface the error, keep flushing.
                if case APIError.http(let code, let message, _) = error, (400..<500).contains(code) {
                    offlinePending.removeFirst()
                    errorMessage = "Message dropped: \(message ?? "HTTP \(code)")"
                    await saveOfflineQueue()
                    continue
                }
                break // still offline — keep the rest
            }
        }
        await saveOfflineQueue()
        if offlinePending.isEmpty { queuedNote = nil }
    }

    /// Fetch full tool output for a truncated (skeleton) tool message and
    /// replace its text in place.
    func expandToolOutput(toolCallId: String?) async -> String? {
        guard let tid = toolCallId, !tid.isEmpty else { return nil }
        return try? await client.fetchToolResult(sessionId, toolCallId: tid)
    }

    func discardOffline(_ id: UUID) {
        offlinePending.removeAll { $0.id == id }
        Task { await saveOfflineQueue() }
    }

    func cancelQueued(_ itemId: String) async {
        do {
            try await client.cancelQueued(sessionId, itemId: itemId)
            queuedItems.removeAll { $0.id == itemId }
            if queuedItems.isEmpty { queuedNote = nil }
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
            await loadQueue()
        }
    }

    /// pi marks tool results with a toolName (roles: toolResult/assistant/user).
    /// Legacy shapes: content made only of toolCall/toolResult blocks.
    private static func isToolMessage(_ json: [String: Any]) -> Bool {
        if let name = json["toolName"] as? String, !name.isEmpty { return true }
        let role = json["role"] as? String
        if role == "tool" || role == "toolResult" { return true }
        if let blocks = json["content"] as? [[String: Any]], !blocks.isEmpty {
            let toolTypes: Set<String> = ["toolCall", "toolResult", "image"]
            let allTool = blocks.allSatisfy { toolTypes.contains($0["type"] as? String ?? "") }
            if allTool && blocks.contains(where: { ($0["type"] as? String) == "toolCall" }) { return true }
        }
        return false
    }

    /// Streamed deltas update the in-progress assistant (or tool) bubble.
    private func handleUpdate(_ obj: [String: Any]) {
        // pi 0.85: cumulative provider usage rides every message_update.
        if let usageJson = obj["usage"] as? [String: Any], let u = SessionUsage(json: usageJson) {
            liveUsage = u
        }
        guard let ev = obj["assistantMessageEvent"] as? [String: Any] else { return }
        let type = ev["type"] as? String ?? ""
        if type == "thinking_delta" {
            if workingText != "Thinking…" { workingText = "Thinking…" }
        }
        if type == "text_delta" {
            if workingText != "Writing…" { workingText = "Writing…" }
        }
        // pi 0.85: tool-call arguments stream incrementally. Surface the
        // forming call in the working indicator (real-time feedback).
        if type == "toolcall_start", let name = ev["toolName"] as? String {
            workingText = "Calling \(name)…"
        }
        if let msg = obj["message"] as? [String: Any], Self.isToolMessage(msg) {
            // Tool result streaming: append deltas to the last tool bubble.
            guard type == "text_delta", let delta = ev["delta"] as? String else { return }
            let idx = streamingIndex ?? messages.lastIndex(where: { $0.role == .tool })
            guard let idx else { return }
            accumulateDelta(delta, into: idx)
            return
        }
        guard let idx = ensureStreamingBubble() else { return }

        switch type {
        case "text_delta":
            if let delta = ev["delta"] as? String {
                accumulateDelta(delta, into: idx)
            }
        case "thinking_delta":
            if let delta = ev["delta"] as? String {
                messages[idx].thinking = (messages[idx].thinking ?? "") + delta
            }
        case "done", "error":
            flushPendingDelta()
            if let msg = obj["message"] as? [String: Any] {
                upsertAssistant(from: msg, finalize: true)
            }
            if type == "error" { isStreaming = false }
        default:
            break
        }
    }

    /// pi 0.85 `tool_execution_update`: `partialResult` holds the ACCUMULATED
    /// output so far (not a delta) — replace the matching tool bubble's text.
    /// Correlate by toolCallId; fall back to the last tool bubble.
    private func handleToolExecutionUpdate(_ obj: [String: Any]) {
        guard let partial = obj["partialResult"] as? [String: Any],
              let blocks = partial["content"] as? [[String: Any]] else { return }
        var text = ""
        for b in blocks where (b["type"] as? String) == "text" {
            if let t = b["text"] as? String { text += t }
        }
        guard !text.isEmpty else { return }
        fileActivityAt = Date()
        let idx: Int?
        if let callId = obj["toolCallId"] as? String {
            idx = messages.lastIndex(where: { $0.toolCalls.contains(where: { $0.id == callId }) })
                ?? messages.lastIndex(where: { $0.role == .tool && $0.toolName == (obj["toolName"] as? String) })
        } else {
            idx = messages.lastIndex(where: { $0.role == .tool })
        }
        guard let idx, messages.indices.contains(idx) else { return }
        // Replace (accumulated, not delta) — throttle via the delta flusher
        // to avoid render storms on chatty tools.
        if let pendingDeltaIndex, pendingDeltaIndex != idx { flushPendingDelta() }
        pendingDeltaIndex = idx
        pendingDelta = text
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushPendingDelta()
        }
    }

    /// Batch streamed text deltas: append to a buffer, flush ~90ms later.
    private func accumulateDelta(_ delta: String, into idx: Int) {
        if let pendingDeltaIndex, pendingDeltaIndex != idx { flushPendingDelta() }
        pendingDeltaIndex = idx
        pendingDelta += delta
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushPendingDelta()
        }
    }

    private func flushPendingDelta() {
        guard !pendingDelta.isEmpty else { return }
        let delta = pendingDelta
        pendingDelta = ""
        let target = pendingDeltaIndex
        pendingDeltaIndex = nil
        if let idx = target, messages.indices.contains(idx) {
            messages[idx].text += delta
        } else if let idx = streamingIndex, messages.indices.contains(idx) {
            messages[idx].text += delta
        } else if let idx = messages.lastIndex(where: { $0.role == .tool }) {
            messages[idx].text += delta
        }
    }

    /// Find or create the assistant bubble receiving streamed content.
    private func ensureStreamingBubble() -> Int? {
        if let idx = streamingIndex, messages.indices.contains(idx) {
            return idx
        }
        var msg = ChatMessage(entryId: nil, role: .assistant, text: "", thinking: nil,
                              toolCalls: [], toolActivity: nil, isError: false,
                              toolName: nil, isSystemNote: false, model: nil, errorMessage: nil, timestamp: nil)
        messages.append(msg)
        streamingIndex = messages.count - 1
        return streamingIndex
    }

    /// Tool-result messages render as monospace tool blocks, like the terminal.
    private func upsertTool(from json: [String: Any], finalize: Bool) {
        let mapped = ChatMessage.fromAgentMessage(json)
        let existingIndex: Int? = {
            if let entryId = mapped.entryId {
                return messages.lastIndex(where: { $0.entryId == entryId })
            }
            if let streamingIndex, messages.indices.contains(streamingIndex),
               messages[streamingIndex].role == .tool {
                return streamingIndex
            }
            return nil
        }()
        let idx: Int
        if let existingIndex {
            idx = existingIndex
            if finalize {
                var replacement = mapped
                replacement.id = messages[existingIndex].id
                messages[existingIndex] = replacement
            } else if !mapped.text.isEmpty {
                messages[existingIndex].text = mapped.text
            }
        } else {
            messages.append(mapped)
            idx = messages.count - 1
        }
        streamingIndex = finalize ? nil : idx
    }

    /// Replace the in-progress bubble with the canonical mapped message.
    private func upsertAssistant(from json: [String: Any], finalize: Bool) {
        let mapped = ChatMessage.fromAgentMessage(json)
        guard let idx = ensureStreamingBubble() else { return }
        var current = messages[idx]
        // Preserve streamed text while the canonical copy is incomplete or
        // message_end carries only metadata/tool calls.
        if !mapped.text.isEmpty || current.text.isEmpty {
            current = mapped
        } else {
            current.entryId = mapped.entryId ?? current.entryId
            current.thinking = mapped.thinking ?? current.thinking
            if !mapped.toolCalls.isEmpty { current.toolCalls = mapped.toolCalls }
            current.isError = mapped.isError
            current.errorMessage = mapped.errorMessage ?? current.errorMessage
            current.model = mapped.model ?? current.model
        }
        messages[idx] = current
        if finalize {
            streamingIndex = nil
        }
    }
}
