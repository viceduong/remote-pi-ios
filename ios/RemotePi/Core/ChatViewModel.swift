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
    private var offlineKey: String { "offlineQueue.\(sessionId)" }
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

    /// Index of the assistant bubble currently receiving deltas.
    private var streamingIndex: Int?
    private var lastFrameTime = Date()

    init(client: APIClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
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
        eventSource?.stop()
        eventSource = nil
        pollTask?.cancel()
        pollTask = nil
        flushTask?.cancel()
        flushTask = nil
        fileFlushTask?.cancel()
        fileFlushTask = nil
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

    // MARK: - Actions

    func send(_ text: String, force: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingText = ""
        let optimisticId = appendUserMessage(trimmed)
        // Immediate feedback: the response can take a second to start, and the
        // first SSE event may lag — show a waiting state right away.
        if !isStreaming {
            isStreaming = true
            workingText = "Waiting for response…"
            fileActivityAt = Date()
        }
        do {
            let resp = try await client.sendTurn(sessionId, message: trimmed, force: force)
            if resp.queued {
                isStreaming = false
                queuedNote = "⏳ Queued — agent is busy, your message will go in when it finishes"
                workingText = nil
                if let id = resp.queueItemId {
                    queuedItems.append(QueueItem(id: id, message: trimmed, status: "queued",
                                                 queuedAt: nil, startedAt: nil, completedAt: nil, error: nil))
                }
            }
        } catch {
            if error is CancellationError {
                messages.removeAll { $0.id == optimisticId }
                isStreaming = false
                workingText = nil
                return
            }
            isStreaming = false
            workingText = nil
            messages.removeAll { $0.id == optimisticId }
            if case APIError.offline = error {
                offlinePending.append(OfflineMessage(text: trimmed))
                saveOfflineQueue()
            } else if case APIError.http(409, _, "session_live") = error {
                // Single-writer invariant: stop the host Pi process first.
                errorMessage = "Host Pi owns this session — stop it in the terminal before sending here."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func abort() async {
        isStreaming = false
        try? await client.abortTurn(sessionId)
    }

    // MARK: - History (lazy, last-N pages)

    private func loadHistory() async {
        guard lifecycleActive else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100)
            guard lifecycleActive else { return }
            messages = page.messages
            working = page.working
            applyWorkingIndicator()
            hasMore = page.hasMore
            lowestFetchedTs = page.messages.compactMap { $0.timestamp }.min()
            loadOfflineQueue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bound memory on very long sessions: drop far-from-viewport pages.
    /// `lowestFetchedTs` stays correct, so scrolling up refetches the span.
    private func evictIfNeeded() {
        let maxRetained = 400
        let trigger = 600
        guard messages.count > trigger else { return }
        messages.removeFirst(messages.count - maxRetained)
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
                hasMore = false // duplicates only — no more new content (infinite-scroll guard)
                return
            }
            // Remember the current top so the list can keep its position.
            prependAnchor = messages.first?.id.uuidString
            messages.insert(contentsOf: fresh, at: 0)
            hasMore = page.hasMore
            lowestFetchedTs = min(lowestFetchedTs ?? Int.max, page.messages.compactMap { $0.timestamp }.min() ?? Int.max)
            evictIfNeeded()
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
        eventSource = source
        source.start()
    }

    private func handle(frame: SSEFrame) {
        lastFrameTime = Date()
        guard let data = frame.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        switch frame.event {
        case "agent_start", "turn_start":
            isStreaming = true
            errorMessage = nil
            queuedNote = nil
            workingText = "Working…"
            fileActivityAt = Date()
        case "agent_end", "turn_end":
            isStreaming = false
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
                else { upsertAssistant(from: msg, finalize: true); isStreaming = false }
            }
        case "agent_exited":
            isStreaming = false
            connectionState = .disconnected
        case "queue_update":
            if let items = obj["items"] as? [[String: Any]] {
                let parsed = items.compactMap { d -> QueueItem? in
                    guard let id = d["id"] as? String, let message = d["message"] as? String else { return nil }
                    return QueueItem(id: id, message: message, status: d["status"] as? String ?? "queued",
                                     queuedAt: nil, startedAt: nil, completedAt: nil, error: nil)
                }
                queuedItems = parsed.filter { $0.status != "done" && $0.status != "failed" }
                if queuedItems.isEmpty { queuedNote = nil }
            }
        case "agent_crashed":
            // Server auto-respawns; surface it instead of a silent stop.
            isStreaming = false
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
                        queuedItems.removeAll { item in item.message == text || item.message.prefix(40) == String(text.prefix(40)) }
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
    }

    /// Remove queued chips once their prompt actually streams in as a message.
    private func reconcileQueued(_ newMessages: [ChatMessage]) {
        guard !queuedItems.isEmpty else { return }
        for m in newMessages where m.role == .user {
            let head = String(m.text.prefix(40))
            queuedItems.removeAll { item in
                item.message.prefix(40) == head || item.message == m.text
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
            }
        }
    }

    /// Persisted offline queue helpers.
    private func loadOfflineQueue() {
        if let data = UserDefaults.standard.data(forKey: offlineKey),
           let decoded = try? JSONDecoder().decode([OfflineMessage].self, from: data) {
            offlinePending = decoded
            return
        }
        // Migrate the original text-only queue without losing messages.
        if let legacy = UserDefaults.standard.array(forKey: offlineKey) as? [String] {
            offlinePending = legacy.map { OfflineMessage(text: $0) }
            saveOfflineQueue()
        }
    }

    private func saveOfflineQueue() {
        if let data = try? JSONEncoder().encode(offlinePending) {
            UserDefaults.standard.set(data, forKey: offlineKey)
        }
    }

    func flushOfflineQueue() async {
        while let item = offlinePending.first {
            do {
                _ = try await client.sendTurn(sessionId, message: item.text)
                offlinePending.removeFirst()
            } catch {
                break // still offline — keep the rest
            }
        }
        saveOfflineQueue()
        if offlinePending.isEmpty { queuedNote = nil }
    }

    func discardOffline(_ id: UUID) {
        offlinePending.removeAll { $0.id == id }
        saveOfflineQueue()
    }

    func cancelQueued(_ itemId: String) async {
        queuedItems.removeAll { $0.id == itemId }
        if queuedItems.isEmpty { queuedNote = nil }
        try? await client.cancelQueued(sessionId, itemId: itemId)
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
            guard type == "text_delta", let delta = ev["delta"] as? String,
                  let idx = messages.lastIndex(where: { $0.role == .tool }) else { return }
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
        if let idx = messages.lastIndex(where: { $0.role == .tool && $0.toolName == mapped.toolName }) {
            if finalize {
                messages[idx] = mapped
            } else if messages[idx].text.isEmpty && !mapped.text.isEmpty {
                messages[idx].text = mapped.text
            }
        } else {
            messages.append(mapped)
        }
        streamingIndex = nil
    }

    /// Replace the in-progress bubble with the canonical mapped message.
    private func upsertAssistant(from json: [String: Any], finalize: Bool) {
        let mapped = ChatMessage.fromAgentMessage(json)
        guard let idx = ensureStreamingBubble() else { return }
        var current = messages[idx]
        // Preserve streamed text while the canonical copy is incomplete.
        if finalize || !mapped.text.isEmpty {
            current = mapped
        } else if !current.text.isEmpty {
            current.thinking = mapped.thinking ?? current.thinking
            if mapped.toolCalls.isEmpty { current.toolCalls = mapped.toolCalls }
        }
        messages[idx] = current
        if finalize {
            streamingIndex = nil
        }
    }

    @discardableResult
    private func appendUserMessage(_ text: String) -> UUID {
        let message = ChatMessage(entryId: nil, role: .user, text: text, thinking: nil,
                                  toolCalls: [], toolActivity: nil,
                                  isError: false, toolName: nil, isSystemNote: false,
                                  model: nil, errorMessage: nil,
                                  timestamp: Int(Date().timeIntervalSince1970 * 1000))
        messages.append(message)
        streamingIndex = nil
        return message.id
    }
}
