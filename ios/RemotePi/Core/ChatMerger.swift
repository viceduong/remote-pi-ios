import Foundation

/// Pure, testable message-list merge logic. Every server-sourced update
/// (SSE echo, file_update, cursor refresh, pagination, reset reload) goes
/// through here so the same identity rules apply everywhere:
///
/// 1. Identity first: `entryId`, then `clientMessageId`.
/// 2. Text heuristics ONLY when identity cannot decide (one side has no
///    entry id, and the two sides don't both carry a client id).
/// 3. Matched rows keep their existing `id` (stable transcript identity) and
///    absorb the canonical copy.
/// 4. Unmatched server rows are INSERTED in server order (after the previous
///    server row, or by timestamp) — never appended blindly, never dropped.
enum ChatMerger {
    /// Heuristic match window for rows that both carry timestamps.
    static let heuristicWindowMs = 120_000

    /// Rows with neither entry id nor timestamp are "floating" local rows
    /// (the in-progress streaming bubble). They always stay at the tail.
    static func isFloating(_ m: ChatMessage) -> Bool {
        m.entryId == nil && m.timestamp == nil
    }

    /// Same logical message when identities can't tell them apart?
    static func heuristicMatch(local: ChatMessage, incoming: ChatMessage) -> Bool {
        guard local.role == incoming.role else { return false }
        if let a = local.entryId, let b = incoming.entryId { return a == b }
        if let a = local.clientMessageId, let b = incoming.clientMessageId { return a == b }
        if let a = local.timestamp, let b = incoming.timestamp, abs(a - b) > heuristicWindowMs {
            return false
        }
        // Q&A rows (contract §9): the live copy (no entry id) and the server
        // copy carry the same `qa` payload; their text may be empty.
        if local.qa != nil || incoming.qa != nil {
            guard let a = local.qa, let b = incoming.qa else { return false }
            return a == b
        }
        let ln = TextNormalizer.normalize(local.text)
        let rn = TextNormalizer.normalize(incoming.text)
        guard !ln.isEmpty, !rn.isEmpty else { return false }
        if ln == rn { return true }
        // Streaming continuation: the partial bubble is a prefix of the
        // canonical copy (or vice versa). Assistant rows only.
        if local.role == .assistant, min(ln.count, rn.count) >= 10,
           rn.hasPrefix(ln) || ln.hasPrefix(rn) {
            return true
        }
        // A bubble that started mid-message (its first deltas were lost, e.g.
        // across a stream reset) is a suffix/infix of the canonical copy.
        if isUnconfirmedFragment(local, of: incoming) { return true }
        return false
    }

    /// `local` is a not-yet-confirmed assistant bubble (no entry id) whose
    /// text appears inside `canonical`'s text (at least 10 characters).
    static func isUnconfirmedFragment(_ local: ChatMessage, of canonical: ChatMessage) -> Bool {
        guard local.role == .assistant, canonical.role == .assistant,
              local.entryId == nil, local.qa == nil else { return false }
        let fragment = TextNormalizer.normalize(local.text)
        let full = TextNormalizer.normalize(canonical.text)
        guard fragment.count >= 10, full.count > fragment.count else { return false }
        return full.contains(fragment)
    }

    /// Drop unconfirmed assistant bubbles (other than `keep`) whose text is
    /// contained in a confirmed assistant row — leftovers of a stream that
    /// lost its start or end. Never touches rows with an entry id.
    /// Only the most recent confirmed replies are candidates, so a new short
    /// reply that happens to repeat a phrase of an old message is never hit.
    static func pruneFragments(_ existing: inout [ChatMessage], keep: String?) {
        let confirmed = Array(existing.filter {
            $0.role == .assistant && $0.entryId != nil && $0.text.hasVisibleCharacters
        }.suffix(3))
        guard !confirmed.isEmpty else { return }
        existing.removeAll { row in
            row.id != keep && confirmed.contains { isUnconfirmedFragment(row, of: $0) }
        }
    }

    /// Index of the existing row representing `m`, if any.
    static func matchIndex(for m: ChatMessage, in existing: [ChatMessage]) -> Int? {
        if let eid = m.entryId, let i = existing.lastIndex(where: { $0.entryId == eid }) {
            return i
        }
        if let cid = m.clientMessageId,
           let i = existing.lastIndex(where: { $0.clientMessageId == cid && $0.role == m.role }) {
            // Same client id but a DIFFERENT entry id would be a distinct row.
            if existing[i].entryId == nil || m.entryId == nil { return i }
        }
        // Heuristic: only against rows that have no entry id yet.
        return existing.lastIndex(where: { $0.entryId == nil && heuristicMatch(local: $0, incoming: m) })
    }

