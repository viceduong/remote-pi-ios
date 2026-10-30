import Foundation

// Contract §14: turn-end notifications via Bark.
//
// Wire shapes (decoded tolerantly — missing / malformed fields fall back to
// defaults, never fail the screen):
//   GET  /api/notify       → {enabled, barkServer, hasDeviceKey,
//                             encryption:{enabled, algorithm, mode, hasKey}, level}
//   PUT  /api/notify       ← partial {enabled?, barkServer?, deviceKey?,
//                             encryption?:{enabled?, algorithm?, mode?, key?, iv?}, level?}
//   POST /api/notify/test  → {ok, status, error?}
// Secrets (device key, key, iv) are write-only: the server only reports
// whether they are set.

/// Bark → Encryption → Algorithm.
enum BarkAlgorithm: String, CaseIterable, Identifiable, Equatable {
    case aes128 = "AES128"
    case aes192 = "AES192"
    case aes256 = "AES256"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aes128: return "AES-128"
        case .aes192: return "AES-192"
        case .aes256: return "AES-256"
        }
    }

    /// Required key length in characters (bytes, ASCII).
    var keyLength: Int {
        switch self {
        case .aes128: return 16
        case .aes192: return 24
        case .aes256: return 32
        }
    }

    /// Accepts "AES128", "aes-128", "AES_128", "128", "aes-128-cbc", …
    init?(wire: String) {
        let n = wire.uppercased().filter { $0.isLetter || $0.isNumber }
        if n.hasPrefix("AES128") || n == "128" {
            self = .aes128
        } else if n.hasPrefix("AES192") || n == "192" {
            self = .aes192
        } else if n.hasPrefix("AES256") || n == "256" {
            self = .aes256
        } else {
            return nil
        }
    }
}

/// Bark → Encryption → Mode.
enum BarkMode: String, CaseIterable, Identifiable, Equatable {
    case cbc = "CBC"
    case ecb = "ECB"
    case gcm = "GCM"

    var id: String { rawValue }
    var label: String { rawValue }

    /// Required IV length in characters; nil = the mode takes no IV.
    var ivLength: Int? {
        switch self {
        case .cbc: return 16
        case .ecb: return nil
        case .gcm: return 12
        }
    }

    /// Accepts "CBC", "cbc", "aes-128-cbc", …
    init?(wire: String) {
        let n = wire.uppercased().filter { $0.isLetter || $0.isNumber }
        if n == "CBC" || n.hasSuffix("CBC") {
            self = .cbc
        } else if n == "ECB" || n.hasSuffix("ECB") {
            self = .ecb
        } else if n == "GCM" || n.hasSuffix("GCM") {
            self = .gcm
        } else {
            return nil
        }
    }
}

/// Bark interruption level. The picker offers active / timeSensitive /
/// passive; `critical` (server-supported) is only shown when already set.
enum BarkLevel: String, CaseIterable, Identifiable, Equatable {
    case active
    case timeSensitive
    case passive
    case critical

    static let standard: [BarkLevel] = [.active, .timeSensitive, .passive]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "Active"
        case .timeSensitive: return "Time Sensitive"
        case .passive: return "Passive"
        case .critical: return "Critical"
        }
    }

    /// Case- and separator-insensitive ("time-sensitive", "TimeSensitive").
    init?(wire: String) {
        switch wire.lowercased().filter({ $0.isLetter }) {
        case "active": self = .active
        case "timesensitive": self = .timeSensitive
        case "passive": self = .passive
        case "critical": self = .critical
        default: return nil
        }
    }
}

/// `GET /api/notify`. Secrets are never part of it.
struct NotifySettings: Equatable {
    static let defaultBarkServer = "https://api.day.app"

    var enabled: Bool
    var barkServer: String
    var hasDeviceKey: Bool
    var encryption: Encryption
    var level: String
    /// Skip turn ends of pi-subagents child sessions (server default true).
    var skipSubagents: Bool

