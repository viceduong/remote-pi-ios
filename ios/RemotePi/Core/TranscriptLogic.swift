import Foundation

// MARK: - Visibility (contract v2 §4)

extension String {
    /// True when the string contains at least one non-whitespace character.
    /// Allocation-free (unlike `trimmingCharacters(in:).isEmpty`).
    var hasVisibleCharacters: Bool { contains { !$0.isWhitespace } }
}

extension ChatMessage {
    /// THE single visibility rule shared by the renderer, `hasVisibleContent`
    /// and every other caller (contract v2 §4). A row is visible iff:
    /// - user (not a system/custom note) with non-blank text;
    /// - assistant with non-blank text (thinking excluded);
    /// - error rows (`isError` on a non-tool row, or wire role "error").
    /// Thinking-only rows, tool calls/results and custom notes are hidden.
    static func isVisibleInFocus(_ m: ChatMessage) -> Bool {
        switch m.role {
        case .tool:
            return false
        case .user:
            return !m.isSystemNote && m.text.hasVisibleCharacters
        case .assistant:
            return m.text.hasVisibleCharacters || m.isErrorRow
        }
    }

    /// Error row: explicit `isError`, or an assistant turn that failed with a
    /// provider `errorMessage` and produced no text (pi never sets `isError`
    /// on assistant errors — matches the server's visibility rule).
    var isErrorRow: Bool {
        isError || (!text.hasVisibleCharacters && (errorMessage?.hasVisibleCharacters ?? false))
    }

    static func hasVisibleContent(_ messages: [ChatMessage]) -> Bool {
        messages.contains(where: ChatMessage.isVisibleInFocus)
    }
}

// MARK: - Text normalization (same function on BOTH sides of every match)

enum TextNormalizer {
    /// Collapse every whitespace run (incl. newlines) to one space and trim.
    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Transcript rows (what the UIKit transcript renders)

struct TranscriptItem: Equatable {
    enum Kind: String, Equatable {
        case user, assistant, error, queued, offline
    }

    var id: String
    var kind: Kind
    var text: String
    var entryId: String? = nil
    var streaming = false
    /// Chip header ("queued · 2m", "sending", "waiting for connection").
    var statusText: String? = nil
    /// Chips/offline rows: whether the ✕ button is shown.
    var cancellable = false
    /// Server queue item id (chips) or offline UUID string (offline rows).
    var actionId: String? = nil
}

// MARK: - Queue chip reconciliation (one chip per logical message)

struct QueueChip: Equatable {
    enum Origin: Equatable { case server, local, piNative }
    /// Stable transcript row id: keyed by clientMessageId when known, so a
    /// local "sending" chip and the server's queue item are the SAME row.
    let rowId: String
    let item: QueueItem
    /// Server queue id usable for DELETE /queue/:id (nil = not cancellable).
    let serverId: String?
    let origin: Origin
}

enum QueueReconciler {
    /// Clock-skew tolerance for the text fallback (client vs server clocks).
    static let textMatchSkewMs = 120_000

