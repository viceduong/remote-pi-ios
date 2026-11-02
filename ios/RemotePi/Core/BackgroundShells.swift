import Foundation
import Combine
import UIKit

// MARK: - Wire models (contract §16)

/// One pi-bash background shell (`GET /api/sessions/:id/shells`).
///
/// Decoding is tolerant: only `id` is required. Numbers may arrive as ints,
/// doubles or numeric strings; times as ms epoch, seconds epoch or ISO-8601.
/// An unknown (newer) status string is kept as `.unknown(raw)`.
struct BackgroundShell: Decodable, Identifiable, Equatable {
    enum Status: Equatable {
        case running, completed, failed, killed
        case unknown(String)

        /// Case-insensitive mapping with a few synonyms for robustness.
        init(raw: String?) {
            let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch value {
            case "running", "run", "active", "started":
                self = .running
            case "completed", "complete", "done", "exited", "finished", "success", "succeeded":
                self = .completed
            case "failed", "error", "errored", "failure":
                self = .failed
            case "killed", "terminated", "cancelled", "canceled", "stopped", "aborted":
                self = .killed
            default:
                self = .unknown(value)
            }
        }

        var label: String {
            switch self {
            case .running: return "Running"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .killed: return "Killed"
            case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw.capitalized
            }
        }

        /// SF Symbol (all SF Symbols 1/2, i.e. iOS 13/14+).
        var symbolName: String {
            switch self {
            case .running: return "play.circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            case .killed: return "stop.circle.fill"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    let id: String
    let command: String
    let status: Status
    let pid: Int?
    /// ms epoch.
    let startTime: Int?
    /// ms epoch.
    let endTime: Int?
    let exitCode: Int?
    let durationMs: Int?
    let outputBytes: Int?

    init(id: String, command: String, status: Status, pid: Int? = nil, startTime: Int? = nil,
         endTime: Int? = nil, exitCode: Int? = nil, durationMs: Int? = nil, outputBytes: Int? = nil) {
        self.id = id
        self.command = command
        self.status = status
        self.pid = pid
        self.startTime = startTime
        self.endTime = endTime
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.outputBytes = outputBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, command, status, pid, startTime, endTime, exitCode, durationMs, outputBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id: String
        if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty {
            id = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            id = String(n)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "missing shell id")
        }
        self.init(id: id,
                  command: (try? c.decodeIfPresent(String.self, forKey: .command)) ?? "",
                  status: Status(raw: try? c.decodeIfPresent(String.self, forKey: .status)),
                  pid: FlexibleJSON.int(c, .pid),
                  startTime: FlexibleJSON.epochMs(c, .startTime),
                  endTime: FlexibleJSON.epochMs(c, .endTime),
                  exitCode: FlexibleJSON.int(c, .exitCode),
                  durationMs: FlexibleJSON.int(c, .durationMs),
                  outputBytes: FlexibleJSON.int(c, .outputBytes))
    }

    var isRunning: Bool { status == .running }

    var startDate: Date? {
        startTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Run time: live (`now - start`) while running; the server's
    /// `durationMs`, else `end - start`, once finished.
    func duration(now: Date) -> TimeInterval? {
        if isRunning {
            guard let start = startDate else { return durationMs.map { TimeInterval($0) / 1000 } }
            return max(0, now.timeIntervalSince(start))
        }
        if let durationMs, durationMs >= 0 { return TimeInterval(durationMs) / 1000 }
        if let startTime, let endTime, endTime >= startTime {
            return TimeInterval(endTime - startTime) / 1000
        }
        return nil
    }

    /// Copy with another status (optimistic "killed" after a kill).
    func with(status: Status) -> BackgroundShell {
        BackgroundShell(id: id, command: command, status: status, pid: pid, startTime: startTime,
                        endTime: endTime, exitCode: exitCode, durationMs: durationMs, outputBytes: outputBytes)
    }
}

/// `GET …/shells/:shellId/output` → `{text, truncated, size}`.
struct ShellOutput: Decodable, Equatable {
    let text: String
    let truncated: Bool
    /// Full log size in bytes (when the server reports it).
    let size: Int?

    init(text: String, truncated: Bool = false, size: Int? = nil) {
        self.text = text
        self.truncated = truncated
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case text, truncated, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? "",
                  truncated: (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false,
                  size: FlexibleJSON.int(c, .size))
    }
}

/// Result of `POST /api/sessions/:id/background` (Ctrl+B).
enum BackgroundBashOutcome: Equatable {
    /// `{detached:true}` — the bash now runs as a background shell.
    case detached
    /// `{detached:false}` — nothing was detached (it likely just finished).
    case notDetached
    /// `{detached:null}` — RPC child: requested, result unknown.
    case requested
    /// 409 — nothing is running.
    case nothingRunning
    /// 502 (or `unsupported:true`) — the server's message, e.g. "reload the TUI".
    case failed(String)
    /// 404 — the server predates §16.
    case unsupportedServer
}

enum FlexibleJSON {
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite,
           abs(d) < 9.0e18 { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let v = Int(t) { return v }
            if let d = Double(t), d.isFinite, abs(d) < 9.0e18 { return Int(d) }
        }
        return nil
    }

    /// ms epoch from a number (seconds epoch auto-detected) or ISO-8601 string.
    static func epochMs<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key), Double(s) == nil {
            return isoMs(s)
        }
        guard let v = int(c, key), v > 0 else { return nil }
        // < 1e11 can't be a plausible ms epoch (that's 1973) → seconds.
        return v < 100_000_000_000 ? v * 1000 : v
    }

