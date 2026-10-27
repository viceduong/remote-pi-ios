import Foundation
import SwiftUI

/// State behind `NewSessionSheet` (contract §12): optional name, working
/// folder with a debounced live status, recent folders, and an idempotent
/// create (`clientRequestId` reused on retry of the same request).
@MainActor
final class NewSessionModel: ObservableObject {
    /// Whether the server supports §12 (`GET /api/dirs`).
    enum FolderSupport: Equatable {
        case loading
        case supported(DirRoots)
        /// Older server (404 / non-§12 answer): hide the folder UI and create
        /// by name only.
        case unsupported
        /// Couldn't reach `/api/dirs` — keep the field (Create still works).
        case failed(String)
    }

    @Published var name = ""
    @Published var path: String {
        didSet {
            guard path != oldValue else { return }
            if !settingPathProgrammatically { userEditedPath = true }
            createError = nil
            scheduleStatusCheck()
        }
    }
    @Published private(set) var support: FolderSupport = .loading
    @Published private(set) var status: WorkdirStatus = .checking
    @Published private(set) var isCreating = false
    @Published private(set) var createError: String?

    let api: any WorkdirService
    private let memory: WorkdirMemory
    private let debounceNanos: UInt64
    private var settingPathProgrammatically = false
    private var userEditedPath = false
    private var loadTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    /// The outstanding create request: retried with the same id while the
    /// inputs are unchanged, so a timed-out-but-applied POST never creates
    /// a second session (or mkdirs twice).
    private var pendingRequest: (name: String, workdir: String?, id: String)?

    init(api: any WorkdirService, memory: WorkdirMemory, debounceNanos: UInt64 = 300_000_000) {
        self.api = api
        self.memory = memory
        self.debounceNanos = debounceNanos
        self.path = memory.lastUsed ?? ""
    }

    // MARK: Derived state

    var roots: [String] {
        if case .supported(let info) = support { return info.roots }
        return []
    }

    var recent: [RecentDir] {
        if case .supported(let info) = support { return info.recent }
        return []
    }

    var defaultDir: String? {
        if case .supported(let info) = support { return info.defaultDir }
        return nil
    }

    var showsFolderUI: Bool { support != .unsupported }

    var normalizedPath: String { WorkdirPath.normalize(path) }

    /// The `workdir` sent on Create (nil → server default / old server).
    var requestedWorkdir: String? {
        guard support != .unsupported else { return nil }
        let normalized = normalizedPath
        return normalized.isEmpty ? nil : normalized
    }

    var canCreate: Bool {
        guard !isCreating else { return false }
        guard showsFolderUI else { return true }
        return status.allowsCreate
    }

    /// Where "Browse…" opens: the typed folder when it exists, else nil (the
    /// browser then starts at the first root).
    var browseStart: String? {
        status == .existing ? normalizedPath : nil
    }

    func isSelected(_ recent: RecentDir) -> Bool {
        !path.isEmpty && WorkdirPath.same(recent.path, path)
    }

    // MARK: Actions

    func start() {
        guard case .loading = support, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.loadRoots()
        }
    }

    func retryLoad() {
        loadTask?.cancel()
        loadTask = nil
        support = .loading
        start()
    }

    /// Fill the field (recent row, browser pick).
    func pick(_ folder: String) {
        userEditedPath = true
        path = WorkdirPath.normalize(folder)
    }

    func loadRoots() async {
        defer { loadTask = nil }
        do {
            let info = try await api.dirRoots()
            guard !Task.isCancelled else { return }
            guard info.isUsable else {
                support = .unsupported
                return
            }
            support = .supported(info)
            if !userEditedPath, path.isEmpty, let fallback = memory.lastUsed ?? info.defaultDir {
                setPathProgrammatically(fallback)
            }
            scheduleStatusCheck(immediate: true)
        } catch {
            if APIClient.isCancellation(error) { return }
            switch error {
            case APIError.http(let code, _, _) where code == 404 || code == 405 || code == 501:
                support = .unsupported
            case APIError.decoding:
                // HTML / unrelated JSON from a pre-§12 server.
                support = .unsupported
            default:
                support = .failed(error.localizedDescription)
                scheduleStatusCheck(immediate: true)
            }
        }
    }

    /// Debounced `GET /api/dirs?path=` → status line. Syntax and root
    /// containment are checked locally first (no request).
    func scheduleStatusCheck(immediate: Bool = false) {
        checkTask?.cancel()
        checkTask = nil
        let target = normalizedPath
        if target.isEmpty {
            status = .serverDefault(defaultDir)
            return
        }
        if let local = WorkdirStatus.preflight(target, roots: roots) {
            status = local
            return
        }
        switch support {
        case .supported:
            break
        case .loading:
            status = .checking
            return
        case .unsupported:
            status = .serverDefault(nil)
            return
        case .failed:
            status = .unknown("Couldn't check the folder — the server will decide")
            return
        }
        status = .checking
        let api = self.api
        let roots = self.roots
        let delay = immediate ? 0 : debounceNanos
        checkTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            let result: WorkdirStatus
            do {
                let listing = try await api.listDirs(path: target)
                result = WorkdirStatus.from(listing: listing, roots: roots)
            } catch {
                if APIClient.isCancellation(error) { return }
                result = WorkdirStatus.from(error: error, roots: roots)
            }
            guard !Task.isCancelled, let self, self.normalizedPath == target else { return }
            self.status = result
        }
    }

    /// POST the session. Returns it on success (caller navigates); on
    /// failure sets `createError` (+ the field status for folder errors).
    func create() async -> SessionSummary? {
        guard canCreate else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir = requestedWorkdir
        if let workdir, let local = WorkdirStatus.preflight(workdir, roots: roots) {
            status = local
            createError = local.text
            return nil
        }
        let requestId: String
        if let pending = pendingRequest, pending.name == trimmedName, pending.workdir == workdir {
            requestId = pending.id
        } else {
            requestId = UUID().uuidString
            pendingRequest = (trimmedName, workdir, requestId)
        }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let session = try await api.createSession(name: trimmedName, workdir: workdir,
                                                      createDir: workdir != nil,
                                                      clientRequestId: requestId)
            pendingRequest = nil
            if case .supported = support, let used = session.workdir ?? workdir {
                memory.remember(used)
            }
            return session
        } catch {
            if APIClient.isCancellation(error) { return nil }
            let failure = WorkdirStatus.createFailure(error, roots: roots)
            if let fieldStatus = failure.status {
                checkTask?.cancel()
                checkTask = nil
                status = fieldStatus
            }
            createError = failure.message
            return nil
        }
    }

    private func setPathProgrammatically(_ value: String) {
        settingPathProgrammatically = true
        path = WorkdirPath.normalize(value)
        settingPathProgrammatically = false
    }

    #if DEBUG
    /// Test seam: install the `/api/dirs` answer + a field value/status as if
    /// loaded and checked (snapshots; no network, no debounce).
    func seedForTesting(roots: DirRoots, path: String, status: WorkdirStatus, name: String = "") {
        loadTask?.cancel()
        loadTask = nil
        support = .supported(roots)
        self.name = name
        setPathProgrammatically(path)
        checkTask?.cancel()
        checkTask = nil
        self.status = status
    }

    var pendingRequestIdForTesting: String? { pendingRequest?.id }
    #endif
}

