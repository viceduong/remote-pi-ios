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
    private var lastFrameTime = Date()

    init(client: APIClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
        self.offlineStore = OfflineQueueStore(sessionId: sessionId)
    }

    // MARK: - Lifecycle

    func start() async {
        lifecycleActive = true
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
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self, self.lifecycleActive else { return }
                // Skip the poll while SSE is alive (it just delivered a frame):
                // the poll is only a safety net for missed file events.
                if Date().timeIntervalSince(self.lastFrameTime) > 30 {
                    await self.refreshFromServer()
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
        guard let page = try? await client.fetchMessages(sessionId, limit: 200) else { return }
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
            return (message.timestamp ?? 0) >= newestLocal && !isDuplicate(message)
        }
        if !fresh.isEmpty { appendTail(fresh) }
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
        let optimisticId = appendUserMessage(trimmed, clientMessageId: clientMessageId)
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
            if resp.queued {
                // Keep an existing turn's state intact. The queue item is a
                // durable pending bubble; queue_update removes it on delivery.
                queuedNote = "⏳ Queued — agent is busy, your message will go in when it finishes"
                if let id = resp.queueItemId,
                   !queuedItems.contains(where: { $0.id == id }) {
                    queuedItems.append(QueueItem(id: id, clientMessageId: clientMessageId,
                                                 message: trimmed, status: "queued",
                                                 queuedAt: nil, startedAt: nil, completedAt: nil, error: nil))
                }
            } else {
                // Idempotent retry may resolve to an already-completed queue
                // item. Remove the orphan optimistic bubble and reconcile.
                messages.removeAll { $0.id == optimisticId }
                await refreshFromServer()
            }
        } catch {
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                // Swift Task cancellation (view disappeared, app backgrounded, or
                // explicit Task.cancel). Don't discard the user's text — keep the
                // optimistic bubble and treat as offline so it retries on reconnect.
                // The next poll/SSE reconnect will reconcile via clientMessageId.
                if !wasStreaming { isStreaming = false; workingText = nil }
                // Keep optimistic message visible; also queue offline if force not already
                if offlinePending.count < 100, !offlinePending.contains(where: { $0.id.uuidString == clientMessageId }) {
                    offlinePending.append(OfflineMessage(text: trimmed, id: UUID(uuidString: clientMessageId) ?? UUID()))
                    Task { await saveOfflineQueue() }
                }
                return
            }
            messages.removeAll { $0.id == optimisticId }
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
            // History may already contain previously queued prompts — clear stale chips
            reconcileQueued(page.messages)
            if queuedItems.isEmpty { queuedNote = nil }
            working = page.working
            applyWorkingIndicator()
            hasMore = page.hasMore
            lowestFetchedTs = page.messages.compactMap { $0.timestamp }.min()
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
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
        let base = client.baseURL.appendingPathComponent("api/sessions/\(sessionId)/events")
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
            Task { @MainActor in
                self?.handle(frame: frame)
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

    private func handle(frame: SSEFrame) {
        lastFrameTime = Date()
        guard let data = frame.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
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
        case "tool_execution_start":
            // Status-only: no bubble (message events render the result), but
            // the user sees what the agent is doing right now.
            if let name = obj["toolName"] as? String {
                workingText = "Running \(name)…"
            }
        case "message_start":
            if let msg = obj["message"] as? [String: Any] {
                // User prompts are already shown optimistically — skip echoes.
                if (msg["role"] as? String) == "user" { break }
                if Self.isToolMessage(msg) { upsertTool(from: msg, finalize: false) }
                else { upsertAssistant(from: msg, finalize: false) }
            }
        case "message_update":
            handleUpdate(obj)
        case "message_end":
            flushPendingDelta()
            if let msg = obj["message"] as? [String: Any] {
                if (msg["role"] as? String) == "user" { break }
                if Self.isToolMessage(msg) { upsertTool(from: msg, finalize: true) }
                else { upsertAssistant(from: msg, finalize: true) }
            }
        case "agent_exited":
            isStreaming = false
            connectionState = .disconnected
        case "queue_update":
            if let items = obj["items"] as? [[String: Any]] {
                let parsed = items.compactMap { d -> QueueItem? in
                    guard let id = d["id"] as? String, let message = d["message"] as? String else { return nil }
                    return QueueItem(id: id, clientMessageId: d["clientMessageId"] as? String,
                                     message: message, status: d["status"] as? String ?? "queued",
                                     queuedAt: nil, startedAt: nil, completedAt: nil, error: nil)
                }
                queuedItems = parsed.filter { $0.status != "done" && $0.status != "failed" }
                if queuedItems.isEmpty { queuedNote = nil }
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
            if let idx = queuedItems.firstIndex(where: { $0.message == m.text }) {
                queuedItems.remove(at: idx)
            }
            if queuedItems.isEmpty { queuedNote = nil }
        }
    }

    /// Server truth from /queue (durable outbox) — fetch on open so queued
    /// messages survive navigation.
    func loadQueue() async {
        if let items = try? await client.fetchQueue(sessionId) {
            queuedItems = items.filter { $0.status != "done" && $0.status != "failed" }
            if !queuedItems.isEmpty {
                queuedNote = "\(queuedItems.count) message\(queuedItems.count > 1 ? "s" : "") queued — agent is busy"
            } else {
                queuedNote = nil
            }
        } else {
            // Keep last known queue on fetch failure; don't show stale note if we know it's empty
            if queuedItems.isEmpty { queuedNote = nil }
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
                break // still offline — keep the rest
            }
        }
        await saveOfflineQueue()
        if offlinePending.isEmpty { queuedNote = nil }
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
        guard let ev = obj["assistantMessageEvent"] as? [String: Any] else { return }
        let type = ev["type"] as? String ?? ""
        if type == "thinking_delta" {
            if workingText != "Thinking…" { workingText = "Thinking…" }
        }
        if type == "text_delta" {
            if workingText != "Writing…" { workingText = "Writing…" }
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

    @discardableResult
    private func appendUserMessage(_ text: String, clientMessageId: String) -> String {
        let message = ChatMessage(id: "client:\(clientMessageId)", entryId: nil,
                                  clientMessageId: clientMessageId,
                                  role: .user, text: text, thinking: nil,
                                  toolCalls: [], toolActivity: nil,
                                  isError: false, toolName: nil, isSystemNote: false,
                                  model: nil, errorMessage: nil,
                                  timestamp: Int(Date().timeIntervalSince1970 * 1000))
        messages.append(message)
        streamingIndex = nil
        return message.id
    }
}
