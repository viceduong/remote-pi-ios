import Foundation

// MARK: - Wire models (mirror of the Remote Pi server API)

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var baseURL: String       // e.g. http://192.168.1.20:8787
    var token: String

    var url: URL? { URL(string: baseURL) }
}

/// GET /api/config
struct ServerInfo: Decodable {
    let name: String
    let piVersion: String?
    let api: String
    let workdir: String?
    let features: [String]?
}

struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let running: Bool
    let busy: Bool
    let model: String?
    let messageCount: Int
    let createdAt: Int
    let lastActivityAt: Int
    /// Actual last message time (pi bumps mtime on open).
    let lastMessageAt: Int?
    /// Runtime phase: idle/streaming/awaitingInput/terminated.
    let phase: String?
    /// Who owns the agent runtime: none/terminal/bridge.
    let owner: String?
    let error: String?
    /// 'app' = created in RemotePi; 'pi' = pre-existing host session.
    let source: String?
    /// True when the agent is currently working (or was live on the host recently).
    let active: Bool?
    /// True when an external (non-bridge) pi process owns this session right now.
    let live: Bool?
    let livePid: Int?
    /// True when the session file was written in the last 30s (agent working now).
    let writing: Bool?
    /// Working directory of the agent.
    let workdir: String?
    /// Contract §7: what an attached transport is doing right now. Decoded
    /// leniently — a malformed value is nil, never a failed list.
    let activity: Lenient<AgentActivity>?

    /// The decoded activity (nil when absent, null or malformed).
    var currentActivity: AgentActivity? { activity?.value }
}

/// Decodes `T` leniently: a malformed value becomes `value == nil` instead of
/// failing the enclosing payload (use as `Lenient<T>?` for optional keys).
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(_ value: T?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension Lenient: Encodable where T: Encodable {
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

extension Lenient: Equatable where T: Equatable {}
extension Lenient: Hashable where T: Hashable {}

/// Contract §7 `agent_status.activity` / session-summary `activity`: what
/// the agent is doing right now.
struct AgentActivity: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case waiting, thinking, writing, toolcall, tool, compacting, retrying, question
    }

    var kind: Kind
    /// ms epoch (server clock) when THIS kind/tool started.
    var since: Int?
    /// ms epoch when the current CONTINUOUS busy period began — stable across
    /// sub-activity transitions, correct across reconnects (contract §7). The
    /// banner's elapsed timer reads from this. Absent on older servers.
    var busySince: Int?
    var tool: String?
    var toolCount: Int?
    var reason: String?
    var percent: Int?
    var attempt: Int?
    var maxAttempts: Int?
    var delayMs: Int?

    init(kind: Kind, since: Int? = nil, busySince: Int? = nil, tool: String? = nil, toolCount: Int? = nil,
         reason: String? = nil, percent: Int? = nil, attempt: Int? = nil,
         maxAttempts: Int? = nil, delayMs: Int? = nil) {
        self.kind = kind
        self.since = since
        self.busySince = busySince
        self.tool = tool.flatMap { $0.isEmpty ? nil : $0 }
        self.toolCount = toolCount
        self.reason = reason
        self.percent = percent
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.delayMs = delayMs
    }

    private enum CodingKeys: String, CodingKey {
        case kind, since, busySince, tool, toolCount, reason, percent, attempt, maxAttempts, delayMs
    }

    /// Only `kind` is required; an unknown (newer) kind reads as "waiting".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        self.init(kind: Kind(rawValue: raw) ?? .waiting,
                  since: Self.flexibleInt(c, .since),
                  busySince: Self.flexibleInt(c, .busySince),
                  tool: try? c.decodeIfPresent(String.self, forKey: .tool),
                  toolCount: Self.flexibleInt(c, .toolCount),
                  reason: try? c.decodeIfPresent(String.self, forKey: .reason),
                  percent: Self.flexibleInt(c, .percent),
                  attempt: Self.flexibleInt(c, .attempt),
                  maxAttempts: Self.flexibleInt(c, .maxAttempts),
                  delayMs: Self.flexibleInt(c, .delayMs))
    }

    /// Build from an untyped SSE `agent_status.activity` object.
    init?(json: [String: Any]) {
        guard let raw = json["kind"] as? String else { return nil }
        // NSNumber.intValue is Int32 — it TRUNCATES ms-epoch values like
        // `since`/`busySince` (1.79e12 → garbage). int64Value is lossless and
        // fits Int on every 64-bit device (all iOS 15 hardware).
        func int(_ key: String) -> Int? {
            guard let n = json[key] as? NSNumber else { return nil }
            return Int(n.int64Value)
        }
        self.init(kind: Kind(rawValue: raw) ?? .waiting,
                  since: int("since"),
                  busySince: int("busySince"),
                  tool: json["tool"] as? String,
                  toolCount: int("toolCount"),
                  reason: json["reason"] as? String,
                  percent: int("percent"),
                  attempt: int("attempt"),
                  maxAttempts: int("maxAttempts"),
                  delayMs: int("delayMs"))
    }

    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int(d) }
        return nil
    }

    /// Status label (banner + session list).
    var label: String {
        switch kind {
        case .waiting:
            return "Working…"
        case .thinking:
            return "Thinking…"
        case .writing:
            return "Writing…"
        case .toolcall:
            return "Preparing \(tool ?? "tool")…"
        case .tool:
            var text = "Running \(tool ?? "tools")"
            if let count = toolCount, count > 1 { text += " +\(count - 1)" }
            return text
        case .compacting:
            if let percent { return "Compacting context… \(min(max(percent, 0), 100))%" }
            return "Compacting context…"
        case .retrying:
            if let attempt, let maxAttempts, maxAttempts > 0 { return "Retrying (\(attempt)/\(maxAttempts))…" }
            return "Retrying…"
        case .question:
            return "Waiting for your answer"
        }
    }

    /// SF Symbol (all available in SF Symbols 2, i.e. iOS 14+).
    var symbolName: String {
        switch kind {
        case .waiting: return "hourglass"
        case .thinking: return "brain.head.profile"
        case .writing: return "pencil"
        case .toolcall: return "hammer"
        case .tool: return "wrench.and.screwdriver"
        case .compacting: return "archivebox"
        case .retrying: return "arrow.triangle.2.circlepath"
        case .question: return "questionmark.circle"
        }
    }

    /// Identity of "what" is happening — the elapsed clock restarts only when
    /// this changes (the server's `since` has the same semantics).
    var phaseKey: String { kind.rawValue + "|" + (tool ?? "") }
}

