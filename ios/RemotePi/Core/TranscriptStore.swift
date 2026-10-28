import Foundation

/// The transcript as a pure projection of server truth (contract v2 §13).
///
/// Identity: every row has ONE identity from its first streamed delta to
/// history and cache — the server's message `key` (`<role>:<timestamp>`,
/// `tool:<toolCallId>`, `#n`-suffixed on collisions). For servers that send
/// no `key` (pre-§13) the view model derives the same `<role>:<timestamp>`
/// shape from the pi message timestamp, which pi stamps once and both
/// streams and persists (`ChatViewModel.identified`). A row without key AND
/// without entry id has no identity and is never stored.
///
/// Order: history pages define order; live rows are appended in ARRIVAL
/// order (live events arrive in server order). There is no timestamp
/// sorting and no text matching anywhere in this type.
///
/// Streamed text: a delta applies iff its `offset` equals the UTF-16 length
/// of the row's streamed text; a replayed delta (`offset <` length) is
/// ignored, a gap (`offset >` length) marks the row incomplete until a
/// snapshot / message_end / history copy replaces its text wholesale.
struct TranscriptStore {
    /// Streamed-text bookkeeping of a row that received live text.
    struct Stream: Equatable {
        /// UTF-16 length (JS `string.length`) of the streamed text so far —
        /// the next expected delta `offset`.
        var length = 0
        /// A delta was missed (offset gap) or the stream broke: the text is
        /// not authoritative until a snapshot / message_end / history copy.
        var incomplete = false
        /// message_end or the persisted copy arrived: deltas are ignored.
        var finished = false
    }

    enum DeltaOutcome: Equatable {
        case applied
        /// Replayed delta (already applied) — ignored.
        case duplicate
        /// Offset gap: the row is incomplete, the delta was NOT appended.
        case gap
        /// The row is finished/persisted (late replay) or nothing streams.
        case ignored
    }

    /// Where unanchored rows of a merged slice go.
    enum Placement {
        /// Newer rows (cursor delta, file tail): at the tail, but above the
        /// in-progress message (anything persisted precedes it).
        case newer
        /// An older page (pagination / visible-only fallback): at the top.
        case older
    }

    private(set) var rows: [ChatMessage] = []
    /// By row id.
    private(set) var streams: [String: Stream] = [:]
    /// Row id of the message currently streaming (message_start / snapshot).
    private(set) var inProgressId: String?
    /// Monotonic live-arrival counter. A reload keeps local rows that are not
    /// in its page only when they arrived live after the request started
    /// (`arrivals[id] > mark`, mark = `liveMark` at request start).
    private(set) var liveMark = 0
    private var arrivals: [String: Int] = [:]

    init(rows: [ChatMessage] = []) {
        self.rows = rows.filter(Self.hasIdentity)
    }

    static func hasIdentity(_ m: ChatMessage) -> Bool {
        m.key != nil || m.entryId != nil
    }

    // MARK: - Lookup

    func index(of m: ChatMessage) -> Int? {
        index(key: m.key, entryId: m.entryId)
    }

    /// Key first; entry id only when one side has no key (a row from a
    /// pre-§13 cache/server). Two different keys are two different rows.
    func index(key: String?, entryId: String?) -> Int? {
        if let key, let i = rows.lastIndex(where: { $0.key == key }) { return i }
        if let entryId, let i = rows.lastIndex(where: { $0.entryId == entryId }) {
            if key == nil || rows[i].key == nil { return i }
        }
        return nil
    }

    private func position(ofId id: String) -> Int? {
        if let last = rows.indices.last, rows[last].id == id { return last }
        return rows.lastIndex(where: { $0.id == id })
    }

    func stream(for rowId: String) -> Stream? { streams[rowId] }

    var inProgressRow: ChatMessage? {
        inProgressId.flatMap { id in position(ofId: id).map { rows[$0] } }
    }

