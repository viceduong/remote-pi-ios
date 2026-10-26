import Foundation
import Combine

/**
 * Chat state for one session (unidirectional data flow):
 *
 *   SSE frames / REST pages / user intents
 *        → reducers (ChatMerger for rows, QueueReconciler for chips,
 *          AgentStatusState for status)
 *        → `commitNow()` derives the visible transcript ONCE per main-loop
 *          turn and publishes it to the UIKit table via `transcript`.
 *
 * High-frequency outputs are deliberately NOT `@Published` here:
 * - transcript rows go through a Combine subject consumed only by the table;
 * - working text / usage / stats live in `ChatLiveStatus`.
 * So ChatView itself only re-renders for low-frequency state.
 */
@MainActor
final class ChatViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    // MARK: Low-frequency published state (ChatView)

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var loadPhase: LoadPhase = .loading
    @Published private(set) var transcriptIsEmpty = true
    /// Unanswered `ask_user_question` questionnaire (card above the composer).
    /// Mirrored into the status reducer ("Waiting for your answer" even on
    /// servers without §7 activity).
    @Published private(set) var pendingQuestion: AgentQuestion? {
        didSet {
            if (oldValue == nil) != (pendingQuestion == nil) {
                status.apply(.questionCard(pendingQuestion != nil))
            }
        }
    }
    @Published var questionSelections: [Int: Set<String>] = [:]
    @Published var questionText: [Int: String] = [:]
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var queuedNote: String?
    /// Set after a successful fork — ChatView pops back to the session list.
    @Published private(set) var shouldDismiss = false

    /// Contract §11 model picker listing state.
    enum ModelListState: Equatable {
        case idle
        case loading
        case loaded([ModelEntry])
        case failed(String)
    }

    /// The session's current model: seeded from the summary `model` string,
    /// updated by `model_changed` frames, `GET /models` `current` and
    /// successful (optimistically applied) switches.
    @Published private(set) var currentModel: ModelRef?
    @Published private(set) var modelList: ModelListState = .idle

    // MARK: Outputs for focused observers

    let status = ChatLiveStatus()
    /// Ordered transcript rows (oldest → newest) for the UIKit table.
    let transcript = CurrentValueSubject<[TranscriptItem], Never>([])
    /// Asks the table to jump to the newest row (after the user sends).
    let scrollToBottomRequests = PassthroughSubject<Void, Never>()

    // MARK: Model state

    /// Full row model (visible + hidden rows). Every mutation schedules one
    /// coalesced commit.
    private(set) var messages: [ChatMessage] = [] { didSet { scheduleCommit() } }
    /// Rows passing the single visibility predicate (contract v2 §4).
    private(set) var visibleMessages: [ChatMessage] = []
    private(set) var hasMore = false

    private var serverQueue: [QueueItem] = [] { didSet { scheduleCommit() } }
    private var piQueue: [String] = [] { didSet { scheduleCommit() } }
    /// Sends in flight / acknowledged but not yet echoed as a user row.
    private var localPending: [QueueItem] = [] { didSet { scheduleCommit() } }
    private var cancelledLocal = Set<String>()
    /// Locally-queued sends while offline (persisted, flushed on reconnect).
    private var offlinePending: [OfflineMessage] = [] { didSet { scheduleCommit() } }

    private let client: APIClient
    private let sessionId: String
    private let offlineStore: OfflineQueueStore
    private var eventSource: EventSource?

    private var lifecycleActive = false
    private var suspended = false
    private var hasConnectedOnce = false
    /// Next `agent_status` after a (re)connect is the server snapshot.
    private var awaitingSnapshot = false
    /// Durable entry-id cursor for cheap reconnects (?since= fetch).
    private var lastSeenEntryId: String?
    /// Oldest timestamp actually fetched (pagination baseline).
    private var lowestFetchedTs: Int?
    private var loadingMore = false
    private var refreshInFlight = false
    private var refreshAgain = false
    private var flushingOffline = false
    /// Live tails may evict old rows only while the user follows the bottom.
    private var viewportNearBottom = true
    private var lastFrameAt = Date()
    private var lastAgentError: String?

    /// Row id of the assistant bubble receiving deltas (identity, not index).
    private var streamingId: String?
    /// Coalesced streamed deltas (~90ms flushes).
    private var pendingDelta = ""
    /// Batched file_update pushes.
    private var pendingFileMessages: [ChatMessage] = []
    /// Questionnaire ids the server resolved/dropped (§8) — a failed POST
    /// must not resurrect them.
    private var resolvedQuestionIds = Set<String>()
    /// Questionnaire whose answer POST is in flight (card already removed).
    private var answeringQuestionId: String?
    /// Send-now (§10) per server queue id: `.distantFuture` while the POST is
    /// in flight, then the acceptance time. While present the item renders
    /// as running ("sending", no buttons) even if a lagging `queue_update`
    /// still reports it `queued` — no flash back, no double steer.
    private var steering: [String: Date] = [:]
    /// How long an accepted steer keeps overriding a stale `queued` status.
    private static let steerGrace: TimeInterval = 30
    /// Model picker bookkeeping: a newer switch supersedes an older one; a
    /// `model_changed` frame received after a switch began wins over its
    /// revert-on-failure.
    private var modelSwitchSeq = 0
    private var modelFrameSeq = 0
    /// Number of switches whose POST is still in flight.
    private var modelSwitchInFlight = 0
    private var modelsLoadInFlight = false

    // MARK: Owned tasks (all cancelled in `stop()`)

    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var fileFlushTask: Task<Void, Never>?
    private var cacheSaveTask: Task<Void, Never>?
    private var loadWatchdog: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var networkCancellable: AnyCancellable?

    private var commitScheduled = false
    private var lastPublished: [TranscriptItem] = []
    private var lastCacheSignature: Int?
    private var pendingCacheSignature: Int?

    init(client: APIClient, sessionId: String, initialModel: String? = nil) {
        self.client = client
        self.sessionId = sessionId
        self.offlineStore = OfflineQueueStore(sessionId: sessionId)
        self.currentModel = ModelRef(summary: initialModel)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !lifecycleActive else { return }
        lifecycleActive = true
        suspended = false
        status.onBecameIdle = { [weak self] in
            self?.spawn { [weak self] in await self?.refreshStats() }
        }
        observeNetwork()
        // Instant open: render the on-disk snapshot, then reconcile.
        if messages.isEmpty,
           let snap = await SessionHistoryCache.shared.load(sessionId: sessionId),
           ChatMessage.hasVisibleContent(snap.messages) {
            messages = snap.messages
            hasMore = snap.hasMore
            lastSeenEntryId = snap.cursor
            loadPhase = .loaded
        }
        guard lifecycleActive else { return }
        await loadOfflineQueue()
        guard lifecycleActive else { return }
        openStream()
        startPolling()
        if loadPhase == .loaded, !messages.isEmpty {
            await refreshFromServer()
        } else {
            await loadHistory()
        }
        guard lifecycleActive else { return }
        await loadQueue()
    }

    func stop() {
        lifecycleActive = false
        flushPendingDelta()
        streamingId = nil
        eventSource?.stop()
        eventSource = nil
        for task in [pollTask, flushTask, fileFlushTask, cacheSaveTask, loadWatchdog, resetTask] {
            task?.cancel()
        }
        pollTask = nil
        flushTask = nil
        fileFlushTask = nil
        cacheSaveTask = nil
        loadWatchdog = nil
        resetTask = nil
        // In-flight sends observe cancellation and persist themselves to the
        // offline outbox (same clientMessageId → idempotent retry).
        for task in ownedTasks.values { task.cancel() }
        ownedTasks.removeAll()
        networkCancellable = nil
        status.onBecameIdle = nil
        pendingFileMessages.removeAll()
        saveCacheNow()
    }

    /// App went to the background: stop transport (iOS suspends sockets).
    /// The EventSource instance — and its Last-Event-ID cursor — is kept.
    func suspendNetwork() {
        guard lifecycleActive, !suspended else { return }
        suspended = true
        eventSource?.stop()
        pollTask?.cancel()
        pollTask = nil
        flushPendingDelta()
        saveCacheNow()
    }

    /// Back to the foreground: resume the SAME stream (Last-Event-ID replay
    /// or a `reset` frame); its `.connected` transition does the one refresh.
    func resumeNetwork() {
        guard lifecycleActive, suspended else { return }
        suspended = false
        if eventSource == nil { openStream() } else { eventSource?.start() }
        startPolling()
    }

    func setViewportNearBottom(_ value: Bool) {
        viewportNearBottom = value
    }

    func retryLoad() {
        spawn { [weak self] in await self?.loadHistory() }
    }

    // MARK: - Task ownership

    /// Run `operation` as a task owned (and cancelled) by this view model.
    private func spawn(_ operation: @escaping @MainActor () async -> Void) {
        let key = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.ownedTasks[key] = nil
        }
        ownedTasks[key] = task
    }

    private func surface(_ error: Error) {
        guard !APIClient.isCancellation(error) else { return }
        errorMessage = error.localizedDescription
    }

    private func observeNetwork() {
        networkCancellable = NetworkMonitor.shared.$satisfiedGeneration
            .dropFirst()
            .sink { [weak self] _ in
                self?.networkBecameAvailable()
            }
    }

    private func networkBecameAvailable() {
        guard lifecycleActive, !suspended else { return }
        if connectionState != .connected { eventSource?.reconnectNow() }
        spawn { [weak self] in await self?.flushOfflineQueue() }
    }

    /// Slow safety net — only does network work when the SSE stream is not
    /// live (or a v1 server left a stale busy flag).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.lifecycleActive else { return }
                await self.pollTick()
            }
        }
    }

    private func pollTick() async {
        let state = status.state
        if connectionState != .connected {
            await refreshFromServer()
            await loadQueue()
        } else if !state.v2, state.busy, Date().timeIntervalSince(lastFrameAt) > 45 {
            // v1 server: verify a busy flag nothing has refreshed lately.
            await refreshFromServer()
        }
        // Nothing confirmed the optimistic "Waiting…" — drop it.
        status.expireOptimistic(olderThan: 30)
        // Refresh chip age labels / expire stuck local chips.
        scheduleCommit()
    }

    // MARK: - Commit (single derivation point)

    private func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        Task { @MainActor [weak self] in
            self?.commitNow()
        }
    }

    /// Derive visible rows, chips and banners from the model. Runs at most
    /// once per main-loop turn; never runs during a SwiftUI `body`.
    func commitNow() {
        commitScheduled = false
        visibleMessages = messages.filter(ChatMessage.isVisibleInFocus)

        expireStaleLocalPending()
        pruneSteering()
        let reconciled = QueueReconciler.reconcile(localPending: steered(localPending),
                                                   server: steered(serverQueue),
                                                   piNative: piQueue, messages: messages)
        if !reconciled.deliveredLocal.isEmpty,
           localPending.contains(where: { reconciled.deliveredLocal.contains($0.clientMessageId ?? "") }) {
            localPending.removeAll { reconciled.deliveredLocal.contains($0.clientMessageId ?? "") }
        }
        dropDeliveredOffline()

        var items: [TranscriptItem] = []
        items.reserveCapacity(visibleMessages.count + reconciled.chips.count + offlinePending.count)
        for m in visibleMessages {
            items.append(ChatViewModel.transcriptItem(for: m, streaming: m.id == streamingId))
        }
        var chipClientIds = Set<String>()
        for chip in reconciled.chips {
            if let cid = chip.item.clientMessageId { chipClientIds.insert(cid) }
            let actions = ChatViewModel.chipActions(chip)
            items.append(TranscriptItem(
                id: chip.rowId, kind: .queued, text: chip.item.message,
                statusText: ChatViewModel.chipStatus(chip.item),
                cancellable: actions.cancellable,
                canSteer: actions.steerable,
                actionId: chip.serverId))
        }
        for o in offlinePending where !chipClientIds.contains(o.clientMessageId) {
            items.append(TranscriptItem(
                id: "o:" + o.id.uuidString, kind: .offline, text: o.text,
                statusText: "waiting for connection", cancellable: true,
                actionId: o.id.uuidString))
        }

        if items != lastPublished {
            lastPublished = items
            transcript.send(items)
        }
        let empty = items.isEmpty
        if transcriptIsEmpty != empty { transcriptIsEmpty = empty }

        let waiting = reconciled.chips.filter { $0.item.status == "queued" }.count
        let note: String? = waiting == 0 ? nil
            : waiting == 1 ? "⏳ Queued — agent is busy, your message will go in when it finishes"
            : "⏳ \(waiting) messages queued"
        if queuedNote != note { queuedNote = note }

        scheduleCacheSave()
    }

    nonisolated static func transcriptItem(for m: ChatMessage, streaming: Bool) -> TranscriptItem {
        if let qa = m.qa {
            return TranscriptItem(id: m.id, kind: .qa, text: qa.transcriptText, entryId: m.entryId,
                                  statusText: qa.cancelled ? "Declined" : "Answered", qa: qa)
        }
        switch m.role {
        case .user:
            return TranscriptItem(id: m.id, kind: .user, text: m.text, entryId: m.entryId)
        case .assistant, .tool:
            if m.isErrorRow {
                var text = m.text
                if !text.hasVisibleCharacters {
                    text = (m.errorMessage?.hasVisibleCharacters == true) ? m.errorMessage! : "Error"
                }
                return TranscriptItem(id: m.id, kind: .error, text: text, entryId: m.entryId)
            }
            return TranscriptItem(id: m.id, kind: .assistant, text: m.text, entryId: m.entryId,
                                  streaming: streaming)
        }
    }

    /// A chip can be cancelled / steered only when it is a still-`queued`
    /// server item with a server queue id: pi-native rows (no id) and local
    /// "sending" chips that have not reached the server yet are neither. Both
    /// actions key off the same server queue id (`chip.serverId`).
    nonisolated static func chipActions(_ chip: QueueChip) -> (cancellable: Bool, steerable: Bool) {
        let eligible = chip.item.status == "queued" && chip.origin != .piNative && chip.serverId != nil
        return (eligible, eligible)
    }

    nonisolated private static func chipStatus(_ item: QueueItem) -> String {
        if item.status != "queued" { return "sending" }
        var parts = ["queued"]
        if let at = item.queuedAt {
            let elapsed = Int(Date().timeIntervalSince1970 * 1000 - TimeInterval(at)) / 1000
            if elapsed >= 60 {
                parts.append(elapsed >= 3600 ? "\(elapsed / 3600)h" : "\(elapsed / 60)m")
            }
        }
        return parts.joined(separator: " · ")
    }

    private static var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Local chips that were acknowledged as delivered but never matched an
    /// echo (e.g. v1 server, edited text) must not stick forever.
    private func expireStaleLocalPending() {
        let now = ChatViewModel.nowMs
        let serverCids = Set(serverQueue.compactMap(\.clientMessageId))
        // Delivered-but-never-echoed "running" chips: drop them (the message is
        // on the server; a refresh surfaces the real user row).
        let isStale: (QueueItem) -> Bool = { item in
            item.status == "running"
                && !serverCids.contains(item.clientMessageId ?? "")
                && now - (item.queuedAt ?? now) > 90_000
        }
        if localPending.contains(where: isStale) { localPending.removeAll(where: isStale) }

        // Safety net for a chip stuck in "sending": `deliver` always resolves a
        // send within the request timeout (to running/queued/offline/error), so
        // a "sending" chip older than that means its delivery task was lost. Re-
        // queue it to the offline outbox — it retries idempotently (server
        // dedupes on clientMessageId) and shows a visible "waiting for
        // connection" state instead of an indefinite, silent "sending".
        let stuckSending = localPending.filter {
            $0.status == "sending" && now - ($0.queuedAt ?? now) > 60_000
        }
        if !stuckSending.isEmpty {
            let stuckIds = Set(stuckSending.map(\.id))
            localPending.removeAll { stuckIds.contains($0.id) }
            for item in stuckSending {
                let cid = item.clientMessageId ?? UUID().uuidString
                spawn { [weak self] in await self?.enqueueOffline(item.message, clientMessageId: cid) }
            }
        }
    }

    /// Offline items the server already has (lost response) are delivered.
    private func dropDeliveredOffline() {
        guard !offlinePending.isEmpty else { return }
        var known = Set(serverQueue.compactMap(\.clientMessageId))
        for m in messages where m.role == .user {
            if let cid = m.clientMessageId { known.insert(cid) }
        }
        guard offlinePending.contains(where: { known.contains($0.clientMessageId) }) else { return }
        offlinePending.removeAll { known.contains($0.clientMessageId) }
        let snapshot = offlinePending
        let store = offlineStore
        spawn { await store.save(snapshot) }
    }

    // MARK: - Cache

    private func cacheableMessages() -> [ChatMessage] {
        let tail = messages.suffix(SessionHistoryCache.maxMessages)
        guard let sid = streamingId else { return Array(tail) }
        return tail.filter { $0.id != sid }
    }

    /// Debounced (2s after the last change), content-gated, written off-main
    /// by the cache actor.
    private func scheduleCacheSave() {
        guard lifecycleActive, loadPhase == .loaded, !messages.isEmpty else { return }
        let signature = SessionHistoryCache.signature(messages: messages, hasMore: hasMore, cursor: lastSeenEntryId)
        guard signature != lastCacheSignature, signature != pendingCacheSignature else { return }
        pendingCacheSignature = signature
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.lastCacheSignature = signature
            self.pendingCacheSignature = nil
            let rows = self.cacheableMessages()
            await SessionHistoryCache.shared.save(sessionId: self.sessionId, messages: rows,
                                                  hasMore: self.hasMore, cursor: self.lastSeenEntryId)
        }
    }

    private func saveCacheNow() {
        guard loadPhase == .loaded, !messages.isEmpty else { return }
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        pendingCacheSignature = nil
        let rows = cacheableMessages()
        let id = sessionId
        let more = hasMore
        let cursor = lastSeenEntryId
        lastCacheSignature = SessionHistoryCache.signature(messages: messages, hasMore: hasMore, cursor: lastSeenEntryId)
        // Short-lived write on the cache actor; the actor itself skips it
        // when the content signature is unchanged.
        Task.detached(priority: .utility) {
            await SessionHistoryCache.shared.save(sessionId: id, messages: rows, hasMore: more, cursor: cursor)
        }
    }

    // MARK: - Server reconciliation

    private func advanceCursor(_ page: [ChatMessage]) {
        if let last = page.last(where: { $0.entryId != nil })?.entryId {
            lastSeenEntryId = last
        }
    }

    private func noteLowest(_ page: [ChatMessage]) {
        guard let low = page.compactMap(\.timestamp).min() else { return }
        lowestFetchedTs = min(lowestFetchedTs ?? Int.max, low)
    }

    /// Tool rows are never rendered (focus mode is fixed on) — keep them out
    /// of the model entirely. Exception: Q&A rows (contract §9).
    nonisolated static func displayable(_ rows: [ChatMessage]) -> [ChatMessage] {
        rows.filter { $0.role != .tool || $0.qa != nil }
    }

    /// Delta refresh by entry-id cursor. Coalesced: concurrent callers share
    /// one in-flight request (plus at most one follow-up).
    private func refreshFromServer() async {
        guard lifecycleActive else { return }
        if refreshInFlight {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshAgain = false
            await performRefresh()
        } while refreshAgain && lifecycleActive
    }

    private func performRefresh() async {
        let cursor = lastSeenEntryId
        do {
            let page = try await client.fetchMessages(sessionId, limit: cursor == nil ? 100 : 200, since: cursor)
            guard lifecycleActive else { return }
            if let working = page.working { status.apply(.legacyBusy(working)) }
            let rows = ChatViewModel.displayable(page.messages)
            let isDelta = cursor != nil && (page.cursorMode ?? true)
            if isDelta {
                // Empty delta = nothing new: a successful no-op.
                guard !page.messages.isEmpty else { return }
                ChatMerger.merge(&messages, rows)
            } else {
                ChatMerger.replaceTail(&messages, with: rows)
                hasMore = page.hasMore
                noteLowest(page.messages)
                if loadPhase != .loaded { loadPhase = .loaded }
            }
            advanceCursor(page.messages)
            evictLiveTailIfNeeded()
        } catch {
            // Background reconciliation: transient failures are retried by
            // the next reconnect/poll; never alert.
        }
    }

    /// SSE `reset` (contract v2 §1): full tail reload REPLACING the tail.
    private func scheduleResetReload() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.client.fetchMessages(self.sessionId, limit: 100)
                guard self.lifecycleActive, !Task.isCancelled else { return }
                self.flushPendingDelta()
                ChatMerger.replaceTail(&self.messages, with: ChatViewModel.displayable(page.messages))
                self.hasMore = page.hasMore
                self.noteLowest(page.messages)
                self.advanceCursor(page.messages)
                if let working = page.working { self.status.apply(.legacyBusy(working)) }
                if self.loadPhase != .loaded { self.loadPhase = .loaded }
            } catch {
                // Cancelled or transient — the next reconnect retries.
            }
            await self.loadQueue()
        }
    }

    // MARK: - History

    private func loadHistory() async {
        guard lifecycleActive else { return }
        if messages.isEmpty { loadPhase = .loading }
        startLoadWatchdog()
        defer {
            loadWatchdog?.cancel()
            loadWatchdog = nil
        }
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100)
            guard lifecycleActive else { return }
            ChatMerger.replaceTail(&messages, with: ChatViewModel.displayable(page.messages))
            hasMore = page.hasMore
            noteLowest(page.messages)
            advanceCursor(page.messages)
            if let working = page.working { status.apply(.legacyBusy(working)) }
            // Blank-page guard: a tail that is one long tool loop has nothing
            // visible — fetch the newest VISIBLE rows (server ?visible=1).
            if !ChatMessage.hasVisibleContent(messages), hasMore,
               let visible = try? await client.fetchMessages(sessionId, limit: 100, visibleOnly: true),
               lifecycleActive {
                ChatMerger.merge(&messages, ChatViewModel.displayable(visible.messages))
                hasMore = visible.hasMore
                noteLowest(visible.messages)
            }
            loadPhase = .loaded
        } catch {
            guard !APIClient.isCancellation(error) else { return }
            loadPhase = messages.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    /// Safety net: the spinner can never stay up forever.
    private func startLoadWatchdog() {
        loadWatchdog?.cancel()
        loadWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.loadPhase == .loading else { return }
            self.loadPhase = self.messages.isEmpty
                ? .failed("Timed out loading the conversation.")
                : .loaded
        }
    }

    /// Fetch older pages (triggered near the top of the transcript). Keeps
    /// going (bounded) while pages add nothing visible.
    func loadMore() {
        guard lifecycleActive, hasMore, !loadingMore, loadPhase == .loaded else { return }
        loadingMore = true
        spawn { [weak self] in
            guard let self else { return }
            defer { self.loadingMore = false }
            for _ in 0..<5 {
                guard self.lifecycleActive, self.hasMore else { return }
                let localMin = self.messages.compactMap(\.timestamp).min()
                guard let earliest = [localMin, self.lowestFetchedTs].compactMap({ $0 }).min() else {
                    return
                }
                let visibleBefore = self.visibleMessages.count
                do {
                    let page = try await self.client.fetchMessages(self.sessionId, limit: 100, before: earliest)
                    guard self.lifecycleActive else { return }
                    guard !page.messages.isEmpty else {
                        self.hasMore = false
                        return
                    }
                    ChatMerger.merge(&self.messages, ChatViewModel.displayable(page.messages))
                    self.hasMore = page.hasMore
                    self.noteLowest(page.messages)
                    let addedVisible = ChatViewModel.displayable(page.messages).contains(where: ChatMessage.isVisibleInFocus)
                    if addedVisible || self.visibleMessages.count != visibleBefore { return }
                } catch {
                    return // transient — the next scroll retries
                }
            }
        }
    }

    /// Bound live-tail memory. Only while following the bottom, so rows above
    /// the viewport never shift (and only far above it: the table is inverted,
    /// the oldest rows are the farthest from the viewport).
    private func evictLiveTailIfNeeded() {
        guard messages.count > 1_500, viewportNearBottom else { return }
        messages.removeFirst(messages.count - 1_000)
        hasMore = true
        lowestFetchedTs = messages.compactMap(\.timestamp).min()
    }

    // MARK: - Actions

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clientMessageId = UUID().uuidString
        // UX: the prompt shows as a chip immediately and turns into a real
        // bubble when the server echoes the user row (clientMessageId first).
        localPending.append(QueueItem(id: "pending:\(clientMessageId)", clientMessageId: clientMessageId,
                                      message: trimmed, status: "sending", queuedAt: ChatViewModel.nowMs))
        status.apply(.optimisticSend)
        scrollToBottomRequests.send(())
        spawn { [weak self] in
            await self?.deliver(trimmed, clientMessageId: clientMessageId, force: false)
        }
    }

    private func updateLocal(_ clientMessageId: String, _ transform: (QueueItem) -> QueueItem) {
        guard let i = localPending.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return }
        localPending[i] = transform(localPending[i])
    }

    private func deliver(_ text: String, clientMessageId: String, force: Bool) async {
        do {
            let resp = try await client.sendTurn(sessionId, message: text, force: force,
                                                 clientMessageId: clientMessageId)
            let delivered = resp.dispatched == true || !resp.queued
            if cancelledLocal.remove(clientMessageId) != nil {
                localPending.removeAll { $0.clientMessageId == clientMessageId }
                if !delivered, let qid = resp.queueItemId {
                    try? await client.cancelQueued(sessionId, itemId: qid)
                }
                return
            }
            updateLocal(clientMessageId) { item in
                QueueItem(id: resp.queueItemId ?? item.id, clientMessageId: clientMessageId,
                          message: item.message, status: delivered ? "running" : "queued",
                          queuedAt: item.queuedAt)
            }
            if connectionState != .connected { await refreshFromServer() }
        } catch {
            localPending.removeAll { $0.clientMessageId == clientMessageId }
            status.apply(.clearOptimistic)
            if APIClient.isCancellation(error) {
                // Owner went away mid-request. Keep the text: it retries with
                // the same clientMessageId (server dedupes).
                await enqueueOffline(text, clientMessageId: clientMessageId)
                return
            }
            if case APIError.offline = error {
                await enqueueOffline(text, clientMessageId: clientMessageId)
                return
            }
            if case APIError.http(409, _, "session_live") = error, !force {
                // One-shot takeover of a read-only mirror (?force=1).
                localPending.append(QueueItem(id: "pending:\(clientMessageId)", clientMessageId: clientMessageId,
                                              message: text, status: "sending", queuedAt: ChatViewModel.nowMs))
                status.apply(.optimisticSend)
                await deliver(text, clientMessageId: clientMessageId, force: true)
                return
            }
            if case APIError.http(409, _, "session_live") = error {
                errorMessage = "Host Pi owns this session — stop it in the terminal before sending here."
                return
            }
            surface(error)
        }
    }

    private func enqueueOffline(_ text: String, clientMessageId: String) async {
        let id = UUID(uuidString: clientMessageId) ?? UUID()
        guard !offlinePending.contains(where: { $0.id == id }) else { return }
        guard offlinePending.count < 100 else {
            errorMessage = "Offline queue is full (100 messages). Reconnect or discard one first."
            return
        }
        offlinePending.append(OfflineMessage(text: text, id: id))
        await offlineStore.save(offlinePending)
    }

    func abort() {
        spawn { [weak self] in
            guard let self else { return }
            do {
                try await self.client.abortTurn(self.sessionId)
                self.status.apply(.clearOptimistic)
                self.status.apply(.legacyBusy(false))
            } catch {
                self.surface(error)
            }
        }
    }

    func requestFork(entryId: String?, name: String) {
        spawn { [weak self] in
            guard let self else { return }
            do {
                let (forked, text) = try await self.client.forkSession(self.sessionId, entryId: entryId, name: name)
                self.infoMessage = "Forked → \(forked.name)" + (text.map { ": \(String($0.prefix(40)))" } ?? "")
                try await Task.sleep(nanoseconds: 1_200_000_000)
                self.shouldDismiss = true
            } catch {
                self.surface(error)
            }
        }
    }

    func cancelQueued(_ serverItemId: String) {
        serverQueue.removeAll { $0.id == serverItemId }
        if let local = localPending.first(where: { $0.id == serverItemId }), let cid = local.clientMessageId {
            cancelledLocal.insert(cid)
            localPending.removeAll { $0.id == serverItemId }
        }
        spawn { [weak self] in
            guard let self else { return }
            do {
                try await self.client.cancelQueued(self.sessionId, itemId: serverItemId)
            } catch {
                self.surface(error)
                await self.loadQueue()
            }
        }
    }

    /// Contract §10 "send now": promote a queued item into the running turn.
    /// Optimistic — the chip flips to running/"sending" at once via the
    /// `steering` overlay (same stable row id, so it never duplicates, and a
    /// lagging `queue_update` cannot flip it back); the user-row echo
    /// reconciles it away exactly like a normal dispatch. A second tap (or
    /// a tap on a chip that is no longer queued) is ignored, so a duplicate
    /// POST can never 404 and "restore" a chip whose steer is succeeding.
    /// On failure the overlay is dropped (chip back to queued + send-now)
    /// and the error surfaced.
    func steerQueued(_ serverItemId: String) {
        guard steering[serverItemId] == nil else { return }
        let isQueued = serverQueue.contains { $0.id == serverItemId && $0.status == "queued" }
            || localPending.contains { $0.id == serverItemId && $0.status == "queued" }
        guard isQueued else { return }
        steering[serverItemId] = .distantFuture
        scheduleCommit()
        status.apply(.optimisticSend)
        scrollToBottomRequests.send(())
        spawn { [weak self] in
            guard let self else { return }
            do {
                try await self.client.steerQueued(self.sessionId, itemId: serverItemId)
                if self.steering[serverItemId] != nil {
                    self.steering[serverItemId] = Date()
                    self.scheduleCommit()
                }
                // On a live stream the echo + queue_update reconcile the chip;
                // without one, pull server truth now.
                if self.connectionState != .connected {
                    await self.refreshFromServer()
                    await self.loadQueue()
                }
            } catch {
                self.steering[serverItemId] = nil
                self.scheduleCommit()
                guard !APIClient.isCancellation(error) else { return }
                // Delivery failed (§10: 404/409/502) — the item stays queued
                // server-side (or is gone: 404); re-sync the queue.
                self.status.apply(.clearOptimistic)
                self.surface(error)
                await self.loadQueue()
            }
        }
    }

    /// Items with a send-now in flight / just accepted render as running.
    private func steered(_ items: [QueueItem]) -> [QueueItem] {
        guard !steering.isEmpty else { return items }
        return items.map { item in
            guard item.status == "queued", steering[item.id] != nil else { return item }
            return QueueItem(id: item.id, clientMessageId: item.clientMessageId, message: item.message,
                             status: "running", queuedAt: item.queuedAt)
        }
    }

    /// Drop overlay entries whose item is gone, or whose accepted steer is
    /// older than the grace period (server truth wins again). In-flight
    /// entries stay until their request resolves.
    private func pruneSteering() {
        guard !steering.isEmpty else { return }
        let now = Date()
        let known = Set(serverQueue.map(\.id)).union(localPending.map(\.id))
        steering = steering.filter { entry in
            if entry.value == .distantFuture { return true }
            return known.contains(entry.key) && now.timeIntervalSince(entry.value) < Self.steerGrace
        }
    }

    func discardOffline(_ id: UUID) {
        offlinePending.removeAll { $0.id == id }
        let snapshot = offlinePending
        let store = offlineStore
        spawn { await store.save(snapshot) }
    }

    // MARK: - Queue

    /// Server truth from /queue (durable outbox).
    func loadQueue() async {
        if let items = try? await client.fetchQueue(sessionId), lifecycleActive {
            let active = items.filter(\.isActive)
            if active != serverQueue { serverQueue = active }
        }
        await refreshStats()
    }

    private func refreshStats() async {
        if let stats = try? await client.fetchStats(sessionId) {
            status.setStats(stats)
        }
    }

    // MARK: - Model picker (contract §11)

    /// Models of the current listing (empty until loaded).
    var availableModels: [ModelEntry] {
        if case .loaded(let models) = modelList { return models }
        return []
    }

    /// Fetch `GET /models`. A refresh keeps the previous list visible; a
    /// failure with no list yet shows the error state (retry from the sheet).
    func loadModels() {
        guard !modelsLoadInFlight else { return }
        modelsLoadInFlight = true
        let hadList: Bool
        if case .loaded = modelList { hadList = true } else { hadList = false }
        if !hadList { modelList = .loading }
        spawn { [weak self] in
            guard let self else { return }
            defer { self.modelsLoadInFlight = false }
            do {
                let listing = try await self.client.listModels(self.sessionId)
                self.adoptListing(listing)
            } catch {
                if APIClient.isCancellation(error) {
                    if !hadList { self.modelList = .idle }
                    return
                }
                if !hadList { self.modelList = .failed(error.localizedDescription) }
            }
        }
    }

    /// Switch the session's model (allowed while busy — pi applies it from
    /// the next turn). Optimistic: `currentModel` moves at once and reverts
    /// on failure (unless a newer switch or a `model_changed` frame has
    /// superseded it); the error is surfaced through `errorMessage`.
    func switchModel(_ entry: ModelEntry) {
        let target = entry.ref
        if let current = currentModel, current.id == target.id, current.provider == target.provider {
            return
        }
        let previous = currentModel
        modelSwitchSeq += 1
        let seq = modelSwitchSeq
        let frameSeq = modelFrameSeq
        currentModel = target
        modelSwitchInFlight += 1
        spawn { [weak self] in
            guard let self else { return }
            defer { self.modelSwitchInFlight -= 1 }
            do {
                let applied = try await self.client.setModel(self.sessionId, provider: entry.provider,
                                                             modelId: entry.id)
                guard seq == self.modelSwitchSeq, frameSeq == self.modelFrameSeq else { return }
                if let applied { self.applyCurrentModel(applied) }
            } catch {
                guard seq == self.modelSwitchSeq, frameSeq == self.modelFrameSeq else { return }
                self.currentModel = previous
                self.surface(error)
            }
        }
    }

    /// Adopt a server-reported model, filling the display name from the
    /// listing when the report carries none. Equality-gated.
    /// Install a fetched listing. A listing fetched mid-switch must not undo
    /// the optimistic pick; otherwise it names a summary-seeded current model.
    private func adoptListing(_ listing: ModelListing) {
        modelList = .loaded(listing.models)
        if let current = listing.current, modelSwitchInFlight == 0 {
            applyCurrentModel(current)
        } else if let current = currentModel, current.name == nil,
                  let entry = listing.models.first(where: current.matches) {
            currentModel = entry.ref
        }
    }

    private func applyCurrentModel(_ ref: ModelRef) {
        var resolved = ref
        if resolved.name == nil, let entry = availableModels.first(where: ref.matches) {
            resolved = entry.ref
        }
        if currentModel != resolved { currentModel = resolved }
    }

    // MARK: - Offline outbox

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
            await offlineStore.save(offlinePending)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } else if let legacy = UserDefaults.standard.array(forKey: legacyKey) as? [String] {
            offlinePending = legacy.prefix(100).map { OfflineMessage(text: $0) }
            await offlineStore.save(offlinePending)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    /// Resend the outbox with each item's ORIGINAL clientMessageId, so a send
    /// whose response was lost can never be delivered twice.
    func flushOfflineQueue() async {
        guard !flushingOffline, !offlinePending.isEmpty else { return }
        flushingOffline = true
        defer { flushingOffline = false }
        while lifecycleActive, let item = offlinePending.first {
            do {
                let resp = try await client.sendTurn(sessionId, message: item.text,
                                                     clientMessageId: item.clientMessageId)
                offlinePending.removeAll { $0.id == item.id }
                let delivered = resp.dispatched == true || !resp.queued
                localPending.append(QueueItem(id: resp.queueItemId ?? "pending:\(item.clientMessageId)",
                                              clientMessageId: item.clientMessageId, message: item.text,
                                              status: delivered ? "running" : "queued",
                                              queuedAt: ChatViewModel.nowMs))
            } catch {
                if APIClient.isCancellation(error) { break }
                // Poison message (4xx): drop it, surface, keep flushing.
                if case APIError.http(let code, let message, _) = error, (400..<500).contains(code) {
                    offlinePending.removeAll { $0.id == item.id }
                    errorMessage = "Message dropped: \(message)"
                    continue
                }
                break // still offline — keep the rest
            }
        }
        await offlineStore.save(offlinePending)
    }

    // MARK: - Questionnaire

    /// View entry points: the work runs in a task owned by this view model.
    func submitQuestionAction() {
        spawn { [weak self] in await self?.submitQuestion() }
    }

    func cancelQuestionAction() {
        spawn { [weak self] in await self?.cancelQuestion() }
    }

    func chatAboutQuestionAction() {
        spawn { [weak self] in await self?.chatAboutQuestion() }
    }

    /// Every question has a selection or typed text (Submit enabled).
    var questionIsComplete: Bool {
        guard let question = pendingQuestion else { return false }
        return ChatViewModel.isComplete(question, selections: questionSelections, text: questionText)
    }

    nonisolated static func isComplete(_ question: AgentQuestion,
                                       selections: [Int: Set<String>],
                                       text: [Int: String]) -> Bool {
        question.items.allSatisfy { item in
            let picked = item.options.contains { (selections[item.index] ?? []).contains($0.label) }
            return picked || (text[item.index] ?? "").hasVisibleCharacters
        }
    }

    /// pi's QuestionAnswer shape (contract §8):
    /// - single option → `option`, answer = label;
    /// - typed text (no option) → `custom`, answer = text;
    /// - multi with selections → `multi`, selected = labels, answer = labels
    ///   joined ", ", typed text as `notes`.
    /// Questions with neither are skipped (Submit is disabled until complete).
    nonisolated static func buildAnswers(_ question: AgentQuestion,
                                         selections: [Int: Set<String>],
                                         text: [Int: String]) -> [APIClient.QuestionAnswerPayload] {
        var answers: [APIClient.QuestionAnswerPayload] = []
        for item in question.items {
            let typed = text[item.index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let selected = selections[item.index] ?? []
            let labels = item.options.map(\.label).filter { selected.contains($0) }
            if item.multiSelect, !labels.isEmpty {
                answers.append(.init(questionIndex: item.index, question: item.question,
                                     kind: "multi", answer: labels.joined(separator: ", "),
                                     selected: labels, notes: typed.isEmpty ? nil : typed,
                                     preview: nil))
            } else if !item.multiSelect, let label = labels.first {
                let preview = item.options.first { $0.label == label }?.preview
                answers.append(.init(questionIndex: item.index, question: item.question,
                                     kind: "option", answer: label, selected: nil,
                                     notes: typed.isEmpty ? nil : typed, preview: preview))
            } else if !typed.isEmpty {
                answers.append(.init(questionIndex: item.index, question: item.question,
                                     kind: "custom", answer: typed, selected: nil,
                                     notes: nil, preview: nil))
            }
        }
        return answers
    }

    /// "Chat about this": answer every question with kind `chat`.
    nonisolated static func chatAnswers(_ question: AgentQuestion) -> [APIClient.QuestionAnswerPayload] {
        question.items.map { item in
            APIClient.QuestionAnswerPayload(questionIndex: item.index, question: item.question, kind: "chat",
                                            answer: "Chat about this", selected: nil, notes: nil, preview: nil)
        }
    }

    /// Build and POST the questionnaire answers.
    func submitQuestion() async {
        guard let question = pendingQuestion, questionIsComplete else { return }
        let answers = ChatViewModel.buildAnswers(question, selections: questionSelections, text: questionText)
        guard !answers.isEmpty else { return }
        await sendQuestionAnswers(question.requestId, answers: answers, cancelled: false)
    }

    func chatAboutQuestion() async {
        guard let question = pendingQuestion else { return }
        await sendQuestionAnswers(question.requestId, answers: ChatViewModel.chatAnswers(question),
                                  cancelled: false)
    }

    func cancelQuestion() async {
        guard let question = pendingQuestion else { return }
        await sendQuestionAnswers(question.requestId, answers: [], cancelled: true)
    }

    private func sendQuestionAnswers(_ requestId: String,
                                     answers: [APIClient.QuestionAnswerPayload],
                                     cancelled: Bool) async {
        let answered = pendingQuestion
        let selections = questionSelections
        let text = questionText
        answeringQuestionId = requestId
        pendingQuestion = nil
        questionSelections = [:]
        questionText = [:]
        defer { if answeringQuestionId == requestId { answeringQuestionId = nil } }
        do {
            try await client.answerQuestion(sessionId, requestId: requestId,
                                            answers: answers, cancelled: cancelled)
        } catch {
            // The answer didn't reach the server: restore the card (with the
            // user's choices) unless the server resolved it meanwhile or a
            // newer questionnaire replaced it. A cancelled request (view gone)
            // is not surfaced as an error.
            if let answered, pendingQuestion == nil, !resolvedQuestionIds.contains(requestId) {
                pendingQuestion = answered
                questionSelections = selections
                questionText = text
            }
            surface(error)
        }
    }

    /// Server says this questionnaire is no longer pending (§8).
    private func markQuestionResolved(_ requestId: String) {
        resolvedQuestionIds.insert(requestId)
        guard pendingQuestion?.requestId == requestId else { return }
        pendingQuestion = nil
        questionSelections = [:]
        questionText = [:]
    }

    // MARK: - SSE

    private func openStream() {
        if let eventSource {
            eventSource.start()
            return
        }
        guard var components = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: true) else { return }
        components.path += "/api/sessions/\(sessionId)/events"
        components.queryItems = [URLQueryItem(name: "skeleton", value: "1")]
        guard let url = components.url else { return }
        let source = EventSource(url: url, token: client.token)
        source.onStateChange = { [weak self] state in
            self?.handleConnection(state)
        }
        source.onFrames = { [weak self] frames in
            self?.handle(frames)
        }
        source.onError = { [weak self] message in
            guard message.contains("401") || message.contains("403") || message.contains("404") else { return }
            self?.errorMessage = "Event stream unavailable: \(message)"
        }
        eventSource = source
        source.start()
    }

    private func handleConnection(_ state: EventSource.State) {
        switch state {
        case .connected:
            if connectionState != .connected { connectionState = .connected }
            awaitingSnapshot = true
            let isReconnect = hasConnectedOnce
            hasConnectedOnce = true
            // file_update frames are live-only (never replayed), so a
            // reconnect reconciles from server truth — exactly once.
            spawn { [weak self] in
                guard let self else { return }
                if isReconnect {
                    await self.refreshFromServer()
                    await self.loadQueue()
                }
                await self.flushOfflineQueue()
            }
        case .connecting:
            if connectionState != .connecting { connectionState = .connecting }
        case .disconnected:
            if connectionState != .disconnected { connectionState = .disconnected }
        }
    }

    private func handle(_ frames: [ParsedSSEFrame]) {
        guard lifecycleActive else { return }
        lastFrameAt = Date()
        for frame in frames { handle(frame) }
        evictLiveTailIfNeeded()
    }

    #if DEBUG
    /// Test seam: feed parsed SSE frames through the real frame handler
    /// without opening a stream (snapshot/integration tests only).
    func ingestForTesting(_ frames: [ParsedSSEFrame]) {
        lifecycleActive = true
        handle(frames)
    }

    /// Test seam: install a model listing as if `GET /models` returned it.
    func seedModelsForTesting(_ listing: ModelListing) {
        adoptListing(listing)
    }
    #endif

    private func handle(_ frame: ParsedSSEFrame) {
        if frame.isReset {
            scheduleResetReload()
            return
        }
        guard let obj = frame.payload else { return }
        switch frame.type {
        case "agent_status":
            handleAgentStatus(obj)
        case "agent_start", "turn_start":
            status.apply(.legacyBusy(true))
        case "agent_end", "agent_settled":
            flushPendingDelta()
            status.apply(.legacyBusy(false))
        case "agent_exited":
            status.apply(.exited)
        case "agent_crashed":
            status.apply(.crashed)
        case "tool_execution_start":
            status.apply(.activity(AgentActivity(kind: .tool, tool: obj["toolName"] as? String)))
        case "tool_execution_end":
            status.apply(.activity(AgentActivity(kind: .waiting)))
        case "tool_execution_update":
            status.apply(.activity(nil))
        case "message_start":
            handleMessageStart(obj)
        case "message_update":
            handleMessageUpdate(obj)
        case "message_end":
            handleMessageEnd(obj)
        case "file_update":
            handleFileUpdate(obj)
        case "queue_update":
            handleQueueUpdate(obj)
        case "agent_question":
            if let question = AgentQuestion(json: obj) {
                // Same card re-sent (reconnect replay): keep the user's picks.
                if pendingQuestion?.requestId != question.requestId {
                    questionSelections = [:]
                    questionText = [:]
                }
                resolvedQuestionIds.remove(question.requestId)
                pendingQuestion = question
            }
        case "model_changed":
            // §11: live frame `{provider, id, name}` (a nested `model` object
            // is tolerated) — switches from this or another client, or from
            // the host TUI.
            if let ref = ModelRef(json: obj) ?? ModelRef(json: obj["model"] as? [String: Any]) {
                modelFrameSeq += 1
                applyCurrentModel(ref)
            }
        case "agent_question_resolved":
            if let resolvedId = obj["requestId"] as? String {
                markQuestionResolved(resolvedId)
            } else if let current = pendingQuestion?.requestId {
                markQuestionResolved(current)
            }
        default:
            break
        }
    }

    /// Contract v2 §5: `agent_status` is the single source of truth.
    private func handleAgentStatus(_ obj: [String: Any]) {
        let v2 = obj["busy"] != nil || obj["owner"] != nil
        let busy: Bool
        if let value = obj["busy"] as? Bool {
            busy = value
        } else if let value = obj["working"] as? Bool {
            busy = value
        } else {
            let phase = obj["phase"] as? String
            busy = phase == "streaming" || phase == "waiting"
        }
        let snapshot = awaitingSnapshot
        awaitingSnapshot = false
        if !busy { flushPendingDelta() }
        // §7: the key's presence (even null) marks an activity-aware server.
        let hasActivity = obj.keys.contains("activity")
        let activity = (obj["activity"] as? [String: Any]).flatMap(AgentActivity.init(json:))
        status.apply(.status(busy: busy, owner: obj["owner"] as? String, v2: v2, isSnapshot: snapshot,
                             activity: activity, hasActivity: hasActivity))
        // §8: `questionId` mirrors the server's pending questionnaire — any
        // card (or in-flight answer) with a different id is stale.
        if obj.keys.contains("questionId") {
            let questionId = obj["questionId"] as? String
            if let current = pendingQuestion?.requestId, current != questionId {
                markQuestionResolved(current)
            }
            if let answering = answeringQuestionId, answering != questionId {
                resolvedQuestionIds.insert(answering)
            }
        }
        if let error = obj["error"] as? String, error.hasVisibleCharacters {
            if error != lastAgentError {
                lastAgentError = error
                errorMessage = "Agent error: \(error)"
            }
        } else {
            lastAgentError = nil
        }
    }

    private func handleMessageStart(_ obj: [String: Any]) {
        guard let msg = obj["message"] as? [String: Any] else { return }
        if let qaRow = ChatViewModel.qaMessage(event: obj, message: msg) {
            upsertQA(qaRow)
            return
        }
        if ChatViewModel.isToolMessage(msg) {
            status.apply(.activity(nil))
            return
        }
        let mapped = ChatMessage.fromAgentMessage(msg)
        switch mapped.role {
        case .tool:
            return
        case .user:
            upsertUserEcho(mapped)
        case .assistant:
            status.apply(.activity(nil))
            beginAssistant(mapped)
        }
    }

    private func handleMessageUpdate(_ obj: [String: Any]) {
        if let usageJson = obj["usage"] as? [String: Any], let usage = SessionUsage(json: usageJson) {
            status.setUsage(usage)
        }
        let msg = obj["message"] as? [String: Any]
        if let msg, ChatViewModel.isToolMessage(msg) {
            status.apply(.activity(nil))
            return
        }
        guard let ev = obj["assistantMessageEvent"] as? [String: Any] else {
            status.apply(.activity(nil))
            return
        }
        // Heuristic labels: fallback only — once the server sends §7
        // `activity`, the reducer ignores them for the label.
        let type = ev["type"] as? String ?? ""
        switch type {
        case "text_delta":
            status.apply(.activity(AgentActivity(kind: .writing)))
            if let delta = ev["delta"] as? String, !delta.isEmpty { accumulate(delta) }
        case "thinking_start", "thinking_delta":
            status.apply(.activity(AgentActivity(kind: .thinking)))
        case "toolcall_start":
            let name = (ev["toolName"] as? String)
                ?? ((ev["toolCall"] as? [String: Any])?["name"] as? String)
            status.apply(.activity(AgentActivity(kind: .toolcall, tool: name)))
        case "done", "error":
            flushPendingDelta()
            if let msg { finalizeAssistant(ChatMessage.fromAgentMessage(msg)) }
        default:
            status.apply(.activity(nil))
        }
    }

    private func handleMessageEnd(_ obj: [String: Any]) {
        flushPendingDelta()
        guard let msg = obj["message"] as? [String: Any] else {
            streamingId = nil
            return
        }
        if let qaRow = ChatViewModel.qaMessage(event: obj, message: msg) {
            upsertQA(qaRow)
            return
        }
        if ChatViewModel.isToolMessage(msg) { return }
        let mapped = ChatMessage.fromAgentMessage(msg)
        switch mapped.role {
        case .tool:
            return
        case .user:
            upsertUserEcho(mapped)
        case .assistant:
            finalizeAssistant(mapped)
        }
    }

    private func handleFileUpdate(_ obj: [String: Any]) {
        // v1 hint only; ignored once v2 agent_status frames are seen.
        if let working = obj["working"] as? Bool { status.apply(.legacyBusy(working)) }
        guard let msg = obj["message"] as? [String: Any] else { return }
        let mapped = ChatViewModel.qaMessage(event: obj, message: msg) ?? ChatMessage.fromAgentMessage(msg)
        guard mapped.role != .tool || mapped.qa != nil else { return }
        // Batch bursts (open-time replay + live host writes) into one merge.
        pendingFileMessages.append(mapped)
        guard fileFlushTask == nil else { return }
        fileFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.fileFlushTask = nil
            let batch = self.pendingFileMessages
            self.pendingFileMessages = []
            ChatMerger.merge(&self.messages, batch)
            self.evictLiveTailIfNeeded()
        }
    }

    private func handleQueueUpdate(_ obj: [String: Any]) {
        if obj["steering"] != nil || obj["followUp"] != nil {
            // pi-native shape: { steering: [text], followUp: [text] }. Shown
            // only for texts the server queue doesn't already represent.
            let steering = obj["steering"] as? [String] ?? []
            let followUp = obj["followUp"] as? [String] ?? []
            let texts = steering + followUp
            if texts != piQueue { piQueue = texts }
        } else if let items = obj["items"] as? [[String: Any]] {
            let parsed = items.compactMap(QueueItem.init(json:)).filter(\.isActive)
            if parsed != serverQueue { serverQueue = parsed }
        }
    }

    // MARK: - Row upserts (identity-preserving)

    private func upsertUserEcho(_ mapped: ChatMessage) {
        guard mapped.text.hasVisibleCharacters else { return }
        ChatMerger.merge(&messages, [mapped])
    }

    /// Q&A rows (contract §9) arrive on message_start AND message_end (and
    /// later file_update / history) — identity-merged into one row.
    private func upsertQA(_ mapped: ChatMessage) {
        ChatMerger.merge(&messages, [mapped])
    }

    /// The `ask_user_question` result as a Q&A row when the server attached
    /// `qa` (on the message copy or the event itself); nil otherwise —
    /// older servers keep today's behaviour (tool rows hidden).
    nonisolated static func qaMessage(event: [String: Any], message: [String: Any]) -> ChatMessage? {
        guard message["qa"] != nil || event["qa"] != nil else { return nil }
        var mapped = ChatMessage.fromAgentMessage(message)
        guard mapped.role == .tool else { return nil }
        if mapped.qa == nil { mapped.qa = QAInfo(json: event["qa"]) }
        return mapped.qa == nil ? nil : mapped
    }

    private func streamingIndex() -> Int? {
        guard let sid = streamingId else { return nil }
        if let last = messages.indices.last, messages[last].id == sid { return last }
        return messages.lastIndex(where: { $0.id == sid })
    }

    /// Find or create the assistant bubble receiving streamed content.
    private func ensureStreamingIndex() -> Int {
        if let i = streamingIndex() { return i }
        let bubble = ChatMessage(role: .assistant, text: "", thinking: nil, toolCalls: [],
                                 isError: false, toolName: nil, isSystemNote: false,
                                 model: nil, errorMessage: nil, timestamp: nil)
        messages.append(bubble)
        streamingId = bubble.id
        return messages.count - 1
    }

    private func beginAssistant(_ mapped: ChatMessage) {
        flushPendingDelta()
        if let i = streamingIndex() {
            // Previous message never ended: drop it if it never got content.
            if messages[i].entryId == nil && !messages[i].text.hasVisibleCharacters && !messages[i].isError {
                messages.remove(at: i)
            }
            streamingId = nil
        }
        if let eid = mapped.entryId, let i = messages.lastIndex(where: { $0.entryId == eid }) {
            streamingId = messages[i].id
            return
        }
        // The row keeps this id for its whole lifecycle (streaming → final →
        // server copy): ChatMerger.absorb never replaces ids.
        messages.append(mapped)
        streamingId = mapped.id
    }

    /// Fold the canonical message_end copy into the streaming bubble WITHOUT
    /// changing its id (no row identity churn → no cell recreation/jump).
    private func finalizeAssistant(_ mapped: ChatMessage) {
        let sIdx = streamingIndex()
        let eIdx = mapped.entryId.flatMap { eid in messages.lastIndex(where: { $0.entryId == eid }) }
        if let e = eIdx, let s = sIdx, e != s {
            // The canonical row already arrived (refresh/file_update) — fold
            // into it and drop the duplicate bubble.
            messages[e] = ChatMerger.absorb(messages[e], mapped)
            messages.remove(at: s)
        } else if let i = eIdx ?? sIdx {
            messages[i] = ChatMerger.absorb(messages[i], mapped)
        } else {
            ChatMerger.merge(&messages, [mapped])
        }
        streamingId = nil
    }

    /// Batch streamed text deltas: append to a buffer, flush ~90ms later.
    private func accumulate(_ delta: String) {
        pendingDelta += delta
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flushPendingDelta()
        }
    }

    private func flushPendingDelta() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingDelta.isEmpty else { return }
        let delta = pendingDelta
        pendingDelta = ""
        let i = ensureStreamingIndex()
        messages[i].text += delta
    }

    /// pi marks tool results with a toolName (roles: toolResult/assistant/user).
    /// Legacy shapes: content made only of toolCall/toolResult blocks.
    nonisolated static func isToolMessage(_ json: [String: Any]) -> Bool {
        if let name = json["toolName"] as? String, !name.isEmpty { return true }
        let role = json["role"] as? String
        if role == "tool" || role == "toolResult" { return true }
        if let blocks = json["content"] as? [[String: Any]], !blocks.isEmpty {
            let toolTypes: Set<String> = ["toolCall", "toolResult", "image"]
            let allTool = blocks.allSatisfy { toolTypes.contains($0["type"] as? String ?? "") }
            if allTool && blocks.contains(where: { ($0["type"] as? String) == "toolResult" }) { return true }
        }
        return false
    }
}