/// Contract §9: the answered (or declined) `ask_user_question` result.
struct QAInfo: Codable, Equatable {
    struct Item: Codable, Equatable {
        let question: String
        let answer: String
    }

    let cancelled: Bool
    let items: [Item]

    init(cancelled: Bool, items: [Item]) {
        self.cancelled = cancelled
        self.items = items
    }

    /// Build from an untyped SSE/file_update `qa` object.
    init?(json: Any?) {
        guard let dict = json as? [String: Any] else { return nil }
        let rawItems = dict["items"] as? [[String: Any]] ?? []
        self.cancelled = dict["cancelled"] as? Bool ?? false
        self.items = rawItems.map {
            Item(question: $0["question"] as? String ?? "", answer: $0["answer"] as? String ?? "")
        }
    }

    /// Plain copy text (context menu Copy / Select Text).
    var transcriptText: String {
        if cancelled { return "Question declined" }
        if items.isEmpty { return "Question answered" }
        return items.map { item in
            let question = item.question.hasVisibleCharacters ? item.question : "Question"
            return "Q: \(question)\nA: \(item.answer)"
        }.joined(separator: "\n\n")
    }
}

/// Server-owned prompt queue item (durable outbox).
///
/// Contract v2: the server only returns `queued` / `running` items and each
/// carries its `clientMessageId`. Decoding is tolerant so the v1 server (and
/// any future additive change) never breaks the whole queue payload.
struct QueueItem: Decodable, Identifiable, Equatable {
    let id: String
    let clientMessageId: String?
    let message: String
    let status: String
    let queuedAt: Int?
    let startedAt: Int?
    let completedAt: Int?
    let error: String?