    /// Settled = may be cached: not streaming, not broken.
    func isSettled(_ m: ChatMessage) -> Bool {
        guard Self.hasIdentity(m), m.id != inProgressId else { return false }
        if m.entryId != nil { return true }
        guard let s = streams[m.id] else { return true }
        return s.finished && !s.incomplete
    }

    /// Fold the canonical `incoming` copy into the existing row, keeping the
    /// row's id (no cell churn) and locally-known data the copy lacks.
    static func absorb(_ local: ChatMessage, _ incoming: ChatMessage) -> ChatMessage {
        var r = incoming
        r.id = local.id
        if r.key == nil { r.key = local.key }
        if r.entryId == nil { r.entryId = local.entryId }
        if r.clientMessageId == nil { r.clientMessageId = local.clientMessageId }
        if r.timestamp == nil { r.timestamp = local.timestamp }
        if r.thinking == nil { r.thinking = local.thinking }
        if r.model == nil { r.model = local.model }
        if !r.text.hasVisibleCharacters && local.text.hasVisibleCharacters { r.text = local.text }
        if r.toolCalls.isEmpty { r.toolCalls = local.toolCalls }
        if r.qa == nil { r.qa = local.qa }
        return r
    }

    private mutating func stamp(_ id: String) {
        liveMark += 1
        arrivals[id] = liveMark
    }

    private func isClosed(_ i: Int) -> Bool {
        rows[i].entryId != nil || streams[rows[i].id]?.finished == true
    }

    // MARK: - Live events

    /// A live row that is not streamed (user echo, Q&A row): upsert by
    /// identity; new rows go to the tail (arrival order).
    mutating func upsertLive(_ m: ChatMessage) {
        guard Self.hasIdentity(m) else { return }
        let id: String
        if let i = index(of: m) {
            rows[i] = Self.absorb(rows[i], m)
            id = rows[i].id
        } else {
            rows.append(m)
            id = m.id
        }
        stamp(id)
    }

    /// message_start of an assistant message: create/locate the row by key
    /// and make it the in-progress row. A replayed start of a message that
    /// already ended is ignored.
    mutating func start(_ m: ChatMessage) {
        guard Self.hasIdentity(m) else { return }
        if let i = index(of: m) {
            if isClosed(i) { return }
            rows[i] = Self.absorb(rows[i], m)
            beginStreaming(at: i)
        } else {
            rows.append(m)
            beginStreaming(at: rows.count - 1)
        }
    }

    private mutating func beginStreaming(at i: Int) {
        let id = rows[i].id
        if let current = inProgressId, current != id { supersede(current) }
        inProgressId = id
        if streams[id] == nil { streams[id] = Stream(length: rows[i].text.utf16.count) }
        stamp(id)
    }

    /// The in-progress message was replaced by another one without its end:
    /// its text is not authoritative any more.
    private mutating func supersede(_ id: String) {
        if var s = streams[id], !s.finished {
            s.incomplete = true
            streams[id] = s
        }
        if inProgressId == id { inProgressId = nil }
    }

    /// A keyed `text_delta` (§13 offsets). Creates the row when its
    /// message_start was missed; never appends across a gap.
    @discardableResult
    mutating func applyDelta(key: String, offset: Int?, delta: String) -> DeltaOutcome {
        let i: Int
        if let found = index(key: key, entryId: nil) {
            i = found
        } else {
            let row = ChatMessage(role: .assistant, text: "", thinking: nil, toolCalls: [], isError: false,
                                  toolName: nil, isSystemNote: false, model: nil, errorMessage: nil,
                                  timestamp: nil, key: key)
            rows.append(row)
            i = rows.count - 1
        }
        if isClosed(i) { return .ignored }
        if inProgressId != rows[i].id { beginStreaming(at: i) } else { stamp(rows[i].id) }
        return append(delta, offset: offset, at: i)
    }

