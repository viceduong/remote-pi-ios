import Foundation

enum APIError: LocalizedError, Equatable {
    case invalidURL
    case http(Int, String, String?)
    case decoding(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .http(let code, let message, _):
            return code == 401 ? "Unauthorized — check the token" : "Server error \(code): \(message)"
        case .decoding(let detail): return "Bad response: \(detail)"
        case .offline: return "Cannot reach server"
        }
    }
}

/// Typed async REST client for the Remote Pi server.
struct APIClient {
    let baseURL: URL
    let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    private func makeRequest(_ path: String, method: String = "GET", body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        guard (200...299).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let message = body?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let apiCode = body?["code"] as? String
            throw APIError.http(http.statusCode, message, apiCode)
        }
        return data
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(makeRequest(path))
        return try await decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await send(makeRequest(path, method: "POST", body: body))
        return try await decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        guard !data.isEmpty else {
            throw APIError.decoding("empty response (server restarted?)")
        }
        do {
            // Decode off the main thread — large history/session payloads would
            // otherwise stutter the first frame when a chat opens.
            let result: T = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(T.self, from: data)
            }.value
            return result
        } catch {
            // Surface what actually came back so misconfigured URLs are obvious
            // (e.g. hitting a router page on port 80 because :8787 was omitted).
            let preview = String(data: data.prefix(160), encoding: .utf8) ?? "<binary>"
            throw APIError.decoding("\(String(describing: error)) — got: \(preview)")
        }
    }

    func postNoResponse(_ path: String, body: (any Encodable)? = nil) async throws {
        _ = try await send(makeRequest(path, method: "POST", body: body))
    }

    func delete(_ path: String) async throws {
        _ = try await send(makeRequest(path, method: "DELETE"))
    }

    // MARK: - Typed endpoints

    func fetchServerInfo() async throws -> ServerInfo {
        try await get("/api/config")
    }

    func listSessions(limit: Int = 50, before: Int? = nil) async throws -> (sessions: [SessionSummary], hasMore: Bool, total: Int) {
        struct Wrapper: Decodable {
            let sessions: [SessionSummary]
            let hasMore: Bool?
            let total: Int?
        }
        var query = "?limit=\(limit)"
        if let before { query += "&before=\(before)" }
        let wrapper: Wrapper = try await get("/api/sessions\(query)")
        return (wrapper.sessions, wrapper.hasMore ?? false, wrapper.total ?? 0)
    }

    func fetchSession(_ id: String) async throws -> SessionSummary {
        struct Wrapper: Decodable { let session: SessionSummary }
        let wrapper: Wrapper = try await get("/api/sessions/\(id)")
        return wrapper.session
    }

    func createSession(name: String) async throws -> SessionSummary {
        struct Wrapper: Decodable { let session: SessionSummary }
        struct Req: Encodable { let name: String }
        let wrapper: Wrapper = try await post("/api/sessions", body: Req(name: name))
        return wrapper.session
    }

    func deleteSession(_ id: String, purge: Bool = false) async throws {
        try await delete("/api/sessions/\(id)?purge=\(purge ? "1" : "0")")
    }

    /// GET /api/sessions/:id/messages — last N messages, paginated with `before`.
    func fetchMessages(_ id: String, limit: Int = 100, before: Int? = nil) async throws -> (messages: [ChatMessage], hasMore: Bool, total: Int) {
        struct Wrapper: Decodable {
            let messages: [WireMessage]
            let hasMore: Bool?
            let total: Int?
        }
        var query = "?limit=\(limit)"
        if let before { query += "&before=\(before)" }
        let wrapper: Wrapper = try await get("/api/sessions/\(id)/messages\(query)")
        return (wrapper.messages.map { $0.toChatMessage() }, wrapper.hasMore ?? false, wrapper.total ?? 0)
    }

    func sendTurn(_ id: String, message: String, force: Bool = false) async throws -> TurnResponse {
        let suffix = force ? "?force=1" : ""
        return try await post("/api/sessions/\(id)/turn\(suffix)", body: TurnRequest(message: message))
    }

    /// Fork the session at a user message (or latest when entryId is nil).
    func forkSession(_ id: String, entryId: String? = nil, name: String? = nil) async throws -> (SessionSummary, String?) {
        struct ForkRequest: Encodable {
            let entryId: String?
            let name: String?
        }
        struct Wrapper: Decodable {
            let session: SessionSummary
            let forkedFrom: String?
        }
        let wrapper: Wrapper = try await post("/api/sessions/\(id)/fork", body: ForkRequest(entryId: entryId, name: name))
        return (wrapper.session, wrapper.forkedFrom)
    }

    func abortTurn(_ id: String) async throws {
        try await postNoResponse("/api/sessions/\(id)/abort")
    }
}
