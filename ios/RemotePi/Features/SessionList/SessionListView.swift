import SwiftUI

/// Session list for one connected server — create, resume, delete, navigate to chat.
@MainActor
struct SessionListView: View {
    let server: ServerConfig
    @Environment(\.theme) private var theme

    @State private var sessions: [SessionSummary] = []
    @State private var searchText = ""
    @State private var loading = false
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var showNewSession = false
    @State private var newSessionName = ""
    @State private var errorMessage: String?
    @State private var serverInfo: ServerInfo?
    @State private var openSession: SessionSummary?

    private var client: APIClient {
        APIClient(baseURL: server.url ?? URL(string: "http://localhost")!, token: server.token)
    }

    private var filteredSessions: [SessionSummary] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.workdir ?? "").localizedCaseInsensitiveContains(searchText)
                || ($0.model ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serverInfo?.name ?? server.name)
                            .font(.headline)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(serverOnline ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                }
            }

            Section("Sessions") {
                if sessions.isEmpty {
                    Text("No sessions yet — tap + to start one.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if filteredSessions.isEmpty {
                    Text("No sessions match \"\(searchText)\"")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(filteredSessions) { session in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(session.name)
                                    .font(.body)
                                    .lineLimit(1)
                                if session.source == "pi" {
                                    Text("pi")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.18))
                                        .foregroundColor(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                            if let workdir = session.workdir {
                                Text(workdir)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 6) {
                                if session.writing == true {
                                    Label("ACTIVE NOW", systemImage: "dot.radiowaves.left.and.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(.green)
                                } else if session.live == true {
                                    Label("HOST", systemImage: "terminal")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(theme.accent)
                                } else {
                                    Text(session.running ? "running" : "stopped")
                                        .font(.caption2)
                                        .foregroundColor(session.running ? .green : .secondary)
                                    if session.active == true {
                                        Text("· recent")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                                if let model = session.model {
                                    Text("· \(model)")
                                        .lineLimit(1)
                                }
                                Text("· \(session.messageCount) msgs")
                                Text("· \(Self.relativeTime(session.lastMessageAt ?? session.lastActivityAt))")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        if session.busy {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(6)
                    .background(session.writing == true ? theme.terminalText.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { openSession = session }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(session)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if hasMore && searchText.isEmpty {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("scroll for more")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear {
                        Task { await loadMore() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
        .refreshable { await load() }
        .task { await load() }
        .task {
            // Live badge refresh: keep the "● working" indicator current.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                await loadQuiet()
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New session", isPresented: $showNewSession) {
            TextField("Name", text: $newSessionName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newSessionName = "" }
        }
        .background(
            NavigationLink(destination: Group {
                if let session = openSession {
                    ChatView(server: server, session: session)
                }
            }, isActive: Binding(
                get: { openSession != nil },
                set: { if !$0 { openSession = nil } }
            )) {
                EmptyView()
            }
        )
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var serverOnline: Bool {
        serverInfo != nil
    }

    private var statusLine: String {
        var parts: [String] = []
        if let pi = serverInfo?.piVersion { parts.append("pi \(pi)") }
        parts.append("\(server.baseURL)")
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            serverInfo = try await client.fetchServerInfo()
            let page = try await client.listSessions(limit: 50)
            sessions = page.sessions
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Infinite scroll: fetch the next older page at the bottom of the list.
    private func loadMore() async {
        guard hasMore, !isLoadingMore,
              let oldest = sessions.compactMap({ $0.lastMessageAt ?? $0.lastActivityAt }).min() else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.listSessions(limit: 50, before: oldest)
            let known = Set(sessions.map { $0.id })
            let fresh = page.sessions.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else {
                hasMore = page.hasMore
                return
            }
            sessions.append(contentsOf: fresh)
            hasMore = page.hasMore
        } catch {
            // transient — retry on next scroll
        }
    }

    /// 5s refresh merges the newest page without collapsing the pagination.
    private func loadQuiet() async {
        do {
            serverInfo = try await client.fetchServerInfo()
            let page = try await client.listSessions(limit: 50)
            var merged = sessions
            var byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
            for s in page.sessions {
                byId[s.id] = s
            }
            merged = byId.values.sorted { ($0.lastMessageAt ?? $0.lastActivityAt) > ($1.lastMessageAt ?? $1.lastActivityAt) }
            if merged.count < sessions.count { merged = sessions } // never shrink loaded pages
            sessions = merged
        } catch {
            // keep showing the last good list
        }
    }

    private func create() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        newSessionName = ""
        Task {
            do {
                let session = try await client.createSession(name: name)
                sessions.insert(session, at: 0)
                openSession = session
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ session: SessionSummary) {
        Task {
            do {
                try await client.deleteSession(session.id, purge: true)
                withAnimation {
                    sessions.removeAll { $0.id == session.id }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// "2m ago" for recent, date for old.
    private static func relativeTime(_ ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let now = Date()
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        if delta < 7 * 86400 { return "\(Int(delta / 86400))d ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}
