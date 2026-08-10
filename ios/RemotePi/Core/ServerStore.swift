import Foundation
import Combine

/// Persists server profiles in UserDefaults (Codable JSON).
@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerConfig] = []
    @Published var selectedServer: ServerConfig?

    private static let key = "remotePi.servers"

    init() {
        load()
    }

    func add(_ server: ServerConfig) {
        servers.append(server)
        save()
    }

    func update(_ server: ServerConfig) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            save()
        }
    }

    func remove(_ server: ServerConfig) {
        servers.removeAll { $0.id == server.id }
        if selectedServer?.id == server.id { selectedServer = nil }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return
        }
        servers = decoded
        selectedServer = servers.first
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