    static func isoMs(_ string: String) -> Int? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return Int(date.timeIntervalSince1970 * 1000) }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return Int(date.timeIntervalSince1970 * 1000) }
        return nil
    }
}

// MARK: - Pure presentation logic (unit-tested)

/// "Background" button rule: only while the agent runs the bash tool.
enum BackgroundBashRule {
    static func isVisible(kind: AgentActivity.Kind?, tool: String?) -> Bool {
        guard kind == .tool, let tool else { return false }
        return tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bash"
    }
}

enum ShellListLogic {
    /// Running shells first, then newest first (unknown start last), then id.
    static func sorted(_ shells: [BackgroundShell]) -> [BackgroundShell] {
        shells.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            switch (a.startTime, b.startTime) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }

    static func runningCount(_ shells: [BackgroundShell]) -> Int {
        shells.reduce(0) { $0 + ($1.isRunning ? 1 : 0) }
    }
}

enum ShellFormat {
    /// "just now", "12s ago", "3m ago", "2h ago", "4d ago".
    static func ago(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        let s = Int(max(0, seconds))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// "<1s", "12s", "3m 05s", "1h 02m".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        if seconds < 1 { return "<1s" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    /// "Running · started 3m ago · 3m 05s" / "Failed · started 1h ago · took 12s · exit 1".
    static func subtitle(_ shell: BackgroundShell, now: Date) -> String {
        var parts = [shell.status.label]
        if let start = shell.startDate {
            parts.append("started \(ago(now.timeIntervalSince(start)))")
        }
        if let d = shell.duration(now: now) {
            parts.append(shell.isRunning ? duration(d) : "took \(duration(d))")
        }
        if !shell.isRunning, let code = shell.exitCode {
            parts.append("exit \(code)")
        }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

enum ShellOutputText {
    /// Terminal-ish cleanup before ANSI rendering: CRLF → LF and, for
    /// carriage-return progress lines (`\r` redraws), keep only the last
    /// redraw of each line.
    static func normalize(_ raw: String) -> String {
        // Check scalars, not Characters: Swift treats "\r\n" as ONE grapheme,
        // so `String.contains("\r")` is false for CRLF text.
        guard raw.unicodeScalars.contains("\r") else { return raw }
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard unified.unicodeScalars.contains("\r") else { return unified }
        return unified.components(separatedBy: "\n").map { line -> String in
            guard line.contains("\r") else { return line }
            let pieces = line.components(separatedBy: "\r")
            return pieces.last(where: { !$0.isEmpty }) ?? ""
        }.joined(separator: "\n")
    }

    /// Plain text for the pasteboard (SGR/CSI escape sequences removed).
    static func stripANSI(_ raw: String) -> String {
        guard raw.contains("\u{1B}") else { return raw }
        var out = ""
        out.reserveCapacity(raw.count)
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}" {
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    var j = i + 2
                    // CSI: parameters/intermediates, then a final byte in @…~.
                    while j < chars.count, !Self.isCSIFinal(chars[j]) { j += 1 }
                    i = min(j + 1, chars.count)
                    continue
                }
                i += 2 // ESC + one char (e.g. ESC=, ESC>)
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func isCSIFinal(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x40 && scalar.value <= 0x7E
    }
}

// MARK: - Service

/// §16 endpoints (injectable so tests run without a network).
protocol BackgroundShellService {
    func backgroundBash(_ sessionId: String) async throws -> BackgroundBashOutcome
    func listShells(_ sessionId: String) async throws -> [BackgroundShell]
    func shellOutput(_ sessionId: String, shellId: String, tail: Int) async throws -> ShellOutput
    func killShell(_ sessionId: String, shellId: String) async throws
}

// MARK: - Chat-scoped model

/// Background shells of one chat: the running-count badge (polled every
/// 10 s while the chat is open and on tool activity changes), the
/// "Background" (Ctrl+B) action with its transient notice, and kill.
/// A 404 from the server hides everything (`supported == false`).
@MainActor
final class BackgroundShellsModel: ObservableObject {
    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        case unsupported
    }

    struct Notice: Equatable, Identifiable {
        enum Kind: Equatable { case info, success, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    @Published private(set) var shells: [BackgroundShell] = []
    @Published private(set) var listState: ListState = .idle
    /// nil = not known yet; false = server predates §16 (hide the features).
    @Published private(set) var supported: Bool?
    @Published private(set) var isBackgrounding = false
    @Published private(set) var notice: Notice?
    @Published private(set) var killing: Set<String> = []
    /// Kill failure (shown as an alert by the sheet / viewer).
    @Published var actionError: String?

    let service: any BackgroundShellService
    let sessionId: String

    static let pollInterval: UInt64 = 10_000_000_000
    static let outputTail = 16_384

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var activityRefreshTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    private var statusCancellable: AnyCancellable?
    private var lastActivityKind: AgentActivity.Kind?

    init(service: any BackgroundShellService, sessionId: String) {
        self.service = service
        self.sessionId = sessionId
    }

    var runningCount: Int { ShellListLogic.runningCount(shells) }

    /// The chat menu entry: only once the server proved it supports §16.
    var showsMenuEntry: Bool { supported == true }

    func shell(id: String) -> BackgroundShell? { shells.first { $0.id == id } }

    // MARK: Lifecycle

    /// Start the 10 s poll and watch the chat's activity (idempotent).
    func start(observing status: ChatLiveStatus? = nil) {
        if let status, statusCancellable == nil {
            lastActivityKind = status.activityKind
            statusCancellable = status.$activityKind
                .combineLatest(status.$activityTool)
                .dropFirst()
                .sink { [weak self] kind, tool in
                    self?.activityChanged(kind: kind, tool: tool)
                }
        }
        guard pollTask == nil, supported != false else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if self.supported == false { break }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    /// Pause polling (chat closed / app backgrounded).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
        followUpTask?.cancel()
        followUpTask = nil
    }

    /// Full teardown (chat closed).
    func teardown() {
        stop()
        statusCancellable = nil
        noticeTask?.cancel()
        noticeTask = nil
    }

    /// Tool runs start/finish shells: refresh (debounced 1 s) whenever the
    /// activity enters or leaves a tool run. Cheap: one small GET.
    private func activityChanged(kind: AgentActivity.Kind?, tool: String?) {
        let previous = lastActivityKind
        lastActivityKind = kind
        guard supported != false, pollTask != nil else { return }
        guard kind == .tool || previous == .tool || kind == nil else { return }
        activityRefreshTask?.cancel()
        activityRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    // MARK: List

    /// Fetch the list (concurrent callers share one request).
    func refresh() async {
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        if shells.isEmpty, listState != .loaded { listState = .loading }
        do {
            let list = try await service.listShells(sessionId)
            setShells(ShellListLogic.sorted(list))
            if supported != true { supported = true }
            if listState != .loaded { listState = .loaded }
        } catch {
            if APIClient.isCancellation(error) {
                if listState == .loading { listState = .idle }
                return
            }
            if let api = error as? APIError, case .http(let code, _, _) = api, code == 404 {
                supported = false
                setShells([])
                listState = .unsupported
                return
            }
            let failure = ListState.failed(error.localizedDescription)
            if listState != failure { listState = failure }
        }
    }

    private func setShells(_ list: [BackgroundShell]) {
        if shells != list { shells = list }
    }

    // MARK: Background (Ctrl+B)

    /// Detach the running bash. Returns the request task (tests await it);
    /// nil while one is already in flight.
    @discardableResult
    func requestBackground() -> Task<Void, Never>? {
        guard !isBackgrounding else { return nil }
        isBackgrounding = true
        return Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.service.backgroundBash(self.sessionId)
                self.apply(outcome)
            } catch {
                if !APIClient.isCancellation(error) {
                    self.show(.error, Self.message(for: error, fallback: "Couldn't move to background"))
                }
            }
            self.isBackgrounding = false
        }
    }

    func apply(_ outcome: BackgroundBashOutcome) {
        switch outcome {
        case .detached:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(.success, "Moved to background")
            supported = true
            refreshSoon(after: 800_000_000)
        case .requested:
            show(.info, "Background requested")
            supported = true
            refreshSoon(after: 1_500_000_000)
        case .notDetached, .nothingRunning:
            show(.info, "Nothing running")
        case .failed(let message):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            show(.error, message.isEmpty ? "Couldn't move to background" : message)
        case .unsupportedServer:
            supported = false
            show(.error, "This server doesn't support backgrounding")
        }
    }

    private func refreshSoon(after nanos: UInt64) {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    // MARK: Notice

    func show(_ kind: Notice.Kind, _ text: String) {
        let notice = Notice(kind: kind, text: text)
        self.notice = notice
        noticeTask?.cancel()
        let nanos: UInt64 = kind == .error ? 6_000_000_000 : 2_500_000_000
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, self.notice?.id == notice.id else { return }
            self.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: Kill

    @discardableResult
    func kill(_ shellId: String) -> Task<Void, Never>? {
        guard !killing.contains(shellId) else { return nil }
        killing.insert(shellId)
        return Task { [weak self] in
            guard let self else { return }
            do {
                try await self.service.killShell(self.sessionId, shellId: shellId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // Optimistic: the next list fetch confirms it.
                self.setShells(ShellListLogic.sorted(self.shells.map {
                    $0.id == shellId && $0.isRunning ? $0.with(status: .killed) : $0
                }))
                self.killing.remove(shellId)
                await self.refresh()
            } catch {
                self.killing.remove(shellId)
                if !APIClient.isCancellation(error) {
                    self.actionError = Self.killMessage(for: error)
                    await self.refresh()
                }
            }
        }
    }

    static func killMessage(for error: Error) -> String {
        if let api = error as? APIError, case .http(let code, _, _) = api {
            if code == 404 { return "That shell no longer exists." }
            if code == 409 { return "That shell is no longer running." }
        }
        return message(for: error, fallback: "Couldn't kill the shell")
    }

    static func message(for error: Error, fallback: String) -> String {
        if let api = error as? APIError, case .http(let code, let message, _) = api, code != 401,
           !message.isEmpty { return message }
        let text = error.localizedDescription
        return text.isEmpty ? fallback : text
    }

    // MARK: Testing

    /// Seed state without a network (snapshots / unit tests).
    func seedForTesting(_ list: [BackgroundShell], state: ListState = .loaded, supported: Bool? = true) {
        shells = ShellListLogic.sorted(list)
        listState = state
        self.supported = supported
    }
}

// MARK: - Output viewer model

/// Tail of one shell's log: refreshed every 2 s while the shell runs (one
/// final fetch after it stops), rendered with ANSI colours by the viewer.
@MainActor
final class ShellOutputModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var output: ShellOutput?
    @Published private(set) var state: LoadState = .loading

    let shellId: String
    private let shells: BackgroundShellsModel

    static let refreshInterval: UInt64 = 2_000_000_000

    init(shellId: String, shells: BackgroundShellsModel) {
        self.shellId = shellId
        self.shells = shells
    }

    var shell: BackgroundShell? { shells.shell(id: shellId) }

    /// Poll loop (run from the view's `.task`; cancelled on disappear).
    func run() async {
        var finalFetchDone = false
        while !Task.isCancelled {
            await load()
            let running = shell?.isRunning ?? false
            if !running {
                if finalFetchDone { return }
                finalFetchDone = true
                // One more pass once the list confirms it stopped, so the
                // tail written just before exit is shown.
                if output != nil { return }
            }
            try? await Task.sleep(nanoseconds: Self.refreshInterval)
            guard !Task.isCancelled else { return }
            await shells.refresh()
        }
    }

    func load() async {
        do {
            let fetched = try await shells.service.shellOutput(shells.sessionId, shellId: shellId,
                                                               tail: BackgroundShellsModel.outputTail)
            if output != fetched { output = fetched }
            if state != .loaded { state = .loaded }
        } catch {
            if APIClient.isCancellation(error) { return }
            // Keep showing the last good output; surface the error only
            // when there is nothing to show.
            if output == nil {
                state = .failed(BackgroundShellsModel.message(for: error, fallback: "Couldn't load the output"))
            }
        }
    }

    func seedForTesting(_ output: ShellOutput?, state: LoadState) {
        self.output = output
        self.state = state
    }
}
