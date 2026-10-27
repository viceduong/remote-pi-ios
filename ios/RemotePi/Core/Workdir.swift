import Foundation

// MARK: - Contract v2 §12 session working directory: wire shapes

/// One subfolder in a `GET /api/dirs?path=` listing.
struct DirEntry: Hashable, Identifiable {
    let name: String
    let path: String

    /// Windows paths are case-insensitive.
    var id: String { path.lowercased() }
}

/// One `recent` item of `GET /api/dirs` (no path): a distinct session cwd.
struct RecentDir: Hashable, Identifiable {
    let path: String
    /// ms epoch of the newest session in that folder (nil when unknown).
    let lastUsedAt: Double?
    /// Number of sessions in that folder (nil when unknown).
    let sessions: Int?

    var id: String { path.lowercased() }
    var name: String { WorkdirPath.lastComponent(path) }
}

/// A string-or-object path item. Accepts `"D:\\x"`, `{path}`, `{dir}`,
/// `{name, path}`, `{path, lastUsedAt, sessions}`; anything malformed
/// decodes to an empty item that callers drop.
private struct RawPathItem: Decodable {
    var name: String?
    var path: String?
    var lastUsedAt: Double?
    var sessions: Int?

    private enum K: String, CodingKey {
        case name, path, dir, lastUsedAt, sessions
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            path = text
            return
        }
        guard let c = try? decoder.container(keyedBy: K.self) else { return }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        path = (try? c.decodeIfPresent(String.self, forKey: .path))
            ?? (try? c.decodeIfPresent(String.self, forKey: .dir))
        if let ms = try? c.decodeIfPresent(Double.self, forKey: .lastUsedAt) {
            lastUsedAt = ms
        }
        if let count = try? c.decodeIfPresent(Int.self, forKey: .sessions) {
            sessions = count
        } else if let count = try? c.decodeIfPresent(Double.self, forKey: .sessions), count.isFinite {
            sessions = Int(count)
        }
    }
}

/// Decodes a list of path items leniently (bad items dropped, a non-array
/// value → empty).
private func decodePathItems<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [RawPathItem] {
    let raw = (try? c.decodeIfPresent([Lenient<RawPathItem>].self, forKey: key)) ?? nil
    return (raw ?? []).compactMap { $0.value }
}