    /// Merge server queue items, local in-flight sends and pi-native queued
    /// texts into one ordered chip list, dropping anything already delivered
    /// (a user row exists for it). Returns the chips plus the
    /// clientMessageIds of local sends that are now delivered.
    static func reconcile(localPending: [QueueItem],
                          server: [QueueItem],
                          piNative: [String],
                          messages: [ChatMessage]) -> (chips: [QueueChip], deliveredLocal: Set<String>) {
        if localPending.isEmpty && server.isEmpty && piNative.isEmpty { return ([], []) }
        var deliveredCids = Set<String>()
        var recent: [(norm: String, ts: Int?, cid: String?)] = []
        for m in messages.reversed() where m.role == .user && !m.isSystemNote {
            if let cid = m.clientMessageId { deliveredCids.insert(cid) }
            if recent.count < 12 {
                recent.append((TextNormalizer.normalize(m.text), m.timestamp, m.clientMessageId))
            }
        }
        var consumed = [Bool](repeating: false, count: recent.count)

        func deliveredByText(_ item: QueueItem) -> Bool {
            let norm = TextNormalizer.normalize(item.message)
            guard !norm.isEmpty else { return false }
            for (i, row) in recent.enumerated() where !consumed[i] {
                guard row.norm == norm else { continue }
                // A row carrying a DIFFERENT clientMessageId is another message.
                if let rc = row.cid, let ic = item.clientMessageId, rc != ic { continue }
                if let ts = row.ts, let q = item.queuedAt, ts < q - textMatchSkewMs { continue }
                consumed[i] = true
                return true
            }
            return false
        }

        var chips: [QueueChip] = []
        var seenCids = Set<String>()
        var deliveredLocal = Set<String>()

        // 1. Server queue (authoritative order).
        for s in server where s.isActive {
            if let cid = s.clientMessageId {
                if deliveredCids.contains(cid) || seenCids.contains(cid) { continue }
            }
            // A `queued` item is by definition undelivered — only a `running`
            // one can already have its user row in the transcript.
            if s.status == "running", deliveredByText(s) { continue }
            if let cid = s.clientMessageId { seenCids.insert(cid) }
            chips.append(QueueChip(rowId: "q:" + (s.clientMessageId ?? s.id), item: s,
                                   serverId: s.id, origin: .server))
        }

        // 2. Local in-flight sends not (yet) represented by a server item.
        for l in localPending {
            guard let cid = l.clientMessageId else { continue }
            if deliveredCids.contains(cid) { deliveredLocal.insert(cid); continue }
            if seenCids.contains(cid) { continue }
            let norm = TextNormalizer.normalize(l.message)
            // v1 servers may return queue items without a clientMessageId.
            if server.contains(where: { $0.isActive && $0.clientMessageId == nil
                && TextNormalizer.normalize($0.message) == norm }) { continue }
            if l.status != "queued", deliveredByText(l) { deliveredLocal.insert(cid); continue }
            seenCids.insert(cid)
            chips.append(QueueChip(rowId: "q:" + cid, item: l,
                                   serverId: l.id.hasPrefix("pending:") ? nil : l.id,
                                   origin: .local))
        }

        // 3. pi-native queue texts (steering/followUp) not already shown.
        var occurrences: [String: Int] = [:]
        for text in piNative {
            let norm = TextNormalizer.normalize(text)
            guard !norm.isEmpty else { continue }
            if chips.contains(where: { TextNormalizer.normalize($0.item.message) == norm }) { continue }
            let n = occurrences[norm, default: 0]
            occurrences[norm] = n + 1
            let item = QueueItem(id: "pi:\(n):\(norm.prefix(48))", clientMessageId: nil,
                                 message: text, status: "queued", queuedAt: nil)
            chips.append(QueueChip(rowId: "qpi:\(n):\(norm.prefix(48))", item: item,
                                   serverId: nil, origin: .piNative))
        }
        return (chips, deliveredLocal)
    }
}

// MARK: - Agent status reducer (contract v2 §5)

/// Single source of truth for working/idle/error. Pure value type so it is
/// unit-testable; `ChatLiveStatus` publishes its derived outputs.
struct AgentStatusState: Equatable {
    enum Event {
        /// `agent_status` frame. `v2` = frame carried the v2 `busy`/`owner`
        /// fields; `isSnapshot` = first status after a (re)connect.
        case status(busy: Bool, owner: String?, v2: Bool, isSnapshot: Bool)
        /// User just sent a prompt (optimistic "Waiting for response…").
        case optimisticSend
        /// Send failed / aborted before reaching the agent.
        case clearOptimistic
        /// Assistant/tool activity frame with an optional detail label.
        case activity(detail: String?)
        /// v1 lifecycle hints (agent_start/agent_end/file_update.working …);
        /// ignored once a v2 `agent_status` has been seen.
        case legacyBusy(Bool)
        case crashed
        case exited
    }

    private(set) var busy = false
    private(set) var optimisticSince: Date?
    private(set) var detail: String?
    private(set) var crashed = false
    private(set) var v2 = false
    private(set) var owner: String?
    private(set) var lastActivity: Date?

    /// Snapshot "idle" frames must not erase a send made moments ago (the
    /// reconnect snapshot can predate the turn start).
    static let optimisticGrace: TimeInterval = 8

    var isBusy: Bool { busy || optimisticSince != nil }

    var workingText: String? {
        if crashed { return "Agent crashed — restarting…" }
        if busy { return detail ?? "Working…" }
        if optimisticSince != nil { return "Waiting for response…" }
        return nil
    }

    mutating func apply(_ event: Event, now: Date = Date()) {
        switch event {
        case let .status(isBusy, owner, isV2, isSnapshot):
            if isV2 { v2 = true }
            if let owner { self.owner = owner }
            crashed = false
            if isBusy {
                if !busy { detail = nil }
                busy = true
                optimisticSince = nil
            } else {
                busy = false
                detail = nil
                if let since = optimisticSince {
                    let fresh = now.timeIntervalSince(since) < Self.optimisticGrace
                    if !(isSnapshot && fresh) { optimisticSince = nil }
                }
            }
        case .optimisticSend:
            if !busy { optimisticSince = now }
            crashed = false
        case .clearOptimistic:
            optimisticSince = nil
        case let .activity(label):
            lastActivity = now
            if !v2 {
                busy = true
                optimisticSince = nil
                crashed = false
            }
            if let label, busy || optimisticSince != nil { detail = label }
        case let .legacyBusy(isBusy):
            guard !v2 else { return }
            if isBusy {
                busy = true
                optimisticSince = nil
                crashed = false
            } else {
                busy = false
                detail = nil
                if let since = optimisticSince, now.timeIntervalSince(since) >= Self.optimisticGrace {
                    optimisticSince = nil
                }
            }
        case .crashed:
            crashed = true
            busy = false
            detail = nil
            optimisticSince = nil
        case .exited:
            optimisticSince = nil
            if !v2 {
                busy = false
                detail = nil
            }
        }
    }

    /// Drop a stale optimistic state (no agent_status/activity confirmed it).
    mutating func expireOptimistic(olderThan seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let since = optimisticSince, now.timeIntervalSince(since) >= seconds else { return false }
        optimisticSince = nil
        return true
    }
}