    /// Pre-§13 server: deltas carry no key — they belong to the message the
    /// last message_start announced. Without one they only update status.
    @discardableResult
    mutating func appendLegacyDelta(_ delta: String) -> DeltaOutcome {
        guard let id = inProgressId, let i = position(ofId: id), !isClosed(i) else { return .ignored }
        stamp(id)
        return append(delta, offset: nil, at: i)
    }

    private mutating func append(_ delta: String, offset: Int?, at i: Int) -> DeltaOutcome {
        let id = rows[i].id
        var s = streams[id] ?? Stream(length: rows[i].text.utf16.count)
        defer { streams[id] = s }
        if s.incomplete { return .gap }
        let units = delta.utf16.count
        guard let offset else {
            rows[i].text += delta
            s.length += units
            return .applied
        }
        if offset == s.length {
            rows[i].text += delta
            s.length += units
            return .applied
        }
        if offset > s.length {
            s.incomplete = true
            return .gap
        }
        // offset < length: a re-sent frame. Fully applied → ignore; a frame
        // re-coalesced across the boundary → apply only its unseen suffix.
        if offset + units <= s.length { return .duplicate }
        let skip = s.length - offset
        guard let tail = String(delta.utf16.dropFirst(skip)) else {
            s.incomplete = true // boundary inside a surrogate pair
            return .gap
        }
        rows[i].text += tail
        s.length += tail.utf16.count
        return .applied
    }

    /// `message_snapshot` (§13): the in-progress message's streamed text so
    /// far — authoritative, replaces the row text wholesale.
    mutating func snapshot(key: String, timestamp: Int?, text: String) {
        let i: Int
        if let found = index(key: key, entryId: nil) {
            i = found
        } else {
            let row = ChatMessage(role: .assistant, text: "", thinking: nil, toolCalls: [], isError: false,
                                  toolName: nil, isSystemNote: false, model: nil, errorMessage: nil,
                                  timestamp: timestamp, key: key)
            rows.append(row)
            i = rows.count - 1
        }
        if isClosed(i) { return }
        rows[i].text = text // raw streamed text, like the deltas it stands for
        if rows[i].timestamp == nil { rows[i].timestamp = timestamp }
        streams[rows[i].id] = Stream(length: text.utf16.count)
        if inProgressId != rows[i].id { beginStreaming(at: i) } else { stamp(rows[i].id) }
    }

    /// message_end (or message_update done/error carrying the message):
    /// the canonical copy replaces the streamed text.
    mutating func finish(_ m: ChatMessage) {
        guard Self.hasIdentity(m) else { return }
        let i: Int
        if let found = index(of: m) {
            rows[found] = Self.absorb(rows[found], m)
            i = found
        } else {
            rows.append(m)
            i = rows.count - 1
        }
        let id = rows[i].id
        streams[id] = Stream(length: rows[i].text.utf16.count, incomplete: false, finished: true)
        if inProgressId == id { inProgressId = nil }
        stamp(id)
    }

    /// The stream broke (reset frame, agent went idle without message_end):
    /// the in-progress row stays but is not authoritative and no longer
    /// receives key-less deltas. Returns whether a message was in progress.
    @discardableResult
    mutating func interruptInProgress() -> Bool {
        guard let id = inProgressId else { return false }
        supersede(id)
        inProgressId = nil
        return true
    }

    // MARK: - Server pages