    struct Encryption: Equatable {
        var enabled: Bool
        var algorithm: String
        var mode: String
        var hasKey: Bool
        /// Not in §14 (optional extension); nil = unknown.
        var hasIv: Bool?

        init(enabled: Bool = false, algorithm: String = BarkAlgorithm.aes128.rawValue,
             mode: String = BarkMode.cbc.rawValue, hasKey: Bool = false, hasIv: Bool? = nil) {
            self.enabled = enabled
            self.algorithm = algorithm
            self.mode = mode
            self.hasKey = hasKey
            self.hasIv = hasIv
        }
    }

    init(enabled: Bool = false, barkServer: String = NotifySettings.defaultBarkServer,
         hasDeviceKey: Bool = false, encryption: Encryption = Encryption(),
         level: String = BarkLevel.active.rawValue, skipSubagents: Bool = true) {
        self.enabled = enabled
        self.barkServer = barkServer
        self.hasDeviceKey = hasDeviceKey
        self.encryption = encryption
        self.level = level
        self.skipSubagents = skipSubagents
    }

    var algorithm: BarkAlgorithm? { BarkAlgorithm(wire: encryption.algorithm) }
    var mode: BarkMode? { BarkMode(wire: encryption.mode) }
    var parsedLevel: BarkLevel? { BarkLevel(wire: level) }
}

extension NotifySettings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case enabled, barkServer, hasDeviceKey, encryption, level, skipSubagents
        // Tolerated wrappers: `{notify:{…}}` / `{settings:{…}}`.
        case notify, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let looksFlat = c.contains(.enabled) || c.contains(.barkServer)
            || c.contains(.encryption) || c.contains(.hasDeviceKey)
        if !looksFlat {
            if let inner = try? c.decode(NotifySettings.self, forKey: .notify) {
                self = inner
                return
            }
            if let inner = try? c.decode(NotifySettings.self, forKey: .settings) {
                self = inner
                return
            }
        }
        enabled = c.lossyBool(.enabled) ?? false
        let server = c.lossyString(.barkServer)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        barkServer = server.isEmpty ? Self.defaultBarkServer : server
        hasDeviceKey = c.lossyBool(.hasDeviceKey) ?? false
        encryption = (try? c.decodeIfPresent(Encryption.self, forKey: .encryption)) ?? Encryption()
        level = c.lossyString(.level) ?? BarkLevel.active.rawValue
        skipSubagents = c.lossyBool(.skipSubagents) ?? true
    }
}

extension NotifySettings.Encryption: Decodable {
    private enum CodingKeys: String, CodingKey {
        case enabled, algorithm, mode, hasKey, hasIv
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hasKey = c.lossyBool(.hasKey) ?? false
        self.hasKey = hasKey
        // §14: encryption defaults ON when a key is configured.
        enabled = c.lossyBool(.enabled) ?? hasKey
        algorithm = c.lossyString(.algorithm) ?? BarkAlgorithm.aes128.rawValue
        mode = c.lossyString(.mode) ?? BarkMode.cbc.rawValue
        hasIv = c.lossyBool(.hasIv)
    }
}

/// `PUT /api/notify` body. nil fields are omitted (partial update).
struct NotifySettingsPatch: Encodable, Equatable {
    var enabled: Bool?
    var barkServer: String?
    var deviceKey: String?
    var encryption: EncryptionPatch?
    var level: String?
    var skipSubagents: Bool?

    struct EncryptionPatch: Encodable, Equatable {
        var enabled: Bool?
        var algorithm: String?
        var mode: String?
        var key: String?
        var iv: String?

        var isEmpty: Bool {
            enabled == nil && algorithm == nil && mode == nil && key == nil && iv == nil
        }
    }

    var isEmpty: Bool {
        enabled == nil && barkServer == nil && deviceKey == nil
            && (encryption?.isEmpty ?? true) && level == nil && skipSubagents == nil
    }
}

/// `POST /api/notify/test` → `{ok, status, error?}`.
struct NotifyTestResult: Equatable {
    let ok: Bool
    /// Bark's HTTP status (or a server-side status word).
    let status: String?
    let error: String?

