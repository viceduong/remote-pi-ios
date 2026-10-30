import SwiftUI

/// Server profile list — connect / add / remove pi servers.
@MainActor
struct ServerListView: View {
    @EnvironmentObject private var store: ServerStore
    @Environment(\.theme) private var theme
    @AppStorage("chatTextScale") private var textScale: Double = 1.0
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var testingID: String?
    @State private var errorMessage: String?
    @State private var showSessionsFor: ServerConfig?
    @State private var editingServer: ServerConfig?
    @State private var showEdit = false
    /// One-shot: with a single configured host, jump straight into it instead
    /// of showing a list of one. Never re-fires after the user backs out.
    @State private var didAutoSelect = false
    @ObservedObject private var deepLinks = DeepLinkRouter.shared
    @State private var deepLinkTask: Task<Void, Never>?

    var body: some View {
        List {
            if store.servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No servers yet")
                        .font(.headline)
                    Text("Add your pi host — run `remote-pi-server` on it and enter its URL + token.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.servers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.name.isEmpty ? server.baseURL : server.name)
                                .font(.headline)
                            Text(server.baseURL)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if testingID == server.id {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { connect(server) }
                    .swipeActions(edge: .trailing) {
                        Button {
                            editingServer = server
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                        Button(role: .destructive) {
                            withAnimation { store.remove(server) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .task { autoSelectSingleHost() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(servers: store.servers)
        }
        .sheet(isPresented: $showAdd) {
            ServerEditView(store: store)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(store: store, editing: server)
        }
        .background(
            NavigationLink(destination: Group {
                if let server = showSessionsFor {
                    SessionListView(server: server)
                }
            }, isActive: Binding(
                get: { showSessionsFor != nil },
                set: { if !$0 { showSessionsFor = nil } }
            )) {
                EmptyView()
            }
        )
        .onReceive(deepLinks.$pendingSessionId) { id in
            guard let id else { return }
            // Deferred: `$pendingSessionId` fires in willSet, so clearing it
            // here synchronously would be overwritten by the in-flight set.
            Task { @MainActor in
                guard deepLinks.pendingSessionId == id else { return }
                openDeepLink(sessionId: id)
            }
        }
        .alert("Connection failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Single-host convenience: skip the one-row list and connect immediately.
    private func autoSelectSingleHost() {
        guard !didAutoSelect, deepLinks.pendingSessionId == nil, store.servers.count == 1,
              let only = store.servers.first, showSessionsFor == nil else { return }
        didAutoSelect = true
        connect(only)
    }

    /// `remotepi://session/<id>`: look the session up on the selected /
    /// last-used server, then navigate server → sessions → chat. Not found
    /// (or unreachable) → error banner.
    private func openDeepLink(sessionId: String) {
        deepLinks.pendingSessionId = nil
        // A deep link supersedes the single-host auto-connect.
        didAutoSelect = true
        guard let server = store.preferredServer, let url = server.url else {
            deepLinks.show("Add a server first — then open the notification again.", isError: true)
            return
        }
        showSettings = false
        showAdd = false
        editingServer = nil
        deepLinks.show("Opening session…", isError: false)
        deepLinkTask?.cancel()
        let client = APIClient(baseURL: url, token: server.token)
        let serverName = server.name.isEmpty ? server.baseURL : server.name
        deepLinkTask = Task {
            do {
                let session = try await client.fetchSession(sessionId)
                guard !Task.isCancelled else { return }
                deepLinks.dismissBanner()
                store.selectedServer = server
                deepLinks.openRequest = DeepLinkRouter.OpenRequest(serverId: server.id, session: session)
                if showSessionsFor?.id == server.id {
                    // Its SessionListView is on the stack and opens the chat.
                    return
                }
                if showSessionsFor != nil {
                    // Another server's stack is showing: pop, then push
                    // (pop + push in one pass is unreliable on iOS 15).
                    showSessionsFor = nil
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    guard !Task.isCancelled else { return }
                }
                showSessionsFor = server
            } catch {
                guard !APIClient.isCancellation(error), !Task.isCancelled else { return }
                if case APIError.http(404, _, _) = error {
                    deepLinks.show("Session not found on \(serverName).", isError: true)
                } else {
                    deepLinks.show("Couldn't open the session on \(serverName): \(error.localizedDescription)",
                                   isError: true)
                }
            }
        }
    }

    private func connect(_ server: ServerConfig) {
        guard let url = server.url else { return }
        testingID = server.id
        let client = APIClient(baseURL: url, token: server.token)
        Task {
            do {
                _ = try await client.fetchServerInfo()
                store.selectedServer = server
                showSessionsFor = server
            } catch is CancellationError {
                // Navigation cancelled — not an error.
            } catch {
                errorMessage = error.localizedDescription
            }
            testingID = nil
        }
    }
}

/// Add/edit form for one server profile.
@MainActor
struct ServerEditView: View {
    @ObservedObject var store: ServerStore
    let editing: ServerConfig?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""
    @State private var token = ""
    @State private var testing = false
    @State private var errorMessage: String?
    @State private var valid = false

    init(store: ServerStore, editing: ServerConfig? = nil) {
        self.store = store
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _baseURL = State(initialValue: editing?.baseURL ?? "")
        _token = State(initialValue: editing?.token ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $name)
                    TextField("URL", text: $baseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .placeholder("http://192.168.1.20:8787", when: baseURL.isEmpty)
                    SecureField("Bearer token", text: $token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section {
                    Button {
                        test()
                    } label: {
                        HStack {
                            if testing {
                                ProgressView()
                            } else {
                                Label("Test connection", systemImage: "bolt.horizontal.circle")
                            }
                        }
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add server" : "Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!valid)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func test() {
        guard let url = URL(string: normalize(baseURL)) else {
            errorMessage = "Invalid URL"
            return
        }
        testing = true
        errorMessage = nil
        let client = APIClient(baseURL: url, token: token)
        Task {
            do {
                let info = try await client.fetchServerInfo()
                valid = true
                errorMessage = "Connected ✓ pi \(info.piVersion ?? "?")"
            } catch is CancellationError {
                valid = false
            } catch {
                valid = false
                errorMessage = error.localizedDescription
            }
            testing = false
        }
    }

    private func save() {
        let normalized = normalize(baseURL)
        if let editing {
            store.update(ServerConfig(
                id: editing.id,
                name: name.isEmpty ? normalized : name,
                baseURL: normalized,
                token: token
            ))
        } else {
            var server = ServerConfig(
                id: UUID().uuidString,
                name: name,
                baseURL: normalized,
                token: token
            )
            if server.name.isEmpty {
                server.name = server.baseURL
            }
            store.add(server)
        }
        dismiss()
    }

    private func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

private extension View {
    func placeholder(_ text: String, when show: Bool) -> some View {
        ZStack(alignment: .leading) {
            if show {
                Text(text).foregroundColor(.secondary).opacity(0.6)
            }
            self
        }
    }
}
