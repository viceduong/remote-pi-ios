import Foundation

// MARK: - Contract v2 §11 model picker wire shapes

/// `{provider, id}` (+ display name when known) — the session's current model.
struct ModelRef: Equatable, Hashable {
    var provider: String
    var id: String
    /// Human name (`ModelEntry.name` / `model_changed.name`); nil when only
    /// the summary string is known.
    var name: String?

    init(provider: String, id: String, name: String? = nil) {
        self.provider = provider
        self.id = id
        self.name = name.flatMap { $0.hasVisibleCharacters ? $0 : nil }
    }

    /// Session summary `model` string (`provider/id`, unchanged since v1).
    /// Model ids may themselves contain "/" (e.g. OpenRouter
    /// `anthropic/claude-x`), so only the FIRST slash separates the provider.
    init?(summary: String?) {
        guard let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let slash = raw.firstIndex(of: "/"), slash != raw.startIndex {
            let rest = raw[raw.index(after: slash)...]
            guard !rest.isEmpty else { return nil }
            self.init(provider: String(raw[..<slash]), id: String(rest))
        } else {
            self.init(provider: "", id: raw.hasPrefix("/") ? String(raw.dropFirst()) : raw)
            if id.isEmpty { return nil }
        }
    }

    /// Untyped `{provider, id|modelId, name?}` (SSE `model_changed`, POST
    /// response `model`); nil without an id.
    init?(json: [String: Any]?) {
        guard let json else { return nil }
        let id = (json["id"] as? String) ?? (json["modelId"] as? String) ?? ""
        guard id.hasVisibleCharacters else { return nil }
        self.init(provider: (json["provider"] as? String) ?? "", id: id, name: json["name"] as? String)
    }

    /// Same model (provider + id); the display name is ignored. An empty
    /// provider (legacy string without one) matches by id only.
    func sameModel(as other: ModelRef) -> Bool {
        guard id == other.id else { return false }
        return provider.isEmpty || other.provider.isEmpty || provider == other.provider
    }

    func matches(_ entry: ModelEntry) -> Bool {
        sameModel(as: entry.ref)
    }

    var displayName: String { name ?? id }
}

/// One available model (`ModelEntry` in §11). Decoding is tolerant: only a
/// non-empty `id` is required (`modelId` accepted), `name` falls back to the
/// id, numeric/boolean extras that are malformed are dropped.
struct ModelEntry: Decodable, Hashable {
    let provider: String
    let id: String
    let name: String
    let contextWindow: Int?
    let reasoning: Bool

    init(provider: String, id: String, name: String? = nil, contextWindow: Int? = nil, reasoning: Bool = false) {
        self.provider = provider
        self.id = id
        self.name = name.flatMap { $0.hasVisibleCharacters ? $0 : nil } ?? id
        self.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }
        self.reasoning = reasoning
    }

    private enum CodingKeys: String, CodingKey {
        case provider, id, modelId, name, contextWindow, reasoning
    }

    private struct MissingId: Error {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decodeIfPresent(String.self, forKey: .id))
            ?? (try? c.decodeIfPresent(String.self, forKey: .modelId))
            ?? ""
        guard id.hasVisibleCharacters else { throw MissingId() }
        var window: Int?
        if let v = try? c.decodeIfPresent(Int.self, forKey: .contextWindow) {
            window = v
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .contextWindow), d.isFinite,
                  d > 0, d < Double(Int32.max) {
            window = Int(d.rounded())
        }
        self.init(provider: (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "",
                  id: id,
                  name: try? c.decodeIfPresent(String.self, forKey: .name),
                  contextWindow: window,
                  reasoning: (try? c.decodeIfPresent(Bool.self, forKey: .reasoning)) ?? false)
    }

    /// Stable row identity (`id` alone is not unique across providers).
    var key: String { provider + "/" + id }
    var ref: ModelRef { ModelRef(provider: provider, id: id, name: name) }
}

/// `GET /api/sessions/:id/models` → `{models, current}`.
///
/// Tolerant of older servers: `models` may be the v1 RPC passthrough
/// `{models: {models: [...]}}`, `current` may be absent, malformed entries
/// are skipped instead of failing the whole listing, duplicates (provider +
/// id) are dropped.
struct ModelListing: Decodable, Equatable {
    var models: [ModelEntry]
    var current: ModelRef?