private func nonBlank(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

/// `GET /api/dirs?path=<abs>` → `{path, exists, isDir, allowed, parent,
/// entries:[{name,path}], truncated}`. Decoding is tolerant: every key is
/// optional, malformed entries are dropped, entries may be bare strings and
/// an entry without `path` gets one from the listing path + its name.
struct DirListing: Decodable, Equatable {
    var path: String
    var exists: Bool
    var isDir: Bool
    var allowed: Bool
    /// nil at a root.
    var parent: String?
    var entries: [DirEntry]
    var truncated: Bool

    init(path: String, exists: Bool = true, isDir: Bool = true, allowed: Bool = true,
         parent: String? = nil, entries: [DirEntry] = [], truncated: Bool = false) {
        self.path = path
        self.exists = exists
        self.isDir = isDir
        self.allowed = allowed
        self.parent = parent
        self.entries = entries
        self.truncated = truncated
    }

    private enum K: String, CodingKey {
        case path, exists, isDir, allowed, parent, entries, truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let listingPath = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        path = listingPath
        let rawExists = try? c.decodeIfPresent(Bool.self, forKey: .exists)
        let rawIsDir = try? c.decodeIfPresent(Bool.self, forKey: .isDir)
        exists = rawExists ?? rawIsDir ?? true
        isDir = rawIsDir ?? exists
        allowed = (try? c.decodeIfPresent(Bool.self, forKey: .allowed)) ?? true
        if c.contains(.parent) {
            // Explicit null = at a root.
            parent = nonBlank(try? c.decodeIfPresent(String.self, forKey: .parent))
        } else {
            parent = listingPath.isEmpty ? nil : WorkdirPath.parent(listingPath)
        }
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        var seen = Set<String>()
        entries = decodePathItems(c, .entries).compactMap { item -> DirEntry? in
            let name = nonBlank(item.name)
            var full = nonBlank(item.path)
            if full == nil, let name, !listingPath.isEmpty {
                full = WorkdirPath.appending(name, to: listingPath)
            }
            guard let full else { return nil }
            // A bare-string entry is a name when the listing has a path and
            // the string isn't itself absolute.
            if item.name == nil, !WorkdirPath.isAbsolute(full), !listingPath.isEmpty {
                let joined = WorkdirPath.appending(full, to: listingPath)
                guard seen.insert(joined.lowercased()).inserted else { return nil }
                return DirEntry(name: full, path: joined)
            }
            guard seen.insert(full.lowercased()).inserted else { return nil }
            return DirEntry(name: name ?? WorkdirPath.lastComponent(full), path: full)
        }
    }
}

/// `GET /api/dirs` (no path) → `{roots:[…], recent:[{path,lastUsedAt,sessions}],
/// default}`. Roots/recent accept strings or objects; recent is deduped
/// case-insensitively (server order kept, most recent first).
struct DirRoots: Decodable, Equatable {
    var roots: [String]
    var recent: [RecentDir]
    /// The server's default workdir (`default`).
    var defaultDir: String?

    init(roots: [String], recent: [RecentDir] = [], defaultDir: String? = nil) {
        self.roots = roots
        self.recent = recent
        self.defaultDir = defaultDir
    }

    private enum K: String, CodingKey {
        case roots, recent
        case defaultDir = "default"
        case defaultWorkdir
        case workdir
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        var seenRoots = Set<String>()
        roots = decodePathItems(c, .roots).compactMap { nonBlank($0.path) }
            .filter { seenRoots.insert($0.lowercased()).inserted }
        var seen = Set<String>()
        recent = decodePathItems(c, .recent).compactMap { item -> RecentDir? in
            guard let path = nonBlank(item.path), seen.insert(path.lowercased()).inserted else { return nil }
            return RecentDir(path: path, lastUsedAt: item.lastUsedAt, sessions: item.sessions)
        }
        defaultDir = nonBlank(try? c.decodeIfPresent(String.self, forKey: .defaultDir))
            ?? nonBlank(try? c.decodeIfPresent(String.self, forKey: .defaultWorkdir))
            ?? nonBlank(try? c.decodeIfPresent(String.self, forKey: .workdir))
    }

    /// A §12 server always has at least one root; anything else (an older
    /// server's catch-all JSON) means the folder UI must stay hidden.
    var isUsable: Bool { !roots.isEmpty }
}

/// A §12 rejection (`403 workdir_forbidden {roots}`, `404 workdir_missing`,
/// `400 workdir_not_dir` / invalid path) from `POST /api/sessions` or
/// `GET /api/dirs`. Other HTTP failures stay `APIError`.
struct WorkdirRejection: LocalizedError, Equatable {
    let status: Int
    let code: String?
    let message: String
    let roots: [String]

    static let forbidden = "workdir_forbidden"
    static let missing = "workdir_missing"
    static let notDir = "workdir_not_dir"

    var errorDescription: String? {
        switch code ?? "" {
        case Self.forbidden: return WorkdirStatus.notAllowed(roots: roots).text
        case Self.missing: return "Folder doesn't exist"
        case Self.notDir: return WorkdirStatus.notADirectory.text
        default: return message
        }
    }

    /// Builds a rejection from an error response, or nil when it isn't a
    /// workdir error (then the caller throws the generic `APIError`).
    /// `dirsEndpoint`: any 400/403 from `/api/dirs` is a path rejection.
    static func parse(status: Int, data: Data, dirsEndpoint: Bool) -> WorkdirRejection? {
        guard (400...499).contains(status), status != 401 else { return nil }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = body?["code"] as? String
        let isWorkdirCode = code?.hasPrefix("workdir_") == true
        guard isWorkdirCode || (dirsEndpoint && (status == 400 || status == 403)) else { return nil }
        let nested = (body?["error"] as? [String: Any])?["message"] as? String
        let message = (body?["error"] as? String) ?? nested ?? (body?["message"] as? String)
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let roots: [String] = ((body?["roots"] as? [Any]) ?? []).compactMap { item in
            if let text = item as? String { return nonBlank(text) }
            return nonBlank((item as? [String: Any])?["path"] as? String)
        }
        return WorkdirRejection(status: status, code: code, message: message, roots: roots)
    }
}

// MARK: - Windows path helpers (pure, unit-tested)

/// Light client-side handling of absolute Windows paths (`X:\…`). The
/// server is authoritative (realpath, junctions, reserved names, …).
enum WorkdirPath {
    static let maxLength = 260
    private static let invalidPathCharacters = CharacterSet(charactersIn: "<>\"|?*")
    private static let invalidNameCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")
    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 { names.insert("COM\(n)"); names.insert("LPT\(n)") }
        return names
    }()

    private static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Trims, turns `/` into `\`, collapses repeated separators (but keeps a
    /// leading `\\` so UNC input stays recognisable — and rejected), upper-cases
    /// the drive letter, `D:` → `D:\`, and drops a trailing separator except
    /// at a drive root.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "\\")
        guard !s.isEmpty else { return s }
        let unc = s.hasPrefix("\\\\")
        while s.contains("\\\\") { s = s.replacingOccurrences(of: "\\\\", with: "\\") }
        if unc { s = "\\" + s }
        let chars = Array(s)
        if chars.count >= 2, chars[1] == ":", chars[0].isASCII, chars[0].isLetter {
            s = chars[0].uppercased() + String(chars.dropFirst())
            if s.count == 2 { s += "\\" }
        }
        while s.count > 3, s.hasSuffix("\\") { s.removeLast() }
        return s
    }

    /// `X:\…` (after normalisation).
    static func isAbsolute(_ raw: String) -> Bool {
        let chars = Array(normalize(raw))
        return chars.count >= 3 && chars[0].isASCII && chars[0].isLetter && chars[1] == ":" && chars[2] == "\\"
    }

    /// A drive root like `D:\`.
    static func isDriveRoot(_ raw: String) -> Bool {
        let s = normalize(raw)
        return s.count == 3 && isAbsolute(s)
    }

    /// Why a typed path can't be right, or nil when it looks fine (or is
    /// empty — empty means "server default").
    static func validationError(_ raw: String) -> String? {
        let s = normalize(raw)
        if s.isEmpty { return nil }
        if hasControlCharacters(s) { return "Path contains invalid characters" }
        guard isAbsolute(s) else { return "Use a full path like D:\\projects\\app" }
        let rest = String(s.dropFirst(2))
        if rest.unicodeScalars.contains(where: { invalidPathCharacters.contains($0) || $0 == ":" }) {
            return "Path contains invalid characters"
        }
        let segments = rest.split(separator: "\\").map(String.init)
        if segments.contains(where: { $0 == "." || $0 == ".." }) { return "“..” and “.” aren't allowed" }
        if s.count > maxLength { return "Path is too long (max \(maxLength) characters)" }
        return nil
    }

    /// `D:\a\b` → `D:\a`, `D:\a` → `D:\`, `D:\` → nil.
    static func parent(_ raw: String) -> String? {
        let s = normalize(raw)
        guard !s.isEmpty, !isDriveRoot(s), let idx = s.lastIndex(of: "\\") else { return nil }
        let head = String(s[..<idx])
        if head.count == 2, head.hasSuffix(":") { return head + "\\" }
        return head.isEmpty ? nil : head
    }

    /// `D:\a` + `b` → `D:\a\b`; `D:\` + `b` → `D:\b`.
    static func appending(_ name: String, to base: String) -> String {
        let leaf = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        let b = normalize(base)
        guard !leaf.isEmpty else { return b }
        guard !b.isEmpty else { return leaf }
        return b.hasSuffix("\\") ? b + leaf : b + "\\" + leaf
    }

    /// `D:\a\b` → `b`; a drive root stays `D:\`.
    static func lastComponent(_ raw: String) -> String {
        let s = normalize(raw)
        if isDriveRoot(s) { return s }
        guard let idx = s.lastIndex(of: "\\") else { return s }
        let leaf = String(s[s.index(after: idx)...])
        return leaf.isEmpty ? s : leaf
    }

    /// Case-insensitive path equality after normalisation.
    static func same(_ a: String, _ b: String) -> Bool {
        normalize(a).lowercased() == normalize(b).lowercased()
    }

    /// `path` equals `root` or is inside it (case-insensitive, Windows).
    /// `D:\` contains `d:\x`; `D:\work` does not contain `D:\workshop`.
    static func isInside(_ path: String, root: String) -> Bool {
        let p = normalize(path).lowercased()
        let r = normalize(root).lowercased()
        guard !p.isEmpty, !r.isEmpty else { return false }
        if p == r { return true }
        let prefix = r.hasSuffix("\\") ? r : r + "\\"
        return p.hasPrefix(prefix)
    }

    static func isInsideAny(_ path: String, roots: [String]) -> Bool {
        roots.contains { isInside(path, root: $0) }
    }

    /// Why a new folder name is unusable, or nil when it's fine.
    static func folderNameError(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a folder name" }
        if name == "." || name == ".." { return "“\(name)” isn't a folder name" }
        if hasControlCharacters(name) || name.unicodeScalars.contains(where: { invalidNameCharacters.contains($0) }) {
            return "Names can't contain < > : \" / \\ | ? *"
        }
        if name.hasSuffix(".") || name.hasSuffix(" ") { return "Names can't end with a dot or space" }
        let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        if reservedNames.contains(stem.uppercased()) { return "“\(name)” is reserved by Windows" }
        if name.count > 255 { return "Name is too long" }
        return nil
    }
}

// MARK: - Folder status (pure mapping, unit-tested)

/// The live status line under the folder field.
enum WorkdirStatus: Equatable {
    /// Field empty → the server's default workdir.
    case serverDefault(String?)
    /// Client-side validation failed.
    case invalid(String)
    case checking
    case existing
    case willCreate
    case notAllowed(roots: [String])
    case notADirectory
    /// Couldn't check (network/server error) — Create still allowed; the
    /// server decides.
    case unknown(String)

    var text: String {
        switch self {
        case .serverDefault(let dir):
            if let dir { return "Server default (\(dir))" }
            return "Server default folder"
        case .invalid(let message): return message
        case .checking: return "Checking…"
        case .existing: return "Existing folder"
        case .willCreate: return "Will be created"
        case .notAllowed(let roots):
            guard !roots.isEmpty else { return "Not allowed — outside the server's folders" }
            return "Not allowed — must be inside \(roots.joined(separator: " or "))"
        case .notADirectory: return "Not a folder"
        case .unknown(let message): return message
        }
    }

    var systemImage: String {
        switch self {
        case .serverDefault: return "house"
        case .invalid, .notAllowed: return "xmark.octagon.fill"
        case .checking: return "ellipsis.circle"
        case .existing: return "checkmark.circle.fill"
        case .willCreate: return "plus.circle.fill"
        case .notADirectory: return "doc.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Whether Create may be tapped with this status.
    var allowsCreate: Bool {
        switch self {
        case .invalid, .notAllowed, .notADirectory: return false
        default: return true
        }
    }

    /// Client-side verdict before asking the server: invalid syntax or
    /// outside every known root (case-insensitive); nil = ask the server.
    static func preflight(_ path: String, roots: [String]) -> WorkdirStatus? {
        if let error = WorkdirPath.validationError(path) { return .invalid(error) }
        if !roots.isEmpty, !WorkdirPath.isInsideAny(path, roots: roots) { return .notAllowed(roots: roots) }
        return nil
    }

    static func from(listing: DirListing, roots: [String]) -> WorkdirStatus {
        if !listing.allowed { return .notAllowed(roots: roots) }
        if listing.exists { return listing.isDir ? .existing : .notADirectory }
        return .willCreate
    }

    /// Status for a failed `GET /api/dirs?path=` probe.
    static func from(error: Error, roots: [String]) -> WorkdirStatus {
        if let rejection = error as? WorkdirRejection {
            switch rejection.code ?? "" {
            case WorkdirRejection.forbidden:
                return .notAllowed(roots: rejection.roots.isEmpty ? roots : rejection.roots)
            case WorkdirRejection.notDir: return .notADirectory
            case WorkdirRejection.missing: return .willCreate
            default:
                if rejection.status == 403 {
                    return .notAllowed(roots: rejection.roots.isEmpty ? roots : rejection.roots)
                }
                if rejection.status == 404 { return .willCreate }
                return .invalid(rejection.message)
            }
        }
        if case APIError.http(let code, _, _) = error {
            if code == 404 { return .willCreate }
            if code == 403 { return .notAllowed(roots: roots) }
        }
        return .unknown("Couldn't check the folder — the server will decide")
    }

    /// Inline feedback for a failed `POST /api/sessions`: an updated field
    /// status (when the failure is about the folder) + the error line.
    static func createFailure(_ error: Error, roots: [String]) -> (status: WorkdirStatus?, message: String) {
        if let rejection = error as? WorkdirRejection {
            switch rejection.code ?? "" {
            case WorkdirRejection.forbidden:
                let status = WorkdirStatus.notAllowed(roots: rejection.roots.isEmpty ? roots : rejection.roots)
                return (status, status.text)
            case WorkdirRejection.missing:
                return (nil, "Folder doesn't exist and couldn't be created")
            case WorkdirRejection.notDir:
                return (.notADirectory, "That path is a file, not a folder")
            default:
                if rejection.status == 403 {
                    let status = WorkdirStatus.notAllowed(roots: rejection.roots.isEmpty ? roots : rejection.roots)
                    return (status, status.text)
                }
                return (rejection.status == 400 ? WorkdirStatus.invalid(rejection.message) : nil, rejection.message)
            }
        }
        return (nil, error.localizedDescription)
    }
}

// MARK: - Persistence + service seam

/// Last-used folder, remembered per server profile.
struct WorkdirMemory {
    let serverKey: String
    let defaults: UserDefaults

    init(serverKey: String, defaults: UserDefaults = .standard) {
        self.serverKey = serverKey
        self.defaults = defaults
    }

    private var key: String { "remotePi.lastWorkdir.\(serverKey)" }

    var lastUsed: String? {
        nonBlank(defaults.string(forKey: key))
    }

    func remember(_ path: String) {
        let normalized = WorkdirPath.normalize(path)
        guard !normalized.isEmpty else { return }
        defaults.set(normalized, forKey: key)
    }
}

/// The endpoints the new-session sheet needs (APIClient in the app, a stub
/// in tests — no network).
protocol WorkdirService {
    func dirRoots() async throws -> DirRoots
    func listDirs(path: String) async throws -> DirListing
    func createSession(name: String, workdir: String?, createDir: Bool,
                       clientRequestId: String?) async throws -> SessionSummary
}
