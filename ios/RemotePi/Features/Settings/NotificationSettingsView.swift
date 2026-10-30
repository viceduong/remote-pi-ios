import SwiftUI

/// State behind the per-server Notifications screen (contract §14).
@MainActor
final class NotificationSettingsModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded(NotifySettings)
        /// Older server without `/api/notify` (404).
        case unsupported
        case failed(String)
    }

    enum TestOutcome: Equatable {
        case sent
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    @Published var draft = NotifyDraft()
    @Published private(set) var isSaving = false
    @Published private(set) var isTesting = false
    @Published private(set) var saveError: String?
    @Published private(set) var didSave = false
    @Published private(set) var testOutcome: TestOutcome?

    let service: any NotifyService
    private var started = false

    init(service: any NotifyService) {
        self.service = service
    }

    var saved: NotifySettings? {
        if case .loaded(let settings) = state { return settings }
        return nil
    }

    var issues: NotifyIssues {
        guard let saved else { return NotifyIssues() }
        return draft.issues(against: saved)
    }

    var hasChanges: Bool {
        guard let saved else { return false }
        return !draft.patch(against: saved).isEmpty
    }

    var canSave: Bool {
        saved != nil && hasChanges && issues.isEmpty && !isSaving && !isTesting
    }

    /// A test needs a device key (stored or typed) and a savable form —
    /// pending edits are saved first.
    var canTest: Bool {
        guard let saved, issues.isEmpty, !isSaving, !isTesting else { return false }
        return saved.hasDeviceKey || !BarkValidation.deviceKey(from: draft.deviceKey).isEmpty
    }

    /// Level choices: the three standard ones, plus `critical` when the
    /// server already has it (so it isn't silently replaced).
    var levelOptions: [BarkLevel] {
        var options = BarkLevel.standard
        if draft.level == .critical || saved?.parsedLevel == .critical { options.append(.critical) }
        return options
    }

    func loadIfNeeded() async {
        guard !started else { return }
        started = true
        await load()
    }

    func load() async {
        if saved == nil { state = .loading }
        do {
            apply(try await service.notifySettings())
        } catch {
            if APIClient.isCancellation(error) {
                started = false
                return
            }
            state = Self.isUnsupported(error) ? .unsupported : .failed(error.localizedDescription)
        }
    }

    /// Sends the pending changes, then re-reads the server state (which also
    /// clears the write-only secret fields). Returns false on failure.
    @discardableResult
    func save() async -> Bool {
        guard let saved, issues.isEmpty, !isSaving else { return false }
        let patch = draft.patch(against: saved)
        guard !patch.isEmpty else { return true }
        isSaving = true
        saveError = nil
        didSave = false
        testOutcome = nil
        defer { isSaving = false }
        do {
            try await service.updateNotifySettings(patch)
            apply(try await service.notifySettings())
            didSave = true
            return true
        } catch {
            if APIClient.isCancellation(error) { return false }
            if Self.isUnsupported(error) {
                state = .unsupported
            } else {
                saveError = error.localizedDescription
            }
            return false
        }
    }

    func sendTest() async {
        guard canTest else { return }
        testOutcome = nil
        if hasChanges {
            guard await save() else { return }
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let result = try await service.sendTestNotification()
            testOutcome = result.ok ? .sent : .failed(result.failureMessage)
        } catch {
            if APIClient.isCancellation(error) { return }
            if Self.isUnsupported(error) {
                state = .unsupported
            } else {
                testOutcome = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ settings: NotifySettings) {
        state = .loaded(settings)
        draft = NotifyDraft(settings: settings)
    }

    private static func isUnsupported(_ error: Error) -> Bool {
        if case APIError.http(404, _, _) = error { return true }
        return false
    }

    #if DEBUG
    func seedForTesting(_ settings: NotifySettings, draft: NotifyDraft? = nil,
                        testOutcome: TestOutcome? = nil) {
        started = true
        apply(settings)
        if let draft { self.draft = draft }
        self.testOutcome = testOutcome
    }

    func seedForTesting(state: LoadState) {
        started = true
        self.state = state
    }
    #endif
}

/// Settings → Notifications for one server: Bark turn-end pushes (§14).
@MainActor
struct NotificationSettingsView: View {
    @StateObject private var model: NotificationSettingsModel
    let serverName: String

    init(model: @autoclosure @escaping () -> NotificationSettingsModel, serverName: String) {
        _model = StateObject(wrappedValue: model())
        self.serverName = serverName
    }

    init(server: ServerConfig) {
        let client = APIClient(baseURL: server.url ?? URL(string: "http://localhost")!, token: server.token)
        self.init(model: NotificationSettingsModel(service: client),
                  serverName: server.name.isEmpty ? server.baseURL : server.name)
    }

    var body: some View {
        Form {
            switch model.state {
            case .loading:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…").foregroundColor(.secondary)
                    }
                }
            case .unsupported:
                Section {
                    Label {
                        Text("Server doesn't support notifications — update the server")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    }
                } footer: {
                    Text("Update remote-pi-server on \(serverName), then come back here. "
                         + "(An up-to-date server may have notifications turned off with REMOTE_PI_NOTIFY=0.)")
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await model.load() } }
                } header: {
                    Text("Couldn't load notification settings")
                }
            case .loaded(let saved):
                loadedSections(saved)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else if model.saved != nil {
                    Button("Save") { Task { await model.save() } }
                        .font(.body.weight(.semibold))
                        .disabled(!model.canSave)
                }
            }
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: Sections

    @ViewBuilder
    private func loadedSections(_ saved: NotifySettings) -> some View {
        let issues = model.issues

        Section {
            Toggle("Turn-end notifications", isOn: $model.draft.enabled)
        } footer: {
            Text("Get a push through the Bark app when an agent on \(serverName) finishes a turn. "
                 + "Tapping it opens the session.")
        }

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL").font(.caption).foregroundColor(.secondary)
                TextField(NotifySettings.defaultBarkServer, text: $model.draft.barkServer)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if let problem = issues.server { issueText(problem) }
            }
            VStack(alignment: .leading, spacing: 6) {
                secretHeader("Device key", isSet: saved.hasDeviceKey)
                SecureField(saved.hasDeviceKey ? "Enter to replace" : "Paste the key (or the whole Bark URL)",
                            text: $model.draft.deviceKey)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if let problem = issues.deviceKey { issueText(problem) }
            }
        } header: {
            Text("Bark")
        } footer: {
            Text("Install Bark from the App Store and open it. Your device key is the code in the URL Bark "
                 + "shows — https://api.day.app/<device key>/… — paste just the key or the whole URL.")
        }

        Section {
            Toggle("Encrypt notifications", isOn: $model.draft.encryptionEnabled)
            if model.draft.encryptionEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Algorithm").font(.caption).foregroundColor(.secondary)
                    Picker("Algorithm", selection: $model.draft.algorithm) {
                        ForEach(BarkAlgorithm.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode").font(.caption).foregroundColor(.secondary)
                    Picker("Mode", selection: $model.draft.mode) {
                        ForEach(BarkMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.draft.mode == .gcm
                         ? "GCM is advanced (not documented by Bark) — CBC is recommended."
                         : "CBC is recommended.")
                        .font(.caption)
                        .foregroundColor(model.draft.mode == .gcm ? .orange : .secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    secretHeader("Key", isSet: saved.encryption.hasKey)
                    SecureField("\(model.draft.algorithm.keyLength) characters", text: $model.draft.key)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    lengthLine(issue: issues.key, entered: model.draft.key,
                               required: model.draft.algorithm.keyLength,
                               hint: "\(model.draft.algorithm.label) uses a \(model.draft.algorithm.keyLength)-character key")
                }
                if let ivLength = model.draft.mode.ivLength {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IV (optional)").font(.subheadline)
                        SecureField("\(ivLength) characters", text: $model.draft.iv)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        lengthLine(issue: issues.iv, entered: model.draft.iv, required: ivLength,
                                   hint: "\(model.draft.mode.label) uses a \(ivLength)-character IV. "
                                       + "Each push carries its own random IV, so Bark's IV can be any "
                                       + "\(ivLength) characters.")
                    }
                }
            } else if let problem = issues.key {
                issueText(problem)
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("In Bark → Settings → Encryption set the same algorithm, mode and key. Bark's IV field can "
                 + "be anything of the right length — every push carries its own random IV. "
                 + "Only the encrypted text leaves your server.")
        }

        Section {
            Picker("Level", selection: $model.draft.level) {
                ForEach(model.levelOptions) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Level")
        } footer: {
            Text(levelHelp(model.draft.level))
        }

        Section {
            Button {
                Task { await model.sendTest() }
            } label: {
                HStack(spacing: 8) {
                    if model.isTesting {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane")
                    }
                    Text(model.hasChanges ? "Save & send test notification" : "Send test notification")
                }
            }
            .disabled(!model.canTest)
            if let saveError = model.saveError {
                outcomeLine(text: "Couldn't save: \(saveError)", ok: false)
            } else if let outcome = model.testOutcome {
                switch outcome {
                case .sent:
                    outcomeLine(text: "Test notification sent — check your iPhone.", ok: true)
                case .failed(let message):
                    outcomeLine(text: "Test failed: \(message)", ok: false)
                }
            } else if model.didSave && !model.hasChanges {
                outcomeLine(text: "Saved.", ok: true)
            }
        }
    }

    // MARK: Pieces

    private func secretHeader(_ title: String, isSet: Bool) -> some View {
        let status: String = isSet ? "set" : "not set"
        return HStack {
            Text(title).font(.subheadline)
            Spacer()
            Label(status, systemImage: isSet ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .foregroundColor(isSet ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func issueText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func lengthLine(issue: String?, entered: String, required: Int, hint: String) -> some View {
        if let issue {
            issueText(issue)
        } else if !entered.isEmpty {
            Label("\(entered.utf8.count)/\(required) characters", systemImage: "checkmark")
                .font(.caption)
                .foregroundColor(.green)
        } else {
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func outcomeLine(text: String, ok: Bool) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
        }
        .font(.footnote)
        .foregroundColor(ok ? .green : .red)
    }

    private func levelHelp(_ level: BarkLevel) -> String {
        switch level {
        case .active: return "Active: a normal notification."
        case .timeSensitive:
            return "Time Sensitive: breaks through Focus — allow Time Sensitive notifications for Bark in iOS Settings."
        case .passive: return "Passive: added to Notification Center silently, without lighting the screen."
        case .critical: return "Critical: plays a sound even when muted (needs Bark's critical-alert permission)."
        }
    }
}