    /// Merge an ordered server slice (cursor delta, file tail row, older
    /// page): rows matched by identity are updated in place; unmatched rows
    /// are inserted right before the next matched row of the slice (server
    /// order), else after the last matched one, else at `placement`.
    /// Every row of a slice is persisted, hence finished.
    mutating func merge(_ page: [ChatMessage], placement: Placement, live: Bool = false) {
        var pending: [ChatMessage] = []
        var lastAnchor: Int?
        for m in Self.dedupe(page) {
            guard let found = index(of: m) else {
                pending.append(m)
                continue
            }
            var i = found
            if !pending.isEmpty {
                rows.insert(contentsOf: pending, at: i)
                for p in pending { settle(p.id, live: live) }
                i += pending.count
                pending.removeAll()
            }
            rows[i] = Self.absorb(rows[i], m)
            settle(rows[i].id, live: live)
            lastAnchor = i
        }
        guard !pending.isEmpty else { return }
        let at: Int
        if let lastAnchor {
            at = lastAnchor + 1
        } else {
            switch placement {
            case .older:
                at = 0
            case .newer:
                at = inProgressId.flatMap { position(ofId: $0) } ?? rows.count
            }
        }
        rows.insert(contentsOf: pending, at: min(max(at, 0), rows.count))
        for p in pending { settle(p.id, live: live) }
    }

    /// A reload (initial load, cursor-unknown refresh, `reset`): the page
    /// (newest server rows, server order) replaces the overlapping tail.
    /// Local rows older than the overlap are kept; local rows from the overlap
    /// on that the page lacks survive only if they arrived live after the
    /// request started (`arrivals > mark`) or are the in-progress message —
    /// they follow the page in their arrival order. Without any overlap the
    /// page replaces everything (keeping older rows would leave a hole).
    mutating func reload(_ page: [ChatMessage], keepingLiveAfter mark: Int) {
        let incoming = Self.dedupe(page)
        var matched = Set<Int>()
        var anchor: Int?
        var replaced: [ChatMessage] = []
        replaced.reserveCapacity(incoming.count)
        for p in incoming {
            if let i = index(of: p), !matched.contains(i) {
                matched.insert(i)
                anchor = min(anchor ?? i, i)
                replaced.append(Self.absorb(rows[i], p))
            } else {
                replaced.append(p)
            }
        }
        let overlapStart = anchor ?? rows.count
        var result: [ChatMessage] = []
        result.reserveCapacity(rows.count + replaced.count)
        if anchor != nil {
            for i in 0..<overlapStart where !matched.contains(i) { result.append(rows[i]) }
        }
        result.append(contentsOf: replaced)
        for i in rows.indices where !matched.contains(i) {
            let id = rows[i].id
            let keep = id == inProgressId || (arrivals[id] ?? 0) > mark
            // Rows before the overlap are already in `result`; without an
            // overlap every local row is a candidate.
            if anchor == nil || i >= overlapStart, keep { result.append(rows[i]) }
        }
        rows = result
        for r in replaced { settle(r.id, live: false) }
        pruneBookkeeping()
    }

    /// Persisted copy seen: the message ended; stop treating it as streaming.
    private mutating func settle(_ id: String, live: Bool) {
        if let i = position(ofId: id) {
            streams[id] = Stream(length: rows[i].text.utf16.count, incomplete: false, finished: true)
        }
        if inProgressId == id { inProgressId = nil }
        if live { stamp(id) }
    }

    /// Drop the oldest rows (live-tail memory bound).
    mutating func evictOldest(_ count: Int) {
        guard count > 0 else { return }
        rows.removeFirst(min(count, rows.count))
        pruneBookkeeping()
    }

    private mutating func pruneBookkeeping() {
        let ids = Set(rows.map(\.id))
        streams = streams.filter { ids.contains($0.key) }
        arrivals = arrivals.filter { ids.contains($0.key) }
        if let id = inProgressId, !ids.contains(id) { inProgressId = nil }
    }

    /// Identity-less rows are dropped; a duplicated identity keeps its first
    /// occurrence (the server never sends one).
    static func dedupe(_ page: [ChatMessage]) -> [ChatMessage] {
        var seenKeys = Set<String>()
        var seenEntries = Set<String>()
        var out: [ChatMessage] = []
        out.reserveCapacity(page.count)
        for m in page where hasIdentity(m) {
            if let key = m.key, !seenKeys.insert(key).inserted { continue }
            if let eid = m.entryId, !seenEntries.insert(eid).inserted { continue }
            out.append(m)
        }
        return out
    }
}
