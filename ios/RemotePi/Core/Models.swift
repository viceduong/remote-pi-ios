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
}

/// GET /api/sessions/:id/messages — wire format (server/src/history.ts shape).
struct WireMessage: Decodable {
    let id: String?
    let role: String
    let text: String
    let thinking: String?
    let toolCalls: [WireToolCall]
    let toolName: String?
    let isError: Bool?
    /// Server marks prune summaries (served as role "user") as system notes.
    let system: Bool?
    let model: String?
    let timestamp: Int?
    let errorMessage: String?

    func toChatMessage() -> ChatMessage {
        var role = MessageRole(rawValue: self.role) ?? .assistant
        // pi sends tool results with role "toolResult" (+ toolName) — normalize.
        if role == .assistant && toolName != nil { role = .tool }
        if role == .tool {
        return ChatMessage(
            entryId: id,
            role: .tool,
            text: text,
            thinking: nil,
            toolCalls: [],
            toolActivity: nil,
            isError: isError ?? false,
            toolName: toolName,
            isSystemNote: false,
            model: nil,
            errorMessage: errorMessage,
            timestamp: timestamp
        )
    }
    return ChatMessage(
        entryId: id,
        role: role,
        text: text,
        thinking: thinking,
        toolCalls: toolCalls.map { ToolCall(id: $0.id, name: $0.name, argumentsText: $0.argumentsText) },
        toolActivity: nil,
        isError: isError ?? false,
        toolName: toolName,
        isSystemNote: role == .user && (system == true || ChatMessage.isBgNotification(text)),
        model: model,
        errorMessage: errorMessage,
        timestamp: timestamp
    )
}
}

struct WireToolCall: Decodable {
    let id: String?
    let name: String
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
}

struct TurnResponse: Decodable {
    let accepted: Bool
    let queued: Bool
}

// MARK: - Chat display model

