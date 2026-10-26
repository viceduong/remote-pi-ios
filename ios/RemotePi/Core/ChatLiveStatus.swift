import Foundation
import Combine

/// Smoothed output-tokens/second estimator fed from pi's cumulative
/// `message_update.usage`. Pure value type (timestamps are injected) so it is
/// unit-testable and never touches the clock on its own.
///
/// pi's usage is CUMULATIVE, so the rate is the output-token delta between two
/// usage frames over the wall-clock gap between them, smoothed with an EMA.
/// Frames closer together than `minInterval` are accumulated (the baseline is
/// not advanced) rather than dividing a tiny delta by a tiny interval. A
/// drop in the counter means a new turn / reset: the meter reseeds and emits
/// nothing until the next real sample.
struct TokenRateMeter {
    /// EMA weight on the newest sample (0…1): higher = more responsive.
    private let alpha: Double
    /// Minimum wall-clock gap between samples that actually update the rate.
    private let minInterval: TimeInterval

    private var lastOutput: Int?
    private var lastTime: Date?
    private var ema: Double?

    init(alpha: Double = 0.4, minInterval: TimeInterval = 0.2) {
        self.alpha = alpha
        self.minInterval = minInterval
    }

    /// Per-turn reset (new turn started or went idle).
    mutating func reset() {
        lastOutput = nil
        lastTime = nil
        ema = nil
    }

    /// Feed a cumulative output-token count observed at `now`. Returns the
    /// smoothed rate in tokens/sec once there is enough data, else nil.
    @discardableResult
    mutating func record(outputTokens: Int, at now: Date) -> Double? {
        guard let prevOut = lastOutput, let prevTime = lastTime else {
            lastOutput = outputTokens
            lastTime = now
            return ema
        }
        let delta = outputTokens - prevOut
        if delta < 0 {
            // Cumulative counter went backwards → new turn: reseed cleanly.
            lastOutput = outputTokens
            lastTime = now
            ema = nil
            return nil
        }
        let dt = now.timeIntervalSince(prevTime)
        // Too soon, or no new tokens yet: keep accumulating against the same
        // baseline so the next sample spans a meaningful interval.
        guard dt >= minInterval, delta > 0 else { return ema }
        lastOutput = outputTokens
        lastTime = now
        let instant = Double(delta) / dt
        ema = ema.map { alpha * instant + (1 - alpha) * $0 } ?? instant
        return ema
    }
}

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
    /// Kind of the displayed activity (banner icon); nil = spinner only.
    @Published private(set) var activityKind: AgentActivity.Kind?
    /// Local time the displayed activity started (elapsed counter origin).
    /// Changes only on kind/tool transitions — not every second.
    @Published private(set) var activitySince: Date?
    /// Live output throughput (whole tokens/sec), shown in the stats strip
    /// only while streaming and nonzero. Updated from usage frames, not from
    /// SwiftUI re-renders, and equality-gated on the displayed integer so the
    /// strip re-renders only when the number actually changes.
    @Published private(set) var tokensPerSecond: Int?

    /// Latest cumulative provider usage. Deliberately NOT published — nothing
    /// renders the per-token value, only its presence (`hasUsage`).
    private(set) var liveUsage: SessionUsage?
    private(set) var state = AgentStatusState()
    private var rateMeter = TokenRateMeter()

    /// Fires on every busy → idle transition (used to refresh stats).
    var onBecameIdle: (@MainActor () -> Void)?

    func apply(_ event: AgentStatusState.Event) {
        let wasBusy = state.isBusy
        state.apply(event)
        // The t/s meter is per-turn: reset on every busy edge (new turn
        // starting OR the turn ending) and clear the readout.
        if wasBusy != state.isBusy {
            rateMeter.reset()
            setTokensPerSecond(nil)
        }
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
        // Only track throughput while a turn is in flight; an idle usage frame
        // (e.g. the final total) must not revive the readout.
        guard state.isBusy else { return }
        if let rate = rateMeter.record(outputTokens: usage.output, at: Date()) {
            setTokensPerSecond(Int(rate.rounded()))
        }
    }

    /// Equality-gated; only a positive rate is shown.
    private func setTokensPerSecond(_ value: Int?) {
        let shown = (value ?? 0) > 0 ? value : nil
        if tokensPerSecond != shown { tokensPerSecond = shown }
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
        let kind = state.displayActivity?.kind
        if activityKind != kind { activityKind = kind }
        if activitySince != state.activitySince { activitySince = state.activitySince }
    }
}
