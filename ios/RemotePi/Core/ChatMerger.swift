import Foundation

/// Pure, testable message-list merge logic. `ChatViewModel` uses this for all
/// server-sourced appends (SSE file_update, poll) so duplicates can never
/// slip through — the same rules apply everywhere.
enum ChatMerger {

    /// True when `m` already exists: same entry id, or same role + text head +
    /// near-identical timestamp (covers optimistic copies vs server echoes).
    static func isDuplicate(_ m: ChatMessage, in existing: [ChatMessage]) -> Bool {
        if let eid = m.entryId, existing.contains(where: { $0.entryId == eid }) { return true }
        return existing.contains { other in
            other.role == m.role
                && other.text.prefix(80) == m.text.prefix(80)
                && abs((other.timestamp ?? 0) - (m.timestamp ?? 0)) < 3000
        }
    }

    /// Append `tail` to `existing`. Dedupes by entry id; for same-role
    /// continuations of the last bubble (partial vs full text, or the same
    /// entry arriving from SSE and the file) it REPLACES the last bubble
    /// instead of appending a second copy.
    static func append(_ existing: inout [ChatMessage], _ tail: [ChatMessage]) {
        var toAdd: [ChatMessage] = []
        for m in tail {
            if isDuplicate(m, in: existing) { continue }
            if let lastIdx = existing.indices.last {
                let last = existing[lastIdx]
                if last.role == m.role {
                    let a = last.text
                    let b = m.text
                    let sameEntry = last.entryId != nil && last.entryId == m.entryId
                    let continuation = (a.isEmpty && !b.isEmpty)
                        || (b.hasPrefix(a) && a.count > 20)
                        || (a.hasPrefix(b) && b.count > 20)
                    if sameEntry || continuation {
                        existing[lastIdx] = m // replace with the fuller copy
                        continue
                    }
                }
            }
            toAdd.append(m)
        }
        if !toAdd.isEmpty { existing.append(contentsOf: toAdd) }
    }
}