enum MessageRole: String, Codable {
    case user, assistant, tool
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    /// pi entry id ("m…") — enables forking from this message.
    var entryId: String?
    var role: MessageRole
    var text: String
    var thinking: String?
    var toolCalls: [ToolCall]
    var toolActivity: ToolActivity?
    var isError: Bool
    var toolName: String?
    /// pi writes background-shell notifications as role "user" (model context) —
    /// render them as system notes instead of user bubbles.
    var isSystemNote: Bool
    var model: String?
    var errorMessage: String?
    var timestamp: Int?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Build a display message from a pi AgentMessage JSON blob (same mapping
    /// the server applies for history; kept in sync with server/src/history.ts).
    static func fromAgentMessage(_ json: [String: Any]) -> ChatMessage {
        // Server-mapped shape (history/file_update): flat text/toolCalls fields.
        if let text = json["text"] as? String {
            let rawRole = json["role"] as? String ?? "assistant"
            let role = MessageRole(rawValue: rawRole) ?? .assistant
            let toolName = json["toolName"] as? String
            let wireCalls = (json["toolCalls"] as? [[String: Any]]) ?? []
            return ChatMessage(
                entryId: json["id"] as? String,
                role: role,
                text: text,
                thinking: json["thinking"] as? String,
                toolCalls: wireCalls.map {
                    ToolCall(id: $0["id"] as? String, name: $0["name"] as? String ?? "tool",
                             argumentsText: prettyArguments($0["arguments"]))
                },
                toolActivity: nil,
                isError: (json["isError"] as? Bool) ?? false,
                toolName: toolName,
                isSystemNote: role == .user && ((json["system"] as? Bool) == true || isBgNotification(text)),
                model: json["model"] as? String,
                errorMessage: json["errorMessage"] as? String,
                timestamp: json["timestamp"] as? Int
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
        var toolName = json["toolName"] as? String
        // Legacy: content made only of toolCall/toolResult blocks.
        let toolOnlyContent: Bool = {
            guard let blocks = json["content"] as? [[String: Any]], !blocks.isEmpty else { return false }
            let toolTypes: Set<String> = ["toolCall", "toolResult", "image"]
            return blocks.allSatisfy { toolTypes.contains($0["type"] as? String ?? "") }
        }()
        // pi serves extension custom messages (context-prune summaries) as
        // role "custom" with customType — system notes, never user bubbles.
        let rawRole = json["role"] as? String
        let isCustom = rawRole == "custom" || (json["customType"] as? String)?.isEmpty == false
        let isToolResult = toolName?.isEmpty == false || toolOnlyContent
        let role: MessageRole
        if isToolResult || rawRole == "tool" || rawRole == "toolResult" {
            role = .tool
        } else if isCustom {
            toolName = nil
            role = .user
        } else {
            role = MessageRole(rawValue: rawRole ?? "") ?? .assistant
        }

        let model: String?
        if let m = json["model"] as? String, !m.isEmpty {
            model = m
        } else if let p = json["provider"] as? String, let m = json["model"] as? String {
            model = "\(p)/\(m)"
        } else {
            model = nil
        }

        return ChatMessage(
            entryId: json["id"] as? String,
            role: role,
            text: text,
            thinking: thinking,
            toolCalls: toolCalls,
            toolActivity: nil,
            isError: (json["isError"] as? Bool) ?? false,
            toolName: json["toolName"] as? String,
            isSystemNote: role == .user && (isCustom || (json["system"] as? Bool) == true || Self.isBgNotification(text)),
            model: model,
            errorMessage: json["errorMessage"] as? String,
            timestamp: json["timestamp"] as? Int
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
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        if let s = raw as? String { return s }
        return String(describing: raw)
    }
}

struct ToolCall: Equatable {
    var id: String?
    var name: String
    var argumentsText: String
}

enum ToolStatus: Equatable {
    case running
    case done(isError: Bool)
}

struct ToolActivity: Equatable {
    var toolName: String
    var argsSummary: String
    var resultPreview: String?
    var status: ToolStatus
}

// MARK: - Codable AgentMessage (pi RPC wire format)

/// pi message content is either a plain string (user) or a block array (assistant).
struct AgentMessage: Decodable {
    let role: String
    let content: MessageContent?
    let timestamp: Int?
    let model: String?
    let provider: String?
    let errorMessage: String?
    let toolName: String?
    let isError: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        if let str = try? c.decode(String.self, forKey: .content) {
            content = .text(str)
        } else if let blocks = try? c.decode([ContentBlock].self, forKey: .content) {
            content = .blocks(blocks)
        } else {
            content = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, timestamp, model, provider, errorMessage, toolName, isError
    }
}

enum MessageContent {
    case text(String)
    case blocks([ContentBlock])
}

struct ContentBlock: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let id: String?
    let name: String?
    let arguments: JSONValue?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        arguments = try c.decodeIfPresent(JSONValue.self, forKey: .arguments)
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, arguments
    }
}

/// JSON blob that can hold arbitrary tool arguments.
enum JSONValue: Decodable {
    case object([String: JSONValue])
    case string(String)

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            // Arguments arrived as a JSON string — try to unpack it.
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self = .object(obj.mapValues { JSONValue.fromAny($0) })
            } else {
                self = .string(s)
            }
        } else {
            let c = try decoder.singleValueContainer()
            let dict = try c.decode([String: JSONValue].self)
            self = .object(dict)
        }
    }

    static func fromAny(_ value: Any) -> JSONValue {
        if let dict = value as? [String: Any] {
            return .object(dict.mapValues { fromAny($0) })
        }
        if let str = value as? String { return .string(str) }
        return .string(String(describing: value))
    }

    /// Compact single-line summary used in tool chips.
    var summary: String {
        switch self {
        case .string(let s):
            return s.count > 60 ? String(s.prefix(60)) + "…" : s
        case .object(let dict):
            let parts = dict.map { "\($0.key): \($0.value.summary)" }
            return parts.joined(separator: ", ")
        }
    }
}
