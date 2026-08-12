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
    /// Coalesced streamed deltas: batched flushes (~90ms) keep scrolling
    /// smooth instead of re-rendering per token.
    private var pendingDelta = ""
    private var flushTask: Task<Void, Never>?
    /// Batched file_update pushes (avoid render storms right after open).
    private var pendingFileMessages: [ChatMessage] = []
    private var fileFlushTask: Task<Void, Never>?
    /// Set when older messages are prepended — the list scrolls back to this
    /// anchor so pagination doesn't visually jump.
    @Published var prependAnchor: String?
    /// Set when the host pi agent owns the session — needs user confirmation
    /// before we resume it from the app (would double-write the session file).
    @Published var confirmLiveResume = false
    private var pendingForceText: String?

    private let client: APIClient
    private let sessionId: String
    private var eventSource: EventSource?
    private var lastEventId: String?
    private var pollTask: Task<Void, Never>?

    /// Index of the assistant bubble currently receiving deltas.
    private var streamingIndex: Int?
    private var lastFrameTime = Date()

    init(client: APIClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
    }

    // MARK: - Lifecycle

    func start() async {
        await loadHistory()
        await loadQueue()
        openStream()
        startPolling()
    }

    func stop() {
        eventSource?.stop()
        pollTask?.cancel()
        pollTask = nil
    }

    /// Host-terminal / other-client activity reaches the app via the server's
    /// file-watch push (`file_update` SSE events). Polling is only a slow
    /// safety net in case the watcher is unavailable on the server.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { return }
                // Skip the poll while SSE is alive (it just delivered a frame):
                // the poll is only a safety net for missed file events.
                if Date().timeIntervalSince(self.lastFrameTime) > 30 {
                    await self.refreshFromServer()
                }
            }
        }
    }

    private func refreshFromServer() async {
        guard let page = try? await client.fetchMessages(sessionId, limit: 200) else { return }
        // Watchdog: clear the host-driven working indicator if the host agent
        // has been quiet for a while (no turn_end arrives in the file stream).
        if let t = fileActivityAt, Date().timeIntervalSince(t) > 25 {
            workingText = nil
            isStreaming = false
            fileActivityAt = nil
        }
        let fresh = page.messages.filter { !isDuplicate($0) }
        guard !fresh.isEmpty else { return }
        // Append only messages newer than everything we already have.
        let newestLocal = messages.compactMap { $0.timestamp }.max() ?? 0
        let newer = fresh.filter { ($0.timestamp ?? 0) >= newestLocal }
        if !newer.isEmpty {
            appendTail(newer)
        }
    }

    // MARK: - Actions

    func send(_ text: String, force: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingText = ""
        appendUserMessage(trimmed)
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
                queuedNote = "⏳ Queued — agent is busy, your message will go in when it finishes"
                workingText = nil
                if let id = resp.queueItemId {
                    queuedItems.append(QueueItem(id: id, message: trimmed, status: "queued",
                                                 queuedAt: nil, startedAt: nil, completedAt: nil, error: nil))
                }
            }
        } catch {
            isStreaming = false
            workingText = nil
            if case APIError.http(409, _, "session_live") = error {
                // Host agent owns the session — ask before double-writing.
                if force {
                    errorMessage = "Host agent is still using this session — the JSONL may interleave."
                } else {
                    pendingForceText = trimmed
                    confirmLiveResume = true
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// User confirmed: resume the host-owned session anyway (?force=1).
    func confirmResumeLive() {
        confirmLiveResume = false
        guard let text = pendingForceText else { return }
        pendingForceText = nil
        Task { await send(text, force: true) }
    }

    func abort() async {
        isStreaming = false
        try? await client.abortTurn(sessionId)
    }

    // MARK: - History (lazy, last-N pages)

    private func loadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100)
            messages = page.messages
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetch the next older page and prepend it (triggered at scroll top).
    func loadMore() async {
        guard hasMore, !loadingMore, let earliest = messages.min(by: { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) })?.timestamp else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100, before: earliest)
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
        guard let data = frame.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let id = frame.id { lastEventId = id }

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
                else { upsertAssistant(from: msg, finalize: true) }
            }
            isStreaming = false
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
            if let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? ""
                if role == "user" {
                    workingText = nil
                    isStreaming = false
                    let text = (msg["text"] as? String) ?? ""
                    if !text.isEmpty {
                        queuedItems.removeAll { item in item.message == text || item.message.prefix(40) == String(text.prefix(40)) }
                        if queuedItems.isEmpty { queuedNote = nil }
                    }
                } else {
                    workingText = role == "tool" ? "Running tool…" : "Writing…"
                    isStreaming = true
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
        streamingIndex = nil
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
        if let idx = streamingIndex, messages.indices.contains(idx) {
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

    private func appendUserMessage(_ text: String) {
        messages.append(ChatMessage(entryId: nil, role: .user, text: text, thinking: nil,
                                    toolCalls: [], toolActivity: nil,
                                    isError: false, toolName: nil, isSystemNote: false,
                                    model: nil, errorMessage: nil,
                                    timestamp: Int(Date().timeIntervalSince1970 * 1000)))
        streamingIndex = nil
    }
}