    init(ok: Bool, status: String? = nil, error: String? = nil) {
        self.ok = ok
        self.status = status
        self.error = error
    }

    /// User-facing failure text.
    var failureMessage: String {
        var text = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { text = "Bark didn't accept the notification" }
        if let status, !status.isEmpty, status != "0", !text.contains(status) {
            text += " (status \(status))"
        }
        return text
    }
}

extension NotifyTestResult: Decodable {
    private enum CodingKeys: String, CodingKey { case ok, status, error }
    private enum MessageKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `ok` is the discriminator: without it this isn't a test result
        // (e.g. an old server's 404 body) and the caller falls back.
        guard let ok = c.lossyBool(.ok) else {
            throw DecodingError.keyNotFound(CodingKeys.ok, .init(codingPath: c.codingPath,
                                                                debugDescription: "missing ok"))
        }
        self.ok = ok
        if let code = try? c.decodeIfPresent(Int.self, forKey: .status) {
            status = String(code)
        } else {
            status = c.lossyString(.status)
        }
        if let message = c.lossyString(.error) {
            error = message
        } else if let nested = try? c.nestedContainer(keyedBy: MessageKeys.self, forKey: .error) {
            error = nested.lossyString(.message)
        } else {
            error = nil
        }
    }
}

/// §14 endpoints (APIClient in the app, a stub in tests).
protocol NotifyService {
    func notifySettings() async throws -> NotifySettings
    func updateNotifySettings(_ patch: NotifySettingsPatch) async throws
    func sendTestNotification() async throws -> NotifyTestResult
}

// MARK: - Validation

enum BarkValidation {
    /// Bark device key from either the bare key or a pasted Bark URL
    /// (`https://api.day.app/<key>/…`).
    static func deviceKey(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           url.host != nil {
            return url.pathComponents.first(where: { $0 != "/" }) ?? ""
        }
        var key = trimmed
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    private static let deviceKeyAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// nil = valid. `key` is the extracted key.
    static func deviceKeyError(_ key: String) -> String? {
        if key.isEmpty { return "Enter the device key from the Bark app" }
        if key.unicodeScalars.contains(where: { !deviceKeyAllowed.contains($0) }) {
            return "The device key should only contain letters and digits"
        }
        return nil
    }

    /// Normalized Bark server URL (`https://` assumed, no trailing slash);
    /// nil when it isn't a usable http(s) URL.
    static func normalizedServer(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            guard !s.contains("://") else { return nil }
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.contains(where: { $0.isWhitespace }),
              let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return s
    }

    /// Printable ASCII only — Bark uses the raw characters as key bytes.
    private static func isPrintableASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// nil = valid. For a non-empty entered key.
    static func keyError(_ key: String, algorithm: BarkAlgorithm) -> String? {
        guard isPrintableASCII(key) else { return "Use plain ASCII characters for the key" }
        let count = key.utf8.count
        guard count == algorithm.keyLength else {
            return "\(algorithm.label) needs a \(algorithm.keyLength)-character key (entered \(count))"
        }
        return nil
    }

    /// nil = valid. For a non-empty entered IV; modes without an IV never fail.
    static func ivError(_ iv: String, mode: BarkMode) -> String? {
        guard let length = mode.ivLength else { return nil }
        guard isPrintableASCII(iv) else { return "Use plain ASCII characters for the IV" }
        let count = iv.utf8.count
        guard count == length else {
            return "\(mode.label) needs a \(length)-character IV (entered \(count))"
        }
        return nil
    }
}

/// Field-level problems in a `NotifyDraft`; all nil = savable.
struct NotifyIssues: Equatable {
    var server: String?
    var deviceKey: String?
    var key: String?
    var iv: String?

