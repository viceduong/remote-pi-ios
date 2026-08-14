import Foundation
import Combine
import Security

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
        Keychain.delete(for: server.id)
        if selectedServer?.id == server.id { selectedServer = nil }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return
        }
        servers = decoded.map { stored in
            var server = stored
            if let secret = Keychain.token(for: server.id), !secret.isEmpty {
                server.token = secret
            } else if !server.token.isEmpty {
                // Migrate existing plaintext profiles once. Keep the token in
                // memory; save() must not overwrite it with an empty value.
                _ = Keychain.save(server.token, for: server.id)
            }
            return server
        }
        save()
        selectedServer = servers.first
    }

    private func save() {
        var persisted: [ServerConfig] = []
        for var server in servers {
            if !server.token.isEmpty {
                // Store non-empty secrets, then strip only the persisted copy.
                // Empty-token writes would erase a valid existing Keychain item.
                if Keychain.save(server.token, for: server.id) {
                    server.token = ""
                } else {
                    // Never fall back to persisting bearer tokens in
                    // UserDefaults when Keychain is unavailable.
                    server.token = ""
                }
            }
            persisted.append(server)
        }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

private enum Keychain {
    private static let service = "com.aiching.remotepi.tokens"

    static func token(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String, for account: String) -> Bool {
        // Empty values are never valid secrets and must not erase an existing
        // credential accidentally during profile persistence.
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