    init(id: String, clientMessageId: String?, message: String, status: String,
         queuedAt: Int?, startedAt: Int? = nil, completedAt: Int? = nil, error: String? = nil) {
        self.id = id
        self.clientMessageId = clientMessageId
        self.message = message
        self.status = status
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id, clientMessageId, message, text, status, queuedAt, startedAt, completedAt, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        clientMessageId = try? c.decodeIfPresent(String.self, forKey: .clientMessageId)
        message = (try? c.decodeIfPresent(String.self, forKey: .message))
            ?? (try? c.decodeIfPresent(String.self, forKey: .text))
            ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "queued"
        queuedAt = Self.flexibleInt(c, .queuedAt)
        startedAt = Self.flexibleInt(c, .startedAt)
        completedAt = Self.flexibleInt(c, .completedAt)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }

    /// Item still pending delivery (v1 servers also return done/failed rows).
    var isActive: Bool { status != "done" && status != "failed" && status != "cancelled" }

    /// Build from an untyped SSE `queue_update.items[]` element.
    init?(json d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        let message = (d["message"] as? String) ?? (d["text"] as? String)
        guard let message else { return nil }
        self.init(id: id,
                  clientMessageId: d["clientMessageId"] as? String,
                  message: message,
                  status: d["status"] as? String ?? "queued",
                  // ms epochs: int64Value is lossless (see AgentActivity.init(json:)).
                  queuedAt: (d["queuedAt"] as? NSNumber).map { Int($0.int64Value) },
                  startedAt: (d["startedAt"] as? NSNumber).map { Int($0.int64Value) },
                  completedAt: (d["completedAt"] as? NSNumber).map { Int($0.int64Value) },
                  error: d["error"] as? String)
    }
}

/// A structured question the agent is waiting on (`ask_user_question`).
/// Transport: the extension embeds the questionnaire in a select() title over
/// RPC; the server turns it into an `agent_question` SSE frame.
struct AgentQuestion: Equatable, Identifiable {
    struct Option: Equatable, Identifiable {
        let label: String
        let description: String
        let preview: String?
        var id: String { label }
    }

    struct Item: Equatable, Identifiable {
        let index: Int
        let header: String
        let question: String
        let multiSelect: Bool
        let options: [Option]
        var id: Int { index }