    var isEmpty: Bool { server == nil && deviceKey == nil && key == nil && iv == nil }
}

/// Editable form state for the Notifications screen. Secret fields start
/// empty (write-only) — empty means "keep what the server has".
struct NotifyDraft: Equatable {
    var enabled = false
    var barkServer = NotifySettings.defaultBarkServer
    var deviceKey = ""
    var encryptionEnabled = false
    var algorithm: BarkAlgorithm = .aes128
    var mode: BarkMode = .cbc
    var key = ""
    var iv = ""
    var level: BarkLevel = .active
    var skipSubagents = true

    init() {}

    init(settings: NotifySettings) {
        enabled = settings.enabled
        barkServer = settings.barkServer
        encryptionEnabled = settings.encryption.enabled
        algorithm = settings.algorithm ?? .aes128
        mode = settings.mode ?? .cbc
        level = settings.parsedLevel ?? .active
        skipSubagents = settings.skipSubagents
    }

    /// Problems that block saving. Notes on the server (§14 impl): it
    /// rejects a stored key whose length doesn't fit the algorithm, and it
    /// never needs the IV (every push carries a fresh random one), so the IV
    /// is optional and only length-checked when entered.
    func issues(against saved: NotifySettings) -> NotifyIssues {
        var issues = NotifyIssues()
        if BarkValidation.normalizedServer(barkServer) == nil {
            issues.server = "Enter a valid http(s) URL, e.g. \(NotifySettings.defaultBarkServer)"
        }

        if !deviceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.deviceKey = BarkValidation.deviceKeyError(BarkValidation.deviceKey(from: deviceKey))
        } else if enabled && !saved.hasDeviceKey {
            issues.deviceKey = "Enter the device key from the Bark app"
        }

        if !key.isEmpty {
            issues.key = BarkValidation.keyError(key, algorithm: algorithm)
        } else if saved.encryption.hasKey && saved.algorithm != algorithm {
            issues.key = "Re-enter the key — \(algorithm.label) uses \(algorithm.keyLength) characters"
        } else if encryptionEnabled && !saved.encryption.hasKey {
            issues.key = "Enter a \(algorithm.keyLength)-character key"
        }

        if !iv.isEmpty, mode.ivLength != nil {
            issues.iv = BarkValidation.ivError(iv, mode: mode)
        }
        return issues
    }

    /// The partial update that turns `saved` into this draft.
    func patch(against saved: NotifySettings) -> NotifySettingsPatch {
        var patch = NotifySettingsPatch()
        let enteredDeviceKey = BarkValidation.deviceKey(from: deviceKey)
        if enabled != saved.enabled {
            patch.enabled = enabled
        } else if !enabled && !saved.hasDeviceKey && !enteredDeviceKey.isEmpty {
            // The server turns notifications on with the first device key
            // unless told otherwise — honour the switch the user sees.
            patch.enabled = false
        }
        if let server = BarkValidation.normalizedServer(barkServer), server != saved.barkServer {
            patch.barkServer = server
        }
        if !enteredDeviceKey.isEmpty { patch.deviceKey = enteredDeviceKey }

        var enc = NotifySettingsPatch.EncryptionPatch()
        if encryptionEnabled != saved.encryption.enabled { enc.enabled = encryptionEnabled }
        if saved.algorithm != algorithm { enc.algorithm = algorithm.rawValue }
        if saved.mode != mode { enc.mode = mode.rawValue }
        if !key.isEmpty { enc.key = key }
        if mode.ivLength != nil, !iv.isEmpty {
            enc.iv = iv
        } else if saved.mode != mode {
            // A stored IV of the old mode's length would make the server
            // reject the new mode; it never needs one, so clear it.
            enc.iv = ""
        }
        if !enc.isEmpty { patch.encryption = enc }

        if saved.parsedLevel != level { patch.level = level.rawValue }
        if saved.skipSubagents != skipSubagents { patch.skipSubagents = skipSubagents }
        return patch
    }
}

// MARK: - Lossy decoding helpers

extension KeyedDecodingContainer {
    /// Bool from true/false, 0/1 or "true"/"false"; nil when absent/garbage.
    func lossyBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    /// String; nil when absent, null or not a string.
    func lossyString(_ key: Key) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return value
    }
}
