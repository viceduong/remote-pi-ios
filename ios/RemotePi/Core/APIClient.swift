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

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    private func makeRequest(_ path: String, method: String = "GET", body: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Performs the request; returns the body + status without judging the
    /// status (network failures → `APIError.offline` / `CancellationError`).
    private func sendRaw(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            if APIClient.isCancellation(error) {
                throw CancellationError()
            }
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        // Bound accidental proxy/error payloads before JSON decoding or UI work.
        guard data.count <= 16 * 1024 * 1024 else {
            throw APIError.decoding("response exceeded 16 MiB safety limit")
        }
        return (data, http.statusCode)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, status) = try await sendRaw(req)
        guard (200...299).contains(status) else {
            throw Self.httpError(status: status, data: data)
        }
        return data
    }

    /// Like `send`, but §12 workdir rejections throw `WorkdirRejection`
    /// (carrying `roots`) instead of a generic `APIError.http`.
    private func sendWorkdirAware(_ req: URLRequest, dirsEndpoint: Bool) async throws -> Data {
        let (data, status) = try await sendRaw(req)
        guard (200...299).contains(status) else {
            if let rejection = WorkdirRejection.parse(status: status, data: data, dirsEndpoint: dirsEndpoint) {
                throw rejection
            }
            throw Self.httpError(status: status, data: data)
        }
        return data
    }

    private static func httpError(status: Int, data: Data) -> APIError {
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nestedMessage = (body?["error"] as? [String: Any])?["message"] as? String
        let message = body?["error"] as? String
            ?? nestedMessage
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let apiCode = body?["code"] as? String
        return APIError.http(status, message, apiCode)
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

    /// True for any flavour of "the caller went away" — these must never be
    /// surfaced to the user as errors.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
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

    /// `POST /api/sessions {name, workdir?, createDir?, clientRequestId?}`.
    /// `workdir == nil` sends the legacy body (server default folder), so this
    /// works against pre-§12 servers. Folder rejections (403
    /// `workdir_forbidden {roots}`, 404 `workdir_missing`, 400
    /// `workdir_not_dir` / invalid path) throw `WorkdirRejection`.
    func createSession(name: String, workdir: String? = nil, createDir: Bool = false,
                       clientRequestId: String? = nil) async throws -> SessionSummary {
        struct Wrapper: Decodable { let session: SessionSummary }
        struct Req: Encodable {
            let name: String
            let workdir: String?
            let createDir: Bool?
            let clientRequestId: String?
        }
        let body = Req(name: name, workdir: workdir,
                       createDir: workdir == nil ? nil : createDir,
                       clientRequestId: clientRequestId)
        let data = try await sendWorkdirAware(makeRequest("/api/sessions", method: "POST", body: body),
                                              dirsEndpoint: false)
        let wrapper = try await decode(Wrapper.self, from: data)
        return wrapper.session
    }

    /// Contract §12: `GET /api/dirs` → `{roots, recent, default}`. An older
    /// server answers 404 (→ `APIError.http(404, …)`).
    func dirRoots() async throws -> DirRoots {
        try await get("/api/dirs")
    }

    /// Contract §12: `GET /api/dirs?path=<abs>` → listing of subfolders.
    /// Outside the roots → `WorkdirRejection` (403, with `roots`).
    func listDirs(path: String) async throws -> DirListing {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            throw APIError.invalidURL
        }
        let data = try await sendWorkdirAware(makeRequest("/api/dirs?path=\(encoded)"), dirsEndpoint: true)
        return try await decode(DirListing.self, from: data)
    }

    /// Query-value-safe characters (`&`, `=`, `+`, `#` must be escaped).
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()

    func deleteSession(_ id: String, purge: Bool = false, force: Bool = false) async throws {
        var qs = "purge=\(purge ? "1" : "0")"
        if force { qs += "&force=1" }
        try await delete("/api/sessions/\(id)?\(qs)")
    }

    /// One page of `GET /api/sessions/:id/messages`.
    struct MessagePage {
        let messages: [ChatMessage]
        let hasMore: Bool
        let total: Int
        /// Server-derived working flag (v1 status hint; nil on `before` pages).
        let working: Bool?
        /// True when a `since` cursor was honoured (delta); false when the
        /// server fell back to a full tail page (unknown cursor). nil = old
        /// server that doesn't report it.
        let cursorMode: Bool?
    }

    /// GET /api/sessions/:id/messages — last N messages, paginated with `before`,
    /// or only the rows after an entry-id cursor with `since`.
    func fetchMessages(_ id: String, limit: Int = 100, before: Int? = nil, since: String? = nil,
                       visibleOnly: Bool = false) async throws -> MessagePage {
        struct Wrapper: Decodable {
            let messages: [WireMessage]
            let hasMore: Bool?
            let total: Int?
            let working: Bool?
            let cursorMode: Bool?
        }
        var query = "?limit=\(limit)"
        if let before { query += "&before=\(before)" }
        if let since, let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&since=\(encoded)"
        }
        if visibleOnly { query += "&visible=1" }
        let wrapper: Wrapper = try await get("/api/sessions/\(id)/messages\(query)")
        return MessagePage(messages: wrapper.messages.map { $0.toChatMessage() },
                           hasMore: wrapper.hasMore ?? false,
                           total: wrapper.total ?? 0,
                           working: wrapper.working,
                           cursorMode: wrapper.cursorMode)
    }

    /// One answer inside a questionnaire response (mirrors pi's QuestionAnswer).
    struct QuestionAnswerPayload: Encodable {
        let questionIndex: Int
        let question: String
        let kind: String          // "option" | "custom" | "chat" | "multi"
        let answer: String?
        let selected: [String]?
        let notes: String?
        let preview: String?
    }

    /// POST /api/sessions/:id/question/:requestId — answer an
    /// ask_user_question questionnaire (or cancel it).
    func answerQuestion(_ id: String, requestId: String,
                        answers: [QuestionAnswerPayload], cancelled: Bool) async throws {
        struct Ok: Decodable { let ok: Bool }
        struct Body: Encodable { let answers: [QuestionAnswerPayload]; let cancelled: Bool }
        let _: Ok = try await post("/api/sessions/\(id)/question/\(requestId)",
                                   body: Body(answers: answers, cancelled: cancelled))
    }

    func sendTurn(_ id: String, message: String, force: Bool = false,
                  clientMessageId: String? = nil) async throws -> TurnResponse {
        let suffix = force ? "?force=1" : ""
        return try await post("/api/sessions/\(id)/turn\(suffix)",
                              body: TurnRequest(message: message, clientMessageId: clientMessageId))
    }

    /// Contract §11: `GET /api/sessions/:id/models` → `{models, current}`.
    /// Decoding is tolerant (see `ModelListing`): older servers' nested
    /// `{models:{models:[…]}}` shape and malformed entries never fail it.
    func listModels(_ id: String) async throws -> ModelListing {
        try await get("/api/sessions/\(id)/models")
    }

    /// Contract §11: `POST /api/sessions/:id/models {provider, modelId}` →
    /// `{ok, model}`. Returns the model the server reports as applied, or
    /// nil when an older server answers only `{ok:true}`. Throws
    /// `APIError.http` on 404 (unknown model) / 502 (transport failure).
    func setModel(_ id: String, provider: String, modelId: String) async throws -> ModelRef? {
        struct Req: Encodable {
            let provider: String?
            let modelId: String
        }
        let data = try await send(makeRequest("/api/sessions/\(id)/models", method: "POST",
                                              body: Req(provider: provider.isEmpty ? nil : provider,
                                                        modelId: modelId)))
        return try Self.decodeSetModelResponse(data)
    }

    /// Body of a 2xx `POST /models`: `{ok:true, model:{provider,id,name}}`.
    /// An empty / non-JSON body or a missing/malformed `model` is still a
    /// success (legacy servers answer `{ok:true}`) → nil; `ok:false` throws.
    static func decodeSetModelResponse(_ data: Data) throws -> ModelRef? {
        struct Resp: Decodable {
            let ok: Bool?
            let model: Lenient<ModelEntry>?
        }
        guard !data.isEmpty, let resp = try? JSONDecoder().decode(Resp.self, from: data) else { return nil }
        if resp.ok == false { throw APIError.http(500, "Model switch was rejected", nil) }
        return resp.model?.value?.ref
    }

    func cycleModel(_ id: String) async throws {
        try await postNoResponse("/api/sessions/\(id)/models/cycle")
    }

    func fetchQueue(_ id: String) async throws -> [QueueItem] {
        struct Wrapper: Decodable { let items: [QueueItem] }
        let wrapper: Wrapper = try await get("/api/sessions/\(id)/queue")
        return wrapper.items
    }

    func cancelQueued(_ id: String, itemId: String) async throws {
        try await delete("/api/sessions/\(id)/queue/\(itemId)")
    }

    /// Contract §10: promote a queued item to immediate delivery, injecting it
    /// into the running turn (`streamingBehavior:"steer"`) and bypassing the
    /// busy gate. Throws `APIError.http` on 404 (not a queued item), 409
    /// `session_live` (host owns the file) or 502 (delivery failed); the item
    /// then stays queued server-side.
    func steerQueued(_ id: String, itemId: String) async throws {
        try await postNoResponse("/api/sessions/\(id)/queue/\(itemId)/steer")
    }

    /// Full tool output for a toolCallId (skeleton mode fetch-on-expand).
    func fetchToolResult(_ id: String, toolCallId: String) async throws -> String {
        struct Wrapper: Decodable { let text: String }
        let path = "/api/sessions/\(id)/toolresult/\(toolCallId)"
        let wrapper: Wrapper = try await get(path)
        return wrapper.text
    }

    /// pi 0.85 get_session_stats via the bridge.
    func fetchStats(_ id: String) async throws -> SessionStats {
        struct Wrapper: Decodable { let stats: StatsJSON }
        struct StatsJSON: Decodable {
            let tokens: [String: Int]
            let cost: Double?
            // Values can be null in the wire shape (seeded sidecars, models
            // without a known context window) — strict [String: Double]?
            // throws on null values and killed the whole decode.
            let contextUsage: [String: Double?]?
        }
        let wrapper: Wrapper = try await get("/api/sessions/\(id)/stats")
        var json: [String: Any] = [:]
        json["tokens"] = wrapper.stats.tokens
        json["cost"] = wrapper.stats.cost as Any?
        if let cu = wrapper.stats.contextUsage {
            var cleaned: [String: Any] = [:]
            for (key, value) in cu { if let value { cleaned[key] = value } }
            if !cleaned.isEmpty { json["contextUsage"] = cleaned }
        }
        if let stats = SessionStats(json: json) { return stats }
        throw APIError.decoding("malformed session stats")
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

/// Contract §12 endpoints used by the new-session sheet.
extension APIClient: WorkdirService {}