    init(models: [ModelEntry], current: ModelRef?) {
        self.models = models
        self.current = current
    }

    private enum CodingKeys: String, CodingKey { case models, current }

    private struct Nested: Decodable {
        let models: [Lenient<ModelEntry>]?
        let current: Lenient<CurrentJSON>?
    }

    private struct CurrentJSON: Decodable {
        let provider: String?
        let id: String?
        let modelId: String?
        let name: String?

        var ref: ModelRef? {
            guard let id = id ?? modelId, id.hasVisibleCharacters else { return nil }
            return ModelRef(provider: provider ?? "", id: id, name: name)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var raw: [Lenient<ModelEntry>] = []
        var nestedCurrent: ModelRef?
        if let list = try? c.decodeIfPresent([Lenient<ModelEntry>].self, forKey: .models) {
            raw = list
        } else if let nested = try? c.decodeIfPresent(Nested.self, forKey: .models) {
            raw = nested.models ?? []
            nestedCurrent = nested.current?.value?.ref
        }
        var seen = Set<String>()
        models = raw.compactMap(\.value).filter { seen.insert($0.key).inserted }
        var top: ModelRef?
        if let lenient = try? c.decodeIfPresent(Lenient<CurrentJSON>.self, forKey: .current) {
            top = lenient.value?.ref
        }
        if top == nil, let string = try? c.decodeIfPresent(String.self, forKey: .current) {
            top = ModelRef(summary: string)
        }
        current = top ?? nestedCurrent
    }
}

// MARK: - Picker logic (pure, unit-tested)

enum ModelPicker {
    struct Group: Equatable {
        let provider: String
        let models: [ModelEntry]
    }

    /// Display title for a provider section.
    static func providerTitle(_ provider: String) -> String {
        provider.isEmpty ? "Other" : provider
    }

    /// Case/diacritic-insensitive multi-term filter over provider, id and
    /// name: every whitespace-separated term must match somewhere.
    static func filter(_ models: [ModelEntry], query: String) -> [ModelEntry] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return models }
        return models.filter { entry in
            let haystack = "\(entry.provider) \(entry.id) \(entry.name)"
            return terms.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Filtered models grouped per provider. Providers in case-insensitive
    /// order, models by name then id (stable even if a server doesn't sort).
    static func groups(_ models: [ModelEntry], query: String) -> [Group] {
        let filtered = filter(models, query: query)
        var byProvider: [String: [ModelEntry]] = [:]
        for entry in filtered { byProvider[entry.provider, default: []].append(entry) }
        let providers = byProvider.keys.sorted { lhs, rhs in
            let l = lhs.lowercased(), r = rhs.lowercased()
            return l != r ? l < r : lhs < rhs
        }
        return providers.map { provider in
            let sorted = (byProvider[provider] ?? []).sorted { a, b in
                let an = a.name.lowercased(), bn = b.name.lowercased()
                if an != bn { return an < bn }
                return a.id < b.id
            }
            return Group(provider: provider, models: sorted)
        }
    }

    /// "200K ctx", "128K ctx" (128000 or 131072), "1M ctx" (1000000 or
    /// 1048576), "1.5M ctx". Round decimal values use decimal units; exact
    /// binary multiples (131072, 1048576) use binary units; anything else
    /// is decimal.
    static func contextLabel(_ tokens: Int?) -> String? {
        guard let n = tokens, n > 0 else { return nil }
        if n >= 1_000_000 {
            let binary = n % 1_000_000 != 0 && n % 1_048_576 == 0
            let value = binary ? Double(n / 1_048_576) : Double(n) / 1_000_000
            return "\(compact(value))M ctx"
        }
        if n >= 1_000 {
            let binary = n % 1_000 != 0 && n % 1_024 == 0
            let value = binary ? Double(n / 1_024) : Double(n) / 1_000
            return "\(compact(value))K ctx"
        }
        return "\(n) ctx"
    }

    private static func compact(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// Name to show for the current model: the listing's entry name when the
    /// listing is known, else the name we were told, else the raw id.
    static func displayName(current: ModelRef?, models: [ModelEntry]) -> String? {
        guard let current else { return nil }
        if current.name == nil, let entry = models.first(where: current.matches) { return entry.name }
        return current.displayName
    }
}