        /// Per-question selection state (labels for multi, single label for
        /// single-select, plus optional typed text).
        init?(json: [String: Any]) {
            guard let question = json["question"] as? String else { return nil }
            self.index = (json["index"] as? NSNumber)?.intValue ?? 0
            self.header = json["header"] as? String ?? ""
            self.question = question
            self.multiSelect = json["multiSelect"] as? Bool ?? false
            self.options = (json["options"] as? [[String: Any]] ?? []).compactMap { o in
                guard let label = o["label"] as? String else { return nil }
                return Option(label: label,
                              description: o["description"] as? String ?? "",
                              preview: (o["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    let requestId: String
    let items: [Item]

    init?(json: [String: Any]) {
        guard let requestId = json["requestId"] as? String,
              let raw = json["questions"] as? [[String: Any]] else { return nil }
        let items = raw.enumerated().compactMap { offset, element -> Item? in
            var copy = element
            if copy["index"] == nil { copy["index"] = offset }
            return Item(json: copy)
        }
        guard !items.isEmpty else { return nil }
        self.requestId = requestId
        self.items = items.sorted { $0.index < $1.index }
    }

    var id: String { requestId }

    /// Plain-text copy of the questionnaire (questions + option labels).
    var copyText: String {
        items.map { item in
            var lines = [item.question]
            for option in item.options {
                lines.append("• " + option.label + (option.description.isEmpty ? "" : " — " + option.description))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Cumulative provider usage from pi 0.85 `message_update.usage`.
struct SessionUsage: Equatable {
    let input: Int
    let output: Int
    let totalTokens: Int
    let cost: Double?

    init?(json: [String: Any]) {
        guard let input = (json["input"] as? NSNumber)?.intValue,
              let output = (json["output"] as? NSNumber)?.intValue else { return nil }
        self.input = input
        self.output = output
        self.totalTokens = (json["totalTokens"] as? NSNumber)?.intValue ?? input + output
        if let cost = json["cost"] as? [String: Any], let total = (cost["total"] as? NSNumber)?.doubleValue {
            self.cost = total
        } else {
            self.cost = nil
        }
    }
}

/// Session token/cost stats from pi 0.85 `get_session_stats`.
struct SessionStats: Equatable {
    let totalTokens: Int
    let cost: Double?
    let contextPercent: Double?

    init?(json: [String: Any]) {
        guard let tokens = json["tokens"] as? [String: Any],
              let total = tokens["total"] as? Int else { return nil }
        self.totalTokens = total
        if let c = json["cost"] as? Double { self.cost = c } else { self.cost = nil }
        if let ctx = json["contextUsage"] as? [String: Any],
           let pct = ctx["percent"] as? Double {
            self.contextPercent = pct
        } else {
            self.contextPercent = nil
        }
    }
}

/// GET /api/sessions/:id/messages — wire format (server/src/history.ts shape).
/// Every field except `role` decodes leniently so one odd row can never fail
/// the whole page.
struct WireMessage: Decodable {
    let id: String?
    let role: String
    let text: String?
    let thinking: String?
    let toolCalls: [WireToolCall]?
    let toolName: String?
    let isError: Bool?
    /// Server marks prune summaries (served as role "user") as system notes.
    let system: Bool?
    let model: String?
    let timestamp: Int?
    let errorMessage: String?
    /// Contract v2 §3: echo of the client idempotency key on user rows.
    let clientMessageId: String?
    /// Contract §9: Q&A payload on the `ask_user_question` result row.
    let qa: Lenient<QAInfo>?

    func toChatMessage() -> ChatMessage {
        let rawRole = self.role
        var role: MessageRole
        var isError = self.isError ?? false
        switch rawRole {
        case "user": role = .user
        case "assistant": role = .assistant
        case "tool", "toolResult": role = .tool
        case "error":
            // Contract v2 §4: role "error" rows are visible error rows.
            role = .assistant
            isError = true
        default: role = .assistant
        }
        if let toolName, !toolName.isEmpty { role = .tool }
        let body = text ?? ""
        if role == .tool {
            var message = ChatMessage(entryId: id, role: .tool, text: body, thinking: nil, toolCalls: [],
                                      isError: isError, toolName: toolName, isSystemNote: false,
                                      model: nil, errorMessage: nil, timestamp: timestamp)
            message.qa = qa?.value
            return message
        }
        return ChatMessage(
            entryId: id,
            clientMessageId: role == .user ? clientMessageId : nil,
            role: role,
            text: body,
            thinking: thinking,
            toolCalls: (toolCalls ?? []).map { ToolCall(id: $0.id, name: $0.name ?? "tool", argumentsText: $0.argumentsText) },
            isError: isError,
            toolName: toolName,
            isSystemNote: role == .user && (system == true || ChatMessage.isBgNotification(body)),
            model: model,
            errorMessage: errorMessage,
            timestamp: timestamp
        )
    }
}

struct WireToolCall: Decodable {
    let id: String?
    let name: String?
    let arguments: AnyJSON?

    var argumentsText: String {
        guard let arguments else { return "" }
        if let s = arguments.value as? String { return s }
        guard JSONSerialization.isValidJSONObject(arguments.value),
              let data = try? JSONSerialization.data(withJSONObject: arguments.value, options: [.sortedKeys]) else {
            return String(describing: arguments.value)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Erased JSON value so arbitrary tool arguments decode without Codable pain.
struct AnyJSON: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let d = try? c.decode([String: AnyJSON].self) { value = d.mapValues { $0.value } }
        else if let a = try? c.decode([AnyJSON].self) { value = a.map { $0.value } }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let n = try? c.decode(Double.self) { value = n }
        else if c.decodeNil() { value = NSNull() }
        else { value = "" }
    }
}

/// POST /api/sessions/:id/turn
struct TurnRequest: Encodable {
    let message: String
    let clientMessageId: String?
}

struct TurnResponse: Decodable {
    let accepted: Bool
    let queued: Bool
    let queueItemId: String?
    /// Server queue depth at accept time (backpressure signal).
    let queueDepth: Int?
    /// True when the prompt went to the agent immediately (idle session).
    let dispatched: Bool?
}

// MARK: - Chat display model

enum MessageRole: String, Codable {
    case user, assistant, tool
}

struct ChatMessage: Identifiable, Equatable, Codable {
    /// Stable row identity for the transcript. Assigned once when the row is
    /// first created (optimistic / streaming / server) and preserved through
    /// every later merge — only `entryId` gets attached when the canonical
    /// copy arrives.
    var id: String
    /// pi entry id — enables forking from this message.
    var entryId: String?
    /// Client idempotency key for optimistic/offline sends (contract v2 §3).
    var clientMessageId: String?
    var role: MessageRole
    var text: String
    var thinking: String?
    var toolCalls: [ToolCall]
    var isError: Bool
    var toolName: String?
    /// pi writes background-shell notifications / prune summaries as role
    /// "user" — they are system notes, never user bubbles.
    var isSystemNote: Bool
    var model: String?
    var errorMessage: String?
    var timestamp: Int?
    /// Contract §9: set on the `ask_user_question` result row — the one
    /// visible tool row (rendered as a compact Q&A card).
    var qa: QAInfo?

    init(id: String? = nil, entryId: String? = nil, clientMessageId: String? = nil,
         role: MessageRole, text: String, thinking: String?, toolCalls: [ToolCall],
         isError: Bool, toolName: String?,
         isSystemNote: Bool, model: String?, errorMessage: String?, timestamp: Int?,
         qa: QAInfo? = nil) {
        self.id = id ?? entryId.map { "entry:\($0)" } ?? "local:\(UUID().uuidString)"
        self.entryId = entryId
        self.clientMessageId = clientMessageId
        self.role = role
        self.text = Self.collapseBlankLines(text)
        self.thinking = thinking.map { Self.collapseBlankLines($0) }
        self.toolCalls = toolCalls
        self.isError = isError
        self.toolName = toolName
        self.isSystemNote = isSystemNote
        self.model = model
        self.errorMessage = errorMessage
        self.timestamp = timestamp
        self.qa = qa
    }

    enum CodingKeys: String, CodingKey {
        case id, entryId, clientMessageId, role, text, thinking, toolCalls
        case isError, toolName, isSystemNote, model
        case errorMessage, timestamp, qa
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decodeIfPresent(String.self, forKey: .id)
        let decodedEntry = try c.decodeIfPresent(String.self, forKey: .entryId)
        id = decodedId ?? decodedEntry.map { "entry:\($0)" } ?? "local:\(UUID().uuidString)"
        entryId = decodedEntry
        clientMessageId = try c.decodeIfPresent(String.self, forKey: .clientMessageId)
        role = try c.decode(MessageRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        isSystemNote = try c.decodeIfPresent(Bool.self, forKey: .isSystemNote) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp)
        qa = try? c.decodeIfPresent(QAInfo.self, forKey: .qa)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(entryId, forKey: .entryId)
        try c.encodeIfPresent(clientMessageId, forKey: .clientMessageId)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(isError, forKey: .isError)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encode(isSystemNote, forKey: .isSystemNote)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(qa, forKey: .qa)
    }

    /// Retain at most one consecutive blank line, trim leading/trailing
    /// blank lines and trailing spaces/tabs. Whitespace-only lines count as
    /// blank. Single linear scan — no regex (this runs for every message).
    static func collapseBlankLines(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var wroteAny = false
        var pendingBlank = false
        // "\r\n" is a single Character in Swift.
        let lines = s.split(omittingEmptySubsequences: false,
                            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        for line in lines {
            var end = line.endIndex
            while end > line.startIndex {
                let prev = line.index(before: end)
                let ch = line[prev]
                if ch == " " || ch == "\t" { end = prev } else { break }
            }
            let trimmed = line[line.startIndex..<end]
            let isBlank = trimmed.allSatisfy { $0.isWhitespace }
            if isBlank {
                if wroteAny { pendingBlank = true }
                continue
            }
            if wroteAny { out += pendingBlank ? "\n\n" : "\n" }
            out.append(contentsOf: trimmed)
            wroteAny = true
            pendingBlank = false
        }
        return out
    }

    /// Build a display message from a pi AgentMessage JSON blob (same mapping
    /// the server applies for history; kept in sync with server/src/history.ts).
    static func fromAgentMessage(_ json: [String: Any]) -> ChatMessage {
        let timestamp = (json["timestamp"] as? NSNumber)?.intValue
        // Server-mapped shape (history/file_update): flat text/toolCalls fields.
        if let text = json["text"] as? String {
            let rawRole = json["role"] as? String ?? "assistant"
            let toolName = (json["toolName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var isError = (json["isError"] as? Bool) ?? false
            let role: MessageRole
            if rawRole == "tool" || rawRole == "toolResult" || toolName != nil {
                role = .tool
            } else if rawRole == "error" {
                role = .assistant
                isError = true
            } else {
                role = MessageRole(rawValue: rawRole) ?? .assistant
            }
            let wireCalls = (json["toolCalls"] as? [[String: Any]]) ?? []
            return ChatMessage(
                entryId: json["id"] as? String,
                clientMessageId: role == .user ? json["clientMessageId"] as? String : nil,
                role: role,
                text: text,
                thinking: json["thinking"] as? String,
                toolCalls: wireCalls.map {
                    ToolCall(id: $0["id"] as? String, name: $0["name"] as? String ?? "tool",
                             argumentsText: prettyArguments($0["arguments"]))
                },
                isError: isError,
                toolName: toolName,
                isSystemNote: role == .user && ((json["system"] as? Bool) == true || isBgNotification(text)),
                model: json["model"] as? String,
                errorMessage: json["errorMessage"] as? String,
                timestamp: timestamp,
                qa: role == .tool ? QAInfo(json: json["qa"]) : nil
            )
        }
        var text = ""
        var thinking: String?
        var toolCalls: [ToolCall] = []

        if let raw = json["content"] {
            if let str = raw as? String {
                text = str
            } else if let blocks = raw as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String { text += t }
                    case "thinking":
                        if let t = block["thinking"] as? String { thinking = t }
                    case "toolCall":
                        toolCalls.append(ToolCall(
                            id: block["id"] as? String,
                            name: block["name"] as? String ?? "tool",
                            argumentsText: prettyArguments(block["arguments"])
                        ))
                    default:
                        break
                    }
                }
            }
        }

        // Tool output: pi marks it with a toolName (roles: toolResult/assistant/user).
        let toolName = (json["toolName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // pi serves extension custom messages (context-prune summaries) as
        // role "custom" with customType — system notes, never user bubbles.
        let rawRole = json["role"] as? String
        let isCustom = rawRole == "custom" || (json["customType"] as? String)?.isEmpty == false
        let hasToolResultBlock = (json["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "toolResult" } == true
        let isToolResult = toolName != nil || rawRole == "tool" || rawRole == "toolResult" || hasToolResultBlock
        var isError = (json["isError"] as? Bool) ?? false
        let role: MessageRole
        if isToolResult {
            role = .tool
        } else if isCustom {
            role = .user
        } else if rawRole == "error" {
            role = .assistant
            isError = true
        } else {
            role = MessageRole(rawValue: rawRole ?? "") ?? .assistant
        }

        let model: String?
        if let m = json["model"] as? String, !m.isEmpty {
            if let p = json["provider"] as? String, !p.isEmpty {
                model = "\(p)/\(m)"
            } else {
                model = m
            }
        } else {
            model = nil
        }

        return ChatMessage(
            entryId: json["id"] as? String,
            clientMessageId: role == .user ? json["clientMessageId"] as? String : nil,
            role: role,
            text: text,
            thinking: thinking,
            toolCalls: toolCalls,
            isError: isError,
            toolName: isCustom ? nil : toolName,
            isSystemNote: role == .user && (isCustom || (json["system"] as? Bool) == true || Self.isBgNotification(text)),
            model: model,
            errorMessage: json["errorMessage"] as? String,
            timestamp: timestamp,
            qa: role == .tool ? QAInfo(json: json["qa"]) : nil
        )
    }

    /// pi background-shell notifications look like "✗ [bg-abc123] failed …".
    static func isBgNotification(_ text: String) -> Bool {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.contains("[bg-")
    }

    private static func prettyArguments(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let dict = raw as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        if let s = raw as? String { return s }
        return String(describing: raw)
    }
}

struct OfflineMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String

    init(text: String, id: UUID = UUID()) {
        self.id = id
        self.text = text
    }

    /// The idempotency key this message is (re)sent with.
    var clientMessageId: String { id.uuidString }
}

struct ToolCall: Equatable, Codable {
    var id: String?
    var name: String
    var argumentsText: String
}