    /// Fold the canonical `incoming` copy into the existing row, keeping the
    /// row's identity and any locally-known data the copy lacks.
    static func absorb(_ local: ChatMessage, _ incoming: ChatMessage) -> ChatMessage {
        var r = incoming
        r.id = local.id
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

    /// Insertion index for an unanchored row: before the first row with a
    /// later timestamp; rows without a timestamp sort last.
    static func timestampInsertionIndex(for m: ChatMessage, in existing: [ChatMessage]) -> Int {
        guard let ts = m.timestamp else {
            return existing.firstIndex(where: isFloating) ?? existing.count
        }
        return existing.firstIndex(where: { ($0.timestamp ?? Int.max) > ts }) ?? existing.count
    }

    /// Where an unmatched incoming row goes when nothing anchors it.
    enum Placement {
        /// Live / delta sources (SSE echoes, file tail, cursor refresh): the
        /// rows are the NEWEST in server order, so they go at the tail (before
        /// the streaming bubble). Timestamps can't be used: pi stamps a
        /// steered user message when it is QUEUED, but appends it after the
        /// assistant/tool rows produced while it waited — timestamp insertion
        /// put it ABOVE the agent's latest messages.
        case tail
        /// Out-of-band slices (older pages): place by timestamp.
        case timestamp
    }

    /// Merge an ordered server slice (delta, page, echo batch) into `existing`.
    static func merge(_ existing: inout [ChatMessage], _ incoming: [ChatMessage],
                      placement: Placement = .timestamp) {
        guard !incoming.isEmpty else { return }
        var cursor: Int?
        var seenEntries = Set<String>()
        for m in incoming {
            if let eid = m.entryId {
                guard seenEntries.insert(eid).inserted else { continue }
            }
            if let idx = matchIndex(for: m, in: existing) {
                existing[idx] = absorb(existing[idx], m)
                cursor = max(cursor ?? 0, idx + 1)
                continue
            }
            var at = cursor ?? (placement == .tail
                ? (existing.firstIndex(where: isFloating) ?? existing.count)
                : timestampInsertionIndex(for: m, in: existing))
            // Never insert below the floating streaming bubble.
            if let floating = existing.firstIndex(where: isFloating), at > floating { at = floating }
            at = min(max(at, 0), existing.count)
            existing.insert(m, at: at)
            cursor = at + 1
        }
    }

    /// Backwards-compatible name used by older call sites/tests.
    static func append(_ existing: inout [ChatMessage], _ tail: [ChatMessage]) {
        merge(&existing, tail)
    }

    /// Replace the tail covered by `page` (newest server rows) — used for
    /// the initial load, unknown-cursor refreshes and SSE `reset` frames.
    /// Older local rows outside the page's range are kept; local rows inside
    /// the range that the server no longer has are dropped; the floating
    /// streaming bubble is preserved. Row ids are preserved for matches.
    static func replaceTail(_ existing: inout [ChatMessage], with page: [ChatMessage],
                            keeping streamingId: String? = nil) {
        var deduped: [ChatMessage] = []
        deduped.reserveCapacity(page.count)
        var seen = Set<String>()
        for m in page {
            if let eid = m.entryId, !seen.insert(eid).inserted { continue }
            deduped.append(m)
        }
        let pageEntryIds = Set(deduped.compactMap(\.entryId))
        let oldest = deduped.compactMap(\.timestamp).min()
        let newest = deduped.compactMap(\.timestamp).max()

        var result: [ChatMessage] = []
        if let oldest {
            result = existing.filter { m in
                guard let eid = m.entryId, !pageEntryIds.contains(eid), let ts = m.timestamp else { return false }
                return ts < oldest
            }
        }
        let localByEntry = Dictionary(existing.compactMap { m in m.entryId.map { ($0, m) } },
                                      uniquingKeysWith: { first, _ in first })
        var identityLess = existing.filter { $0.entryId == nil }
        for p in deduped {
            if let eid = p.entryId, let local = localByEntry[eid] {
                result.append(absorb(local, p))
                continue
            }
            if let i = identityLess.firstIndex(where: { candidate in
                if let cid = p.clientMessageId, candidate.clientMessageId == cid { return true }
                return heuristicMatch(local: candidate, incoming: p)
            }) {
                result.append(absorb(identityLess[i], p))
                identityLess.remove(at: i)
                continue
            }
            result.append(p)
        }
        // Keep unconfirmed local rows that are newer than the page (or have
        // no timestamp at all), and ALWAYS the bubble that is still streaming:
        // it is not in the server history yet, and its timestamp (the message
        // start) can be older than the page's newest row — dropping it made
        // the next deltas start a new bubble mid-sentence.
        result.append(contentsOf: identityLess.filter {
            $0.id == streamingId || ($0.timestamp ?? Int.max) >= (newest ?? Int.min)
        })
        existing = result
        pruneFragments(&existing, keep: streamingId)
    }
}
