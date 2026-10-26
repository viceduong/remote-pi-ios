import Foundation
import Combine

/// Small, high-frequency status object observed ONLY by the status banner,
/// stats strip and toolbar control — so per-token status/usage changes never
/// invalidate the chat screen or the transcript.
///
/// Every published value is equality-gated: assigning an unchanged value
/// emits nothing.
@MainActor
final class ChatLiveStatus: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var workingText: String?
    @Published private(set) var stats: SessionStats?
    @Published private(set) var hasUsage = false
    /// Contract v2 `agent_status.owner == "tui"` (host terminal owns it).
    @Published private(set) var hostOwned = false

    /// Latest cumulative provider usage. Deliberately NOT published — nothing
    /// renders the per-token value, only its presence (`hasUsage`).
    private(set) var liveUsage: SessionUsage?
    private(set) var state = AgentStatusState()

    /// Fires on every busy → idle transition (used to refresh stats).
    var onBecameIdle: (@MainActor () -> Void)?

    func apply(_ event: AgentStatusState.Event) {
        let wasBusy = state.isBusy
        state.apply(event)
        publish()
        if wasBusy && !state.isBusy { onBecameIdle?() }
    }

    /// Clear an optimistic "Waiting…" nobody confirmed. Returns true if it fired.
    @discardableResult
    func expireOptimistic(olderThan seconds: TimeInterval) -> Bool {
        let wasBusy = state.isBusy
        guard state.expireOptimistic(olderThan: seconds) else { return false }
        publish()
        if wasBusy && !state.isBusy { onBecameIdle?() }
        return true
    }

    func setUsage(_ usage: SessionUsage) {
        liveUsage = usage
        if !hasUsage { hasUsage = true }
    }

    func setStats(_ value: SessionStats?) {
        if stats != value { stats = value }
    }

    private func publish() {
        if isBusy != state.isBusy { isBusy = state.isBusy }
        let text = state.workingText
        if workingText != text { workingText = text }
        let owned = state.owner == "tui"
        if hostOwned != owned { hostOwned = owned }
    }
}
