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

    /// Append `tail` to `existing`. Rules, in order:
    /// 1. Same entry id on the last bubble -> replace with the fuller copy
    ///    (SSE finalize vs file_update carry the same id, different lengths).
    /// 2. Strict text continuation of the last bubble (same role, close ts,
    ///    longer text starting with the partial) -> replace.
    /// 3. Otherwise dedupe by entry id / text-head + timestamp window.
    static func append(_ existing: inout [ChatMessage], _ tail: [ChatMessage]) {
        var toAdd: [ChatMessage] = []
        for m in tail {
            if let lastIdx = existing.indices.last {
                let last = existing[lastIdx]
                if last.role == m.role {
                    let a = last.text
                    let b = m.text
                    let sameEntry = last.entryId != nil && last.entryId == m.entryId
                    if sameEntry {
                        if a != b { existing[lastIdx] = m }
                        continue
                    }
                    let tsClose = abs((last.timestamp ?? 0) - (m.timestamp ?? 0)) < 3000
                    let continuation = tsClose && b.count > a.count && b.hasPrefix(a) && a.count >= 10
                    if continuation {
                        existing[lastIdx] = m
                        continue
                    }
                }
            }
            if isDuplicate(m, in: existing) { continue }
            toAdd.append(m)
        }
        if !toAdd.isEmpty { existing.append(contentsOf: toAdd) }
    }
}
