import Foundation
import Combine

/**
 * Chat state for one session (unidirectional data flow):
 *
 *   SSE frames / REST pages / user intents
 *        → reducers (TranscriptStore for rows — contract §13 identity:
 *          keyed rows, history order + live arrival order, offset-checked
 *          deltas; QueueReconciler for chips; AgentStatusState for status)
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
    /// Unanswered `ask_user_question` questionnaire, shown INLINE as the
    /// newest transcript row (`TranscriptItem.Kind.question`). Mirrored into
    /// the status reducer ("Waiting for your answer" even on servers without
    /// §7 activity).
    @Published private(set) var pendingQuestion: AgentQuestion? {
        didSet {
            if (oldValue == nil) != (pendingQuestion == nil) {
                status.apply(.questionCard(pendingQuestion != nil))
            }
            // The card is a transcript row: add/remove/replace it.
            if oldValue != pendingQuestion { scheduleCommit() }
        }
    }
    @Published var questionSelections: [Int: Set<String>] = [:]
    @Published var questionText: [Int: String] = [:]
    /// Transcript viewport state for the "Question waiting" pill: the user
    /// is (not) near the bottom / the inline question row is (not) on screen.
    @Published var errorMessage: String?
    @Published var infoMessage: String?
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

    /// Full row model (visible + hidden rows), keyed by §13 identity. Every
    /// mutation schedules one coalesced commit.
    private(set) var store = TranscriptStore() { didSet { scheduleCommit() } }
    var messages: [ChatMessage] { store.rows }
    /// The server sends §13 message keys (any event/row carried `key`, even
    /// null). Pre-§13 servers get derived keys and the legacy chip fallback.
    private(set) var serverKeyed = false
    /// Rows passing the single visibility predicate (contract v2 §4).
    private(set) var visibleMessages: [ChatMessage] = []
    private(set) var hasMore = false

    private var serverQueue: [QueueItem] = [] { didSet { scheduleCommit() } }
    private var piQueue: [String] = [] { didSet { scheduleCommit() } }
    /// Sends in flight / acknowledged but not yet echoed as a user row.
    private var localPending: [QueueItem] = [] { didSet { scheduleCommit() } }
    /// clientMessageIds the user cancelled (✕) while their POST /turn was not
    /// acknowledged yet; `deliver` honours them on the late ack or failure.
    /// Value: the server side still has to be cancelled (false when a DELETE
    /// by queue id already covers it — the ack is then just dropped).
    private var cancelledLocal: [String: Bool] = [:]
    /// The delivery task of each still-unacknowledged send (by clientMessageId),
    /// so a ✕ on a "sending…" chip can abandon the request.
    private var deliverTasks: [String: Task<Void, Never>] = [:]
    /// ✕ bookkeeping (contract §15), keyed by `cancelKey`: the chip is hidden
    /// optimistically from the tap until the server confirms (and its queue
    /// drops the item), or shown again when the cancel fails.
    private var cancelIntents: [String: CancelIntent] = [:]
    /// Chips the server could not cancel any more (already handed to the
    /// agent): no ✕ — the user-row echo will replace them. Keyed by `cancelKey`.
    private var uncancellable = Set<String>()
    /// Locally-queued sends while offline (persisted, flushed on reconnect).
    private var offlinePending: [OfflineMessage] = [] { didSet { scheduleCommit() } }

    private let client: APIClient
    /// Send / queue / cancel endpoints (the client itself; stubbed in tests).
    private let queueService: any ChatQueueService
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

    /// Questionnaire ids the server resolved/dropped (§8) — a failed POST
    /// must not resurrect them.
    private var resolvedQuestionIds = Set<String>()
    /// Questionnaire whose answer POST is in flight (card already removed).
    private var answeringQuestionId: String?
    /// Send-now (§10) per server queue id: `.distantFuture` while the POST is
    /// in flight, then the acceptance time. While present the item renders
    /// as "sending…" / running (no ⚡, still ✕) even if a lagging
    /// `queue_update` still reports it `queued` — no flash back, no double
    /// steer.
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
    private var cacheSaveTask: Task<Void, Never>?
    private var loadWatchdog: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var networkCancellable: AnyCancellable?

    private var commitScheduled = false
    private var lastPublished: [TranscriptItem] = []
    private var lastCacheSignature: Int?
    private var pendingCacheSignature: Int?

    init(client: APIClient, sessionId: String, initialModel: String? = nil,
         queueService: (any ChatQueueService)? = nil) {
        self.client = client
        self.queueService = queueService ?? client
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
        // `load` keeps only rows with an identity (key / entry id): older
        // builds cached orphan stream bubbles — never resurrect them.
        if messages.isEmpty,
           let snap = await SessionHistoryCache.shared.load(sessionId: sessionId),
           ChatMessage.hasVisibleContent(snap.messages) {
            store = TranscriptStore(rows: snap.messages)
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
        eventSource?.stop()
        eventSource = nil
        for task in [pollTask, cacheSaveTask, loadWatchdog, resetTask] {
            task?.cancel()
        }
        pollTask = nil
        cacheSaveTask = nil
        loadWatchdog = nil
        resetTask = nil
        // In-flight sends observe cancellation and persist themselves to the
        // offline outbox (same clientMessageId → idempotent retry).
        for task in ownedTasks.values { task.cancel() }
        ownedTasks.removeAll()
        deliverTasks.removeAll()
        networkCancellable = nil
        status.onBecameIdle = nil
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
    @discardableResult
    private func spawn(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let key = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.ownedTasks[key] = nil
        }
        ownedTasks[key] = task
        return task
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
        pruneCancels()
        let reconciled = QueueReconciler.reconcile(localPending: steered(localPending),
                                                   server: steered(serverQueue),
                                                   piNative: piQueue, messages: messages,
                                                   legacyTextMatch: !serverKeyed)
        if !reconciled.deliveredLocal.isEmpty,
           localPending.contains(where: { reconciled.deliveredLocal.contains($0.clientMessageId ?? "") }) {
            localPending.removeAll { reconciled.deliveredLocal.contains($0.clientMessageId ?? "") }
        }
        dropDeliveredOffline()

        var items: [TranscriptItem] = []
        items.reserveCapacity(visibleMessages.count + reconciled.chips.count + offlinePending.count)
        let streamingId = store.inProgressId
        for m in visibleMessages {
            items.append(ChatViewModel.transcriptItem(for: m, streaming: m.id == streamingId))
        }
        var chipClientIds = Set<String>()
        for chip in reconciled.chips {
            if let cid = chip.item.clientMessageId { chipClientIds.insert(cid) }
            // ✕ tapped: hidden until the server confirms (or the cancel fails).
            if isHiddenByCancel(chip) { continue }
            let actions = ChatViewModel.chipActions(chip)
            let blocked = uncancellable.contains(ChatViewModel.cancelKey(clientMessageId: chip.item.clientMessageId,
                                                                         serverId: chip.serverId ?? chip.item.id))
            items.append(TranscriptItem(
                id: chip.rowId, kind: .queued, text: chip.item.message,
                statusText: ChatViewModel.chipStatus(chip.item),
                cancellable: actions.cancellable && !blocked,
                canSteer: actions.steerable,
                actionId: ChatViewModel.chipActionId(chip)))
        }
        for o in offlinePending where !chipClientIds.contains(o.clientMessageId) {
            items.append(TranscriptItem(
                id: "o:" + o.id.uuidString, kind: .offline, text: o.text,
                statusText: "waiting for connection", cancellable: true,
                actionId: o.id.uuidString))
        }
        // The pending questionnaire is ALWAYS the newest row (after messages,
        // chips and offline rows); it disappears when resolved, and the Q&A
        // row from the tool result takes over.
        if let question = pendingQuestion {
            items.append(ChatViewModel.questionItem(question))
        }

        if items != lastPublished {
            lastPublished = items
            transcript.send(items)
        }
        let empty = items.isEmpty
        if transcriptIsEmpty != empty { transcriptIsEmpty = empty }

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

    /// Transcript row for the pending questionnaire (stable id per request).
    nonisolated static func questionItem(_ question: AgentQuestion) -> TranscriptItem {
        TranscriptItem(id: "question:" + question.requestId, kind: .question,
                       text: question.copyText, actionId: question.requestId, question: question)
    }

    /// Every pending chip of ours can be cancelled (✕, contract §15): a local
    /// "sending…" chip (POST not acknowledged — addressed by its
    /// clientMessageId), a `queued` item, and a `running` item pi still holds
    /// as a steer. Send-now (⚡) only applies to a still-`queued` server item.
    /// pi-native rows (texts from pi's own queue, no id) have neither.
    nonisolated static func chipActions(_ chip: QueueChip) -> (cancellable: Bool, steerable: Bool) {
        guard chip.origin != .piNative else { return (false, false) }
        let status = chip.item.status
        let pending = status == "queued" || status == "running" || status == "sending"
        let addressable = chip.serverId != nil || chip.item.clientMessageId != nil
        return (pending && addressable, status == "queued" && chip.serverId != nil)
    }

    /// Prefix of the action id of a chip the server hasn't given an id yet.
    nonisolated static var pendingActionPrefix: String { "pending:" }

    /// The id the chip's buttons act on: the server queue id when known,
    /// else `pending:<clientMessageId>` (cancel by clientMessageId).
    nonisolated static func chipActionId(_ chip: QueueChip) -> String? {
        if let serverId = chip.serverId { return serverId }
        guard chip.origin != .piNative, let cid = chip.item.clientMessageId else { return nil }
        return pendingActionPrefix + cid
    }

    /// Chip header label:
    /// - "sending…" — POST (or send-now) not acknowledged yet;
    /// - "queued · 2m" — waiting in the server queue;
    /// - "waiting for agent · after current step" — handed to pi (running /
    ///   steered), which takes it when the current step ends; the user-row
    ///   echo replaces the chip.
    nonisolated static func chipStatus(_ item: QueueItem, now: Date = Date()) -> String {
        switch item.status {
        case "queued":
            var parts = ["queued"]
            if let at = item.queuedAt {
                let elapsed = Int(now.timeIntervalSince1970 * 1000 - TimeInterval(at)) / 1000
                if elapsed >= 60 {
                    parts.append(elapsed >= 3600 ? "\(elapsed / 3600)h" : "\(elapsed / 60)m")
                }
            }
            return parts.joined(separator: " · ")
        case "sending":
            return "sending…"
        default:
            return "waiting for agent · after current step"
        }
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

    /// Only settled rows with a server identity: never the in-progress or an
    /// incomplete (gap) row, never a row without key/entry id. On pre-§13
    /// servers only persisted (entry-id) rows — derived keys stay in memory.
    private func cacheableMessages() -> [ChatMessage] {
        ChatViewModel.cacheable(store, serverKeyed: serverKeyed)
    }

    nonisolated static func cacheable(_ store: TranscriptStore, serverKeyed: Bool) -> [ChatMessage] {
        store.rows.suffix(SessionHistoryCache.maxMessages).filter { m in
            store.isSettled(m) && (m.entryId != nil || (serverKeyed && m.key != nil))
        }
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

    /// History rows as stored: displayable, with an identity (server `key`,
    /// else the derived pre-§13 key — see `identified`).
    nonisolated static func prepareHistory(_ rows: [ChatMessage]) -> [ChatMessage] {
        displayable(rows).map { identified($0, key: nil) }
    }

    /// Note whether a page comes from a §13 server, then prepare its rows.
    private func historyRows(_ page: [ChatMessage]) -> [ChatMessage] {
        if !serverKeyed, page.contains(where: { $0.key != nil }) { serverKeyed = true }
        return ChatViewModel.prepareHistory(page)
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

    /// Fire-and-forget refresh (healing after a broken stream).
    private func requestRefresh() {
        guard lifecycleActive else { return }
        spawn { [weak self] in await self?.refreshFromServer() }
    }

    private func performRefresh() async {
        let cursor = lastSeenEntryId
        let mark = store.liveMark
        do {
            let page = try await client.fetchMessages(sessionId, limit: cursor == nil ? 100 : 200, since: cursor)
            guard lifecycleActive else { return }
            if let working = page.working { status.apply(.legacyBusy(working)) }
            let isDelta = cursor != nil && (page.cursorMode ?? true)
            if isDelta {
                // Empty delta = nothing new: a successful no-op.
                guard !page.messages.isEmpty else { return }
                store.merge(historyRows(page.messages), placement: .newer)
            } else {
                store.reload(historyRows(page.messages), keepingLiveAfter: mark)
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

    /// SSE `reset` (contract v2 §1 / §13 "Ordering"): the server could not
    /// replay, so live frames were lost. The in-progress row is no longer
    /// authoritative (the server re-announces it with `message_snapshot`
    /// right after the reset), then a full tail reload REPLACES the tail,
    /// keeping only rows that arrived live after the request started.
    private func scheduleResetReload() {
        store.interruptInProgress()
        let mark = store.liveMark
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.client.fetchMessages(self.sessionId, limit: 100)
                guard self.lifecycleActive, !Task.isCancelled else { return }
                self.store.reload(self.historyRows(page.messages), keepingLiveAfter: mark)
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
        let mark = store.liveMark
        do {
            let page = try await client.fetchMessages(sessionId, limit: 100)
            guard lifecycleActive else { return }
            store.reload(historyRows(page.messages), keepingLiveAfter: mark)
            hasMore = page.hasMore
            noteLowest(page.messages)
            advanceCursor(page.messages)
            if let working = page.working { status.apply(.legacyBusy(working)) }
            // Blank-page guard: a tail that is one long tool loop has nothing
            // visible — fetch the newest VISIBLE rows (server ?visible=1).
            // They are all older than the tail page.
            if !ChatMessage.hasVisibleContent(messages), hasMore,
               let visible = try? await client.fetchMessages(sessionId, limit: 100, visibleOnly: true),
               lifecycleActive {
                store.merge(historyRows(visible.messages), placement: .older)
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
    /// going (bounded) while pages add nothing visible. The `before` cursor
    /// is the server's timestamp pagination API — rows are still placed by
    /// identity/page order (an older page goes above the loaded rows).
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
                    let rows = self.historyRows(page.messages)
                    self.store.merge(rows, placement: .older)
                    self.hasMore = page.hasMore
                    self.noteLowest(page.messages)
                    let addedVisible = rows.contains(where: ChatMessage.isVisibleInFocus)
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
        store.evictOldest(messages.count - 1_000)
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
        // Runs after this synchronous call returns (main-actor task), so the
        // entry below is always registered before the task can clear it.
        deliverTasks[clientMessageId] = spawn { [weak self] in
            await self?.deliver(trimmed, clientMessageId: clientMessageId, force: false)
            self?.deliverTasks[clientMessageId] = nil
        }
    }

    private func updateLocal(_ clientMessageId: String, _ transform: (QueueItem) -> QueueItem) {
        guard let i = localPending.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return }
        localPending[i] = transform(localPending[i])
    }

    private func deliver(_ text: String, clientMessageId: String, force: Bool) async {
        do {
            let resp = try await queueService.sendTurn(sessionId, message: text, force: force,
                                                       clientMessageId: clientMessageId)
            let delivered = resp.dispatched == true || !resp.queued
            if let needsServerCancel = cancelledLocal.removeValue(forKey: clientMessageId) {
                // ✕ was tapped before this (late) ack: the server has the
                // message now — queued or already handed to pi — cancel it.
                localPending.removeAll { $0.clientMessageId == clientMessageId }
                if needsServerCancel {
                    resolveCancelledSend(clientMessageId, reachedServer: true, queueItemId: resp.queueItemId)
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
            if let needsServerCancel = cancelledLocal.removeValue(forKey: clientMessageId) {
                // Cancelled before any ack (the ✕ abandoned the request, or it
                // failed). A request that was lost in flight may still have
                // reached the server: cancel it there by clientMessageId. A
                // server rejection means it never got queued — nothing to undo.
                // Never the offline outbox: the user cancelled it.
                if needsServerCancel {
                    resolveCancelledSend(clientMessageId, reachedServer: ChatViewModel.isLostRequest(error),
                                         queueItemId: nil)
                }
                return
            }
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

    // MARK: - Cancel (✕ on a pending chip, contract §15)

    /// One ✕ in progress / just confirmed.
    struct CancelIntent {
        let clientMessageId: String?
        /// Server queue id once known (DELETE /queue/:id).
        var serverId: String?
        let text: String
        /// A DELETE (or the late ack it waits for) is in flight.
        var inFlight = true
        /// The server didn't know the message yet (lost POST, by-client 404):
        /// if it still shows up in the queue, it is cancelled then.
        var awaitingServerItem = false
        /// When the server confirmed the cancel.
        var settledAt: Date?
        let since = Date()
    }

    enum CancelOutcome {
        case cancelled
        /// 409 `already_delivered`: pi already took it — the echo follows.
        case alreadyDelivered
        /// 404: unknown id (pre-§15 server for a non-queued item, by-client
        /// for a POST that never arrived, or an item that just settled).
        case notFound
        case failed(Error)
    }

    nonisolated static func cancelOutcome(for error: Error) -> CancelOutcome {
        if case APIError.http(let code, _, let apiCode) = error {
            if code == 409, apiCode == nil || apiCode == "already_delivered" { return .alreadyDelivered }
            if code == 404 { return .notFound }
        }
        return .failed(error)
    }

    /// Identity of a chip for cancel bookkeeping: its clientMessageId (shared
    /// by the local and server twins), else its server id.
    nonisolated static func cancelKey(clientMessageId: String?, serverId: String?) -> String {
        if let clientMessageId { return clientMessageId }
        return "id:" + (serverId ?? "")
    }

    /// The request may have reached the server although no response came
    /// back (abandoned / connection lost).
    nonisolated static func isLostRequest(_ error: Error) -> Bool {
        if APIClient.isCancellation(error) { return true }
        if case APIError.offline = error { return true }
        return false
    }

    /// Text shown when pi already took the message (409 / pre-§15 404).
    nonisolated static var alreadyDeliveredInfo: String { "Already delivered to the agent" }

    /// ✕ on a queue chip (`actionId` from `chipActionId`).
    /// - `pending:<cid>` — a send without a server queue id: while its POST
    ///   is unacknowledged the chip goes at once, the request is abandoned and
    ///   `deliver` cancels it server-side if it got there anyway; an
    ///   acknowledged one is cancelled by clientMessageId.
    /// - a server queue id — `DELETE /queue/:id`, for `queued` items and (§15)
    ///   `running` ones pi still holds as a steer. Optimistically hidden; a
    ///   409 `already_delivered` brings the chip back without ✕ until its
    ///   echo turns it into the user row; other failures roll back + error.
    func cancelQueued(_ actionId: String) {
        let prefix = ChatViewModel.pendingActionPrefix
        if actionId.hasPrefix(prefix) {
            cancelLocalSend(String(actionId.dropFirst(prefix.count)))
        } else {
            cancelServerItem(actionId)
        }
    }

    private func cancelLocalSend(_ clientMessageId: String) {
        guard let local = localPending.first(where: { $0.clientMessageId == clientMessageId }) else { return }
        let key = ChatViewModel.cancelKey(clientMessageId: clientMessageId, serverId: nil)
        guard cancelIntents[key] == nil else { return }
        localPending.removeAll { $0.clientMessageId == clientMessageId }
        cancelIntents[key] = CancelIntent(clientMessageId: clientMessageId, serverId: nil, text: local.message)
        scheduleCommit()
        if !localPending.contains(where: { $0.status == "sending" }) {
            status.apply(.clearOptimistic)
        }
        if local.status == "sending", let task = deliverTasks[clientMessageId] {
            // Not acknowledged: `deliver` resolves the cancel on the ack (late
            // ack → server-side cancel) or the failure this triggers.
            cancelledLocal[clientMessageId] = true
            task.cancel()
        } else {
            // Acknowledged without a queue id (or its delivery task is gone).
            spawn { [weak self] in
                await self?.runCancel(key: key, serverId: nil, clientMessageId: clientMessageId,
                                      fallbackServerId: nil, wasQueued: local.status == "queued")
            }
        }
    }

    private func cancelServerItem(_ serverItemId: String) {
        let server = serverQueue.first { $0.id == serverItemId }
        let local = localPending.first { $0.id == serverItemId }
        guard let item = server ?? local, item.isActive else { return }
        let cid = item.clientMessageId
        let key = ChatViewModel.cancelKey(clientMessageId: cid, serverId: serverItemId)
        guard cancelIntents[key] == nil, !uncancellable.contains(key) else { return }
        let wasQueued = item.status == "queued" && steering[serverItemId] == nil
        cancelIntents[key] = CancelIntent(clientMessageId: cid, serverId: serverItemId, text: item.message)
        // A local twin whose POST is still unacknowledged: its late ack must
        // neither resurrect the chip nor go to the offline outbox (this
        // DELETE covers the server side).
        if let cid, let twin = localPending.first(where: { $0.clientMessageId == cid }) {
            if twin.status == "sending", deliverTasks[cid] != nil { cancelledLocal[cid] = false }
            localPending.removeAll { $0.clientMessageId == cid }
        }
        scheduleCommit()
        spawn { [weak self] in
            await self?.runCancel(key: key, serverId: serverItemId, clientMessageId: nil,
                                  fallbackServerId: nil, wasQueued: wasQueued)
        }
    }

    /// The ✕ of a send whose POST was unacknowledged at tap time, once the
    /// POST resolved. If it (may have) reached the server — late ack, or
    /// lost in flight — cancel it by clientMessageId (§15), falling back to
    /// the acknowledged queue id on servers without the by-client route; a
    /// server rejection leaves nothing to cancel. Runs the DELETE in its own
    /// task: the delivery task may be the cancelled one. Nothing to do when a
    /// server-chip ✕ (DELETE by queue id) already covers it.
    private func resolveCancelledSend(_ clientMessageId: String, reachedServer: Bool, queueItemId: String?) {
        let key = ChatViewModel.cancelKey(clientMessageId: clientMessageId, serverId: nil)
        if let intent = cancelIntents[key], intent.serverId != nil { return }
        guard reachedServer else {
            dropCancelIntent(key)
            return
        }
        if cancelIntents[key] == nil {
            cancelIntents[key] = CancelIntent(clientMessageId: clientMessageId, serverId: nil, text: "")
        }
        spawn { [weak self] in
            await self?.runCancel(key: key, serverId: nil, clientMessageId: clientMessageId,
                                  fallbackServerId: queueItemId, wasQueued: false)
        }
    }

    /// Perform the DELETE and settle the intent.
    private func runCancel(key: String, serverId: String?, clientMessageId: String?,
                           fallbackServerId: String?, wasQueued: Bool) async {
        var outcome: CancelOutcome
        let byClient = serverId == nil
        do {
            if let serverId {
                try await queueService.cancelQueued(sessionId, itemId: serverId)
            } else if let clientMessageId {
                try await queueService.cancelQueuedByClient(sessionId, clientMessageId: clientMessageId)
            }
            outcome = .cancelled
        } catch {
            outcome = ChatViewModel.cancelOutcome(for: error)
        }
        // Pre-§15 server (no by-client route): the acknowledged queue id.
        if byClient, case .notFound = outcome, let fallbackServerId {
            do {
                try await queueService.cancelQueued(sessionId, itemId: fallbackServerId)
                outcome = .cancelled
            } catch {
                outcome = ChatViewModel.cancelOutcome(for: error)
            }
        }
        await settleCancel(key: key, outcome: outcome, byClient: byClient, wasQueued: wasQueued)
    }

    private func settleCancel(key: String, outcome: CancelOutcome, byClient: Bool, wasQueued: Bool) async {
        switch outcome {
        case .cancelled:
            guard var intent = cancelIntents[key] else { return }
            intent.inFlight = false
            intent.awaitingServerItem = false
            intent.settledAt = Date()
            cancelIntents[key] = intent
            // Server truth now: gone. (A lagging queue_update stays hidden by
            // the settled intent for a grace period.)
            serverQueue.removeAll { item in
                (intent.serverId != nil && item.id == intent.serverId)
                    || (intent.clientMessageId != nil && item.clientMessageId == intent.clientMessageId)
            }
            scheduleCommit()
        case .alreadyDelivered:
            markAlreadyDelivered(key)
        case .notFound where byClient:
            // The server doesn't know this clientMessageId (yet): the POST
            // never arrived, or is still being processed — if the item shows
            // up in the queue, `sweepCancelIntents` cancels it then.
            guard var intent = cancelIntents[key] else { return }
            intent.inFlight = false
            intent.awaitingServerItem = true
            cancelIntents[key] = intent
            scheduleCommit()
            sweepCancelIntents()
        case .notFound:
            if wasQueued {
                // The queued item is gone (dispatched or cancelled elsewhere):
                // resync silently — a delivered one shows up as its echo.
                dropCancelIntent(key)
                await loadQueue()
            } else {
                // Pre-§15 server: a running item can't be cancelled.
                markAlreadyDelivered(key)
            }
        case .failed(let error):
            if byClient, ChatViewModel.isLostRequest(error) {
                // Unreachable: keep watching for the item to cancel it.
                guard var intent = cancelIntents[key] else { return }
                intent.inFlight = false
                intent.awaitingServerItem = true
                cancelIntents[key] = intent
                scheduleCommit()
                sweepCancelIntents()
                return
            }
            // 502 (pi's queue couldn't be cleared) etc.: roll back, show why.
            dropCancelIntent(key)
            surface(error)
            await loadQueue()
        }
    }

    /// 409 `already_delivered`: the chip comes back (no ✕) until the echo
    /// turns it into the user row.
    private func markAlreadyDelivered(_ key: String) {
        dropCancelIntent(key)
        uncancellable.insert(key)
        scheduleCommit()
        infoMessage = ChatViewModel.alreadyDeliveredInfo
    }

    private func dropCancelIntent(_ key: String) {
        guard cancelIntents.removeValue(forKey: key) != nil else { return }
        scheduleCommit()
    }

    /// A message cancelled before the server knew it showed up in the queue
    /// after all: cancel it by its queue id now.
    private func sweepCancelIntents() {
        guard cancelIntents.values.contains(where: \.awaitingServerItem) else { return }
        for item in serverQueue {
            guard let cid = item.clientMessageId else { continue }
            let key = ChatViewModel.cancelKey(clientMessageId: cid, serverId: nil)
            guard var intent = cancelIntents[key], intent.awaitingServerItem else { continue }
            intent.awaitingServerItem = false
            intent.inFlight = true
            intent.serverId = item.id
            cancelIntents[key] = intent
            let wasQueued = item.status == "queued"
            spawn { [weak self] in
                await self?.runCancel(key: key, serverId: item.id, clientMessageId: nil,
                                      fallbackServerId: nil, wasQueued: wasQueued)
            }
        }
    }

    /// A chip the user cancelled stays hidden while its intent lives; while a
    /// DELETE is in flight a pi-native copy of its text is hidden too (pi's
    /// own queue still lists it until the server clears it).
    private func isHiddenByCancel(_ chip: QueueChip) -> Bool {
        guard !cancelIntents.isEmpty else { return false }
        if chip.origin == .piNative {
            let norm = TextNormalizer.normalize(chip.item.message)
            return cancelIntents.values.contains {
                $0.inFlight && !$0.text.isEmpty && TextNormalizer.normalize($0.text) == norm
            }
        }
        if let cid = chip.item.clientMessageId, cancelIntents[cid] != nil { return true }
        let id = chip.serverId ?? chip.item.id
        return cancelIntents["id:" + id] != nil || cancelIntents.values.contains { $0.serverId == id }
    }

    /// Forget settled intents once the server dropped the item (after a short
    /// grace for lagging queue updates), and stale "already delivered" marks.
    private func pruneCancels() {
        guard !cancelIntents.isEmpty || !uncancellable.isEmpty else { return }
        let now = Date()
        let liveCids = Set(serverQueue.compactMap(\.clientMessageId)).union(localPending.compactMap(\.clientMessageId))
        let liveIds = Set(serverQueue.map(\.id)).union(localPending.map(\.id))
        func present(_ key: String) -> Bool {
            key.hasPrefix("id:") ? liveIds.contains(String(key.dropFirst(3))) : liveCids.contains(key)
        }
        let kept = cancelIntents.filter { key, intent in
            if intent.inFlight { return true }
            if intent.awaitingServerItem { return now.timeIntervalSince(intent.since) < Self.cancelWatch }
            let age = now.timeIntervalSince(intent.settledAt ?? intent.since)
            return age < Self.cancelGrace || (present(key) && age < Self.cancelWatch)
        }
        if kept.count != cancelIntents.count { cancelIntents = kept }
        let blocked = uncancellable.filter(present)
        if blocked.count != uncancellable.count { uncancellable = blocked }
    }

    /// A confirmed cancel hides lagging queue updates this long.
    private static let cancelGrace: TimeInterval = 10
    /// Upper bound for watching a cancelled item (unknown to the server, or
    /// still listed after a confirmed cancel).
    private static let cancelWatch: TimeInterval = 60

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

    /// Items with a send-now in flight render as "sending…"; once accepted
    /// as a running steer (pi takes it after the current step).
    private func steered(_ items: [QueueItem]) -> [QueueItem] {
        guard !steering.isEmpty else { return items }
        return items.map { item in
            guard item.status == "queued", let since = steering[item.id] else { return item }
            let inFlight = since == .distantFuture
            return QueueItem(id: item.id, clientMessageId: item.clientMessageId, message: item.message,
                             status: inFlight ? "sending" : "running", queuedAt: item.queuedAt,
                             steered: inFlight ? item.steered : true)
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
        if let items = try? await queueService.fetchQueue(sessionId), lifecycleActive {
            let active = items.filter(\.isActive)
            if active != serverQueue { serverQueue = active }
            sweepCancelIntents()
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
                let resp = try await queueService.sendTurn(sessionId, message: item.text, force: false,
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
    /// without opening a stream (snapshot/integration/replay tests).
    func ingestForTesting(_ frames: [ParsedSSEFrame]) {
        lifecycleActive = true
        handle(frames)
    }

    /// Test seam: install a model listing as if `GET /models` returned it.
    func seedModelsForTesting(_ listing: ModelListing) {
        adoptListing(listing)
    }

    /// Test seam: the live-arrival mark a reload request captures when it
    /// starts (`store.liveMark`).
    var liveMarkForTesting: Int { store.liveMark }

    /// Test seam: complete a reload (initial / cursor-unknown / reset) with
    /// `page` as the server's `GET /messages` rows, for a request that
    /// started at `mark` — the same code path as the real responses.
    func reloadForTesting(_ page: [ChatMessage], mark: Int) {
        lifecycleActive = true
        store.reload(historyRows(page), keepingLiveAfter: mark)
        advanceCursor(page)
    }

    /// Test seam: a cursor (`since`) delta page.
    func mergeDeltaForTesting(_ page: [ChatMessage]) {
        lifecycleActive = true
        store.merge(historyRows(page), placement: .newer)
        advanceCursor(page)
    }

    /// Test seam: rows that would be written to the on-disk cache.
    var cacheableRowsForTesting: [ChatMessage] { cacheableMessages() }

    /// Test seam: open with a cached snapshot (as `start()` does).
    func loadCacheForTesting(_ rows: [ChatMessage]) {
        store = TranscriptStore(rows: SessionHistoryCache.sanitized(rows))
        loadPhase = .loaded
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
            streamBrokeIfInProgress()
            status.apply(.legacyBusy(false))
        case "agent_exited":
            streamBrokeIfInProgress()
            status.apply(.exited)
        case "agent_crashed":
            streamBrokeIfInProgress()
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
        case "message_snapshot":
            handleMessageSnapshot(obj)
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

    /// The agent stopped while a message was still streaming (its
    /// message_end was lost): the row is no longer authoritative — heal it
    /// from history (the persisted copy replaces it by key).
    private func streamBrokeIfInProgress() {
        if store.interruptInProgress() { requestRefresh() }
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
        if !busy { streamBrokeIfInProgress() }
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

    // MARK: - Identity (contract §13)

    /// A §13 server puts `key` on every message event (null for deltas of a
    /// message whose start it did not see). Its mere presence marks the
    /// server as keyed.
    private func noteKeyed(_ obj: [String: Any]) -> Bool {
        let keyed = obj.keys.contains("key")
        if keyed, !serverKeyed { serverKeyed = true }
        return keyed
    }

    /// The event's key: top-level (message events, snapshot) or on the
    /// server-mapped message (`file_update.message`, history shape).
    nonisolated static func eventKey(_ obj: [String: Any], _ msg: [String: Any]?) -> String? {
        (obj["key"] as? String) ?? (msg?["key"] as? String)
    }

    /// Give a row its identity: the server key when given, else the key it
    /// already carries, else (pre-§13 server) the same `<role>:<timestamp>`
    /// shape derived from pi's creation timestamp, which pi streams AND
    /// persists unchanged. Rows created here get the key-based row id.
    nonisolated static func identified(_ m: ChatMessage, key: String?) -> ChatMessage {
        var r = m
        if let key { r.key = key } else if r.key == nil { r.key = derivedKey(r) }
        if r.entryId == nil, let k = r.key { r.id = "k:" + k }
        return r
    }

    /// Pre-§13 identity. Tool rows (only Q&A rows are kept) use the
    /// timestamp too: the history shape carries no toolCallId.
    nonisolated static func derivedKey(_ m: ChatMessage) -> String? {
        guard let ts = m.timestamp else { return nil }
        switch m.role {
        case .user: return "user:\(ts)"
        case .assistant: return "assistant:\(ts)"
        case .tool: return "tool@\(ts)"
        }
    }

    /// Map an event's message, attaching the event-level clientMessageId
    /// (§3) to user rows.
    private static func mapped(_ obj: [String: Any], _ msg: [String: Any]) -> ChatMessage {
        var m = ChatMessage.fromAgentMessage(msg)
        if m.role == .user, m.clientMessageId == nil {
            m.clientMessageId = obj["clientMessageId"] as? String
        }
        return m
    }

    // MARK: - Message events

    private func handleMessageStart(_ obj: [String: Any]) {
        _ = noteKeyed(obj)
        guard let msg = obj["message"] as? [String: Any] else { return }
        let key = ChatViewModel.eventKey(obj, msg)
        if let qaRow = ChatViewModel.qaMessage(event: obj, message: msg) {
            store.upsertLive(ChatViewModel.identified(qaRow, key: key))
            return
        }
        if ChatViewModel.isToolMessage(msg) {
            status.apply(.activity(nil))
            return
        }
        let row = ChatViewModel.identified(ChatViewModel.mapped(obj, msg), key: key)
        switch row.role {
        case .tool:
            return
        case .user:
            store.upsertLive(row)
        case .assistant:
            status.apply(.activity(nil))
            store.start(row)
        }
    }

    private func handleMessageUpdate(_ obj: [String: Any]) {
        if let usageJson = obj["usage"] as? [String: Any], let usage = SessionUsage(json: usageJson) {
            status.setUsage(usage)
        }
        let keyed = noteKeyed(obj)
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
            guard let delta = ev["delta"] as? String, !delta.isEmpty else { break }
            if let key = ChatViewModel.eventKey(obj, nil) {
                let number = (obj["offset"] as? NSNumber) ?? (ev["offset"] as? NSNumber)
                store.applyDelta(key: key, offset: number.map { Int($0.int64Value) }, delta: delta)
            } else if !keyed {
                // Pre-§13 server: deltas belong to the last started message.
                store.appendLegacyDelta(delta)
            }
            // `key: null` (§13: server saw no message_start) → status only;
            // the keyed message_end / snapshot brings the text.
        case "thinking_start", "thinking_delta":
            status.apply(.activity(AgentActivity(kind: .thinking)))
        case "toolcall_start":
            let name = (ev["toolName"] as? String)
                ?? ((ev["toolCall"] as? [String: Any])?["name"] as? String)
            status.apply(.activity(AgentActivity(kind: .toolcall, tool: name)))
        case "done", "error":
            if let msg { finishAssistant(obj, msg) }
        default:
            status.apply(.activity(nil))
        }
    }

    private func handleMessageEnd(_ obj: [String: Any]) {
        _ = noteKeyed(obj)
        guard let msg = obj["message"] as? [String: Any] else {
            // Defensive: a keyed end carrying only the canonical text.
            if let key = obj["key"] as? String, let text = obj["text"] as? String {
                store.finish(ChatMessage(role: .assistant, text: text, thinking: nil, toolCalls: [],
                                         isError: false, toolName: nil, isSystemNote: false, model: nil,
                                         errorMessage: nil, timestamp: nil, key: key))
            }
            return
        }
        let key = ChatViewModel.eventKey(obj, msg)
        if let qaRow = ChatViewModel.qaMessage(event: obj, message: msg) {
            store.upsertLive(ChatViewModel.identified(qaRow, key: key))
            return
        }
        if ChatViewModel.isToolMessage(msg) { return }
        let row = ChatViewModel.mapped(obj, msg)
        switch row.role {
        case .tool:
            return
        case .user:
            store.upsertLive(ChatViewModel.identified(row, key: key))
        case .assistant:
            finishAssistant(obj, msg)
        }
    }

    /// message_end / done / error: the server's top-level `text` (§13: the
    /// SAME function as the history mapping) replaces the streamed text;
    /// older servers → the mapped message text.
    private func finishAssistant(_ obj: [String: Any], _ msg: [String: Any]) {
        var row = ChatViewModel.identified(ChatViewModel.mapped(obj, msg),
                                           key: ChatViewModel.eventKey(obj, msg))
        if let text = obj["text"] as? String { row.text = ChatMessage.collapseBlankLines(text) }
        guard TranscriptStore.hasIdentity(row) else {
            // No key, no timestamp, no entry id: nothing to anchor it to —
            // never invent a floating row; history brings it.
            requestRefresh()
            return
        }
        store.finish(row)
    }

    /// §13 `message_snapshot {key, role, timestamp, text, streaming}`: the
    /// in-progress message's text so far, authoritative.
    private func handleMessageSnapshot(_ obj: [String: Any]) {
        _ = noteKeyed(obj)
        guard let key = obj["key"] as? String, let text = obj["text"] as? String else { return }
        let timestamp = (obj["timestamp"] as? NSNumber).map { Int($0.int64Value) }
        if (obj["streaming"] as? Bool) == false {
            store.finish(ChatMessage(role: .assistant, text: text, thinking: nil, toolCalls: [],
                                     isError: false, toolName: nil, isSystemNote: false, model: nil,
                                     errorMessage: nil, timestamp: timestamp, key: key))
        } else {
            store.snapshot(key: key, timestamp: timestamp, text: text)
        }
    }

    /// Read-only tailer rows (no transport): persisted rows, upserted by
    /// identity in arrival order.
    private func handleFileUpdate(_ obj: [String: Any]) {
        // v1 hint only; ignored once v2 agent_status frames are seen.
        if let working = obj["working"] as? Bool { status.apply(.legacyBusy(working)) }
        guard let msg = obj["message"] as? [String: Any] else { return }
        let keyed = noteKeyed(obj) || msg.keys.contains("key")
        if keyed, !serverKeyed { serverKeyed = true }
        let mapped = ChatViewModel.qaMessage(event: obj, message: msg) ?? ChatMessage.fromAgentMessage(msg)
        guard mapped.role != .tool || mapped.qa != nil else { return }
        let row = ChatViewModel.identified(mapped, key: ChatViewModel.eventKey(obj, msg))
        store.merge([row], placement: .newer, live: true)
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
            sweepCancelIntents()
        }
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