/// State behind `FolderBrowserView`: one folder listing at a time, drilled
/// in place (up = parent, or the root list above a root when there are
/// several roots).
@MainActor
final class FolderBrowserModel: ObservableObject {
    enum State: Equatable {
        case loading
        /// Several roots and we're above them.
        case rootList
        case loaded(DirListing)
        case forbidden([String])
        case failed(String)
    }

    /// nil = the root list.
    @Published private(set) var path: String?
    @Published private(set) var state: State = .loading

    let roots: [String]
    let api: any WorkdirService
    private var loadTask: Task<Void, Never>?
    private var started = false

    init(api: any WorkdirService, roots: [String], start: String?) {
        self.api = api
        self.roots = roots
        if let start, !start.isEmpty {
            path = WorkdirPath.normalize(start)
        } else if let first = roots.first {
            path = WorkdirPath.normalize(first)
        } else {
            path = nil
        }
        if path == nil { state = .rootList }
    }

    var title: String {
        guard let path else { return "Folders" }
        return WorkdirPath.lastComponent(path)
    }

    var listing: DirListing? {
        if case .loaded(let listing) = state { return listing }
        return nil
    }

    /// Where "up" goes: the parent folder, `.some(nil)` for the root list,
    /// or nil when there's nowhere to go.
    var upDestination: String?? {
        guard let path else { return nil }
        let atRoot = roots.contains { WorkdirPath.same($0, path) }
        if !atRoot, let parent = listing?.parent ?? WorkdirPath.parent(path),
           roots.isEmpty || WorkdirPath.isInsideAny(parent, roots: roots) {
            return .some(parent)
        }
        return roots.count > 1 ? .some(nil) : nil
    }

    var canUse: Bool {
        guard path != nil else { return false }
        switch state {
        case .forbidden, .rootList: return false
        default: return true
        }
    }

    func onAppear() {
        guard !started else { return }
        started = true
        if case .loading = state { open(path) }
    }

    func goUp() {
        guard let destination = upDestination else { return }
        open(destination)
    }

    func retry() { open(path) }

    func open(_ target: String?) {
        loadTask?.cancel()
        loadTask = nil
        guard let target else {
            path = nil
            state = .rootList
            return
        }
        let normalized = WorkdirPath.normalize(target)
        path = normalized
        state = .loading
        let api = self.api
        let roots = self.roots
        loadTask = Task { [weak self] in
            let next: State
            do {
                let listing = try await api.listDirs(path: normalized)
                next = .loaded(listing)
            } catch {
                if APIClient.isCancellation(error) { return }
                switch WorkdirStatus.from(error: error, roots: roots) {
                case .notAllowed(let allowed): next = .forbidden(allowed)
                case .willCreate:
                    next = .loaded(DirListing(path: normalized, exists: false, isDir: false,
                                              parent: WorkdirPath.parent(normalized)))
                default:
                    next = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
            guard !Task.isCancelled, let self, self.path == normalized else { return }
            self.state = next
        }
    }

    #if DEBUG
    /// Test seam: show a listing as if loaded (snapshots; no network).
    func seedForTesting(_ listing: DirListing) {
        loadTask?.cancel()
        loadTask = nil
        started = true
        path = WorkdirPath.normalize(listing.path)
        state = .loaded(listing)
    }
    #endif
}
