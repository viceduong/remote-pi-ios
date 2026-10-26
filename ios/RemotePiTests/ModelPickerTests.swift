import XCTest
@testable import RemotePi

/// Contract §11 (model picker): wire decoding (incl. older / malformed
/// shapes), summary-string parsing, `model_changed` handling and the pure
/// grouping / search / label helpers behind the picker sheet.
@MainActor
final class ModelPickerTests: XCTestCase {

    private func listing(_ json: String) throws -> ModelListing {
        try JSONDecoder().decode(ModelListing.self, from: Data(json.utf8))
    }

    private func entry(_ provider: String, _ id: String, _ name: String? = nil,
                       ctx: Int? = nil, reasoning: Bool = false) -> ModelEntry {
        ModelEntry(provider: provider, id: id, name: name, contextWindow: ctx, reasoning: reasoning)
    }

    // MARK: - GET /models decoding

    func testDecodesContractShape() throws {
        let decoded = try listing(#"""
        {"models":[
          {"provider":"anthropic","id":"claude-opus-4-1","name":"Claude Opus 4.1","contextWindow":200000,"reasoning":true},
          {"provider":"zai","id":"glm-5.3-flash","name":"GLM 5.3 Flash","contextWindow":131072}
        ],"current":{"provider":"zai","id":"glm-5.3-flash"}}
        """#)
        XCTAssertEqual(decoded.models.count, 2)
        XCTAssertEqual(decoded.models[0].provider, "anthropic")
        XCTAssertEqual(decoded.models[0].name, "Claude Opus 4.1")
        XCTAssertEqual(decoded.models[0].contextWindow, 200_000)
        XCTAssertTrue(decoded.models[0].reasoning)
        XCTAssertFalse(decoded.models[1].reasoning, "absent reasoning reads as false")
        XCTAssertEqual(decoded.current, ModelRef(provider: "zai", id: "glm-5.3-flash"))
        XCTAssertEqual(decoded.models[1].key, "zai/glm-5.3-flash")
    }

    func testDecodesNullCurrentAndEmptyList() throws {
        let decoded = try listing(#"{"models":[],"current":null}"#)
        XCTAssertTrue(decoded.models.isEmpty)
        XCTAssertNil(decoded.current)
    }

    func testDecodesLegacyNestedRPCShape() throws {
        // v1 server: `{models: <RPC get_available_models data>}` with raw pi
        // Model objects (extra keys, float context window, no `current`).
        let decoded = try listing(#"""
        {"models":{"models":[
          {"provider":"openai","id":"gpt-5","name":"GPT-5","api":"openai-responses","contextWindow":400000.0,
           "reasoning":true,"cost":{"input":1.25,"output":10}}
        ]}}
        """#)
        XCTAssertEqual(decoded.models.map(\.key), ["openai/gpt-5"])
        XCTAssertEqual(decoded.models.first?.contextWindow, 400_000)
        XCTAssertTrue(decoded.models.first?.reasoning ?? false)
        XCTAssertNil(decoded.current)
    }

    func testMalformedEntriesAreSkippedNotFatal() throws {
        let decoded = try listing(#"""
        {"models":[
          {"provider":"x"},
          null,
          42,
          {"id":"   "},
          {"modelId":"legacy-id","provider":"p2"},
          {"id":"bare"},
          {"provider":"p","id":"m","name":null,"contextWindow":"big","reasoning":"yes"},
          {"provider":"p","id":"m","name":"duplicate"},
          {"provider":"p","id":"neg","contextWindow":-5}
        ],"current":"p/m"}
        """#)
        XCTAssertEqual(decoded.models.map(\.key), ["p2/legacy-id", "/bare", "p/m", "p/neg"])
        let m = decoded.models[2]
        XCTAssertEqual(m.name, "m", "missing/null name falls back to the id")
        XCTAssertNil(m.contextWindow, "non-numeric context window dropped")
        XCTAssertFalse(m.reasoning, "non-boolean reasoning dropped")
        XCTAssertNil(decoded.models[3].contextWindow, "non-positive context window dropped")
        XCTAssertEqual(decoded.current, ModelRef(provider: "p", id: "m"), "string `current` accepted")
    }

    func testGarbageModelsFieldYieldsEmptyListing() throws {
        XCTAssertTrue(try listing(#"{"models":"nope","current":{"oops":1}}"#).models.isEmpty)
        XCTAssertNil(try listing(#"{"models":"nope","current":{"oops":1}}"#).current)
        XCTAssertTrue(try listing("{}").models.isEmpty)
    }

    // MARK: - POST /models response

    func testSetModelResponseShapes() throws {
        let full = try APIClient.decodeSetModelResponse(
            Data(#"{"ok":true,"model":{"provider":"anthropic","id":"claude-sonnet-4-5","name":"Claude Sonnet 4.5"}}"#.utf8))
        XCTAssertEqual(full, ModelRef(provider: "anthropic", id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"))
        XCTAssertNil(try APIClient.decodeSetModelResponse(Data(#"{"ok":true}"#.utf8)), "legacy server")
        XCTAssertNil(try APIClient.decodeSetModelResponse(Data()), "empty body is still success")
        XCTAssertNil(try APIClient.decodeSetModelResponse(Data(#"{"ok":true,"model":"weird"}"#.utf8)))
        XCTAssertThrowsError(try APIClient.decodeSetModelResponse(Data(#"{"ok":false}"#.utf8)))
    }

    // MARK: - Summary string

    func testSummaryStringParsing() {
        XCTAssertEqual(ModelRef(summary: "anthropic/claude-opus-4-1"),
                       ModelRef(provider: "anthropic", id: "claude-opus-4-1"))
        XCTAssertEqual(ModelRef(summary: "openrouter/anthropic/claude-3.5-sonnet"),
                       ModelRef(provider: "openrouter", id: "anthropic/claude-3.5-sonnet"),
                       "only the first slash separates the provider")
        XCTAssertEqual(ModelRef(summary: "gpt-5"), ModelRef(provider: "", id: "gpt-5"))
        XCTAssertNil(ModelRef(summary: nil))
        XCTAssertNil(ModelRef(summary: "  "))
        XCTAssertNil(ModelRef(summary: "zai/"))
        XCTAssertNil(ModelRef(summary: "/"))
    }

    func testMatchingIgnoresNameAndEmptyProvider() {
        let e = entry("zai", "glm-5.3-flash", "GLM 5.3 Flash")
        XCTAssertTrue(ModelRef(provider: "zai", id: "glm-5.3-flash", name: "Other").matches(e))
        XCTAssertTrue(ModelRef(provider: "", id: "glm-5.3-flash").matches(e))
        XCTAssertFalse(ModelRef(provider: "openrouter", id: "glm-5.3-flash").matches(e))
        XCTAssertFalse(ModelRef(provider: "zai", id: "glm-5").matches(e))
    }

    // MARK: - ViewModel: seed + model_changed

    private func makeViewModel(model: String?) -> ChatViewModel {
        ChatViewModel(client: APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t"),
                      sessionId: "model-tests", initialModel: model)
    }

    private func frame(_ json: String) -> ParsedSSEFrame {
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ParsedSSEFrame(event: "model_changed", id: nil, payload: payload)
    }

    func testCurrentModelSeededFromSummaryAndNamedFromListing() {
        let vm = makeViewModel(model: "zai/glm-5.3-flash")
        XCTAssertEqual(vm.currentModel?.id, "glm-5.3-flash")
        XCTAssertNil(vm.currentModel?.name)
        XCTAssertEqual(ModelPicker.displayName(current: vm.currentModel, models: vm.availableModels),
                       "glm-5.3-flash", "raw id until the listing is known")
        vm.seedModelsForTesting(ModelListing(models: [entry("zai", "glm-5.3-flash", "GLM 5.3 Flash")],
                                             current: ModelRef(provider: "zai", id: "glm-5.3-flash")))
        XCTAssertEqual(vm.currentModel?.name, "GLM 5.3 Flash")
        XCTAssertNil(makeViewModel(model: nil).currentModel)
    }

    func testModelChangedFrameUpdatesCurrentModel() {
        let vm = makeViewModel(model: "zai/glm-5.3-flash")
        vm.ingestForTesting([frame(#"{"type":"model_changed","provider":"anthropic","id":"claude-opus-4-1","name":"Claude Opus 4.1"}"#)])
        XCTAssertEqual(vm.currentModel, ModelRef(provider: "anthropic", id: "claude-opus-4-1", name: "Claude Opus 4.1"))

        // Name missing → filled from the listing.
        vm.seedModelsForTesting(ModelListing(models: [entry("openai", "gpt-5", "GPT-5")], current: nil))
        vm.ingestForTesting([frame(#"{"type":"model_changed","model":{"provider":"openai","id":"gpt-5"}}"#)])
        XCTAssertEqual(vm.currentModel?.key, "openai/gpt-5")
        XCTAssertEqual(vm.currentModel?.name, "GPT-5")

        // Malformed frame: ignored, never crashes or clears the model.
        vm.ingestForTesting([frame(#"{"type":"model_changed","provider":"x"}"#)])
        XCTAssertEqual(vm.currentModel?.id, "gpt-5")
    }

    // MARK: - Grouping / search

    private var catalog: [ModelEntry] {
        [
            entry("zai", "glm-5.3-flash", "GLM 5.3 Flash", ctx: 131_072),
            entry("anthropic", "claude-sonnet-4-5", "Claude Sonnet 4.5", ctx: 200_000, reasoning: true),
            entry("openai", "gpt-5", "GPT-5", ctx: 400_000, reasoning: true),
            entry("anthropic", "claude-opus-4-1", "Claude Opus 4.1", ctx: 200_000, reasoning: true),
            entry("openai", "gpt-5-mini", "GPT-5 mini", ctx: 400_000),
            entry("Anthropic-Vertex", "claude-opus-4-1@vertex", "Claude Opus 4.1 (Vertex)"),
        ]
    }

    func testGroupsByProviderSortedWithModelsByName() {
        let groups = ModelPicker.groups(catalog, query: "")
        XCTAssertEqual(groups.map(\.provider), ["anthropic", "Anthropic-Vertex", "openai", "zai"])
        XCTAssertEqual(groups[0].models.map(\.id), ["claude-opus-4-1", "claude-sonnet-4-5"])
        XCTAssertEqual(groups[2].models.map(\.id), ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.models.count }, catalog.count)
    }

    func testSearchMatchesAllTermsAcrossProviderIdAndName() {
        XCTAssertEqual(ModelPicker.filter(catalog, query: "opus").map(\.id),
                       ["claude-opus-4-1", "claude-opus-4-1@vertex"])
        XCTAssertEqual(ModelPicker.groups(catalog, query: "OPENAI mini").flatMap(\.models).map(\.id), ["gpt-5-mini"])
        XCTAssertEqual(ModelPicker.groups(catalog, query: "opus vertex").map(\.provider), ["Anthropic-Vertex"])
        XCTAssertEqual(ModelPicker.filter(catalog, query: "glm-5.3").map(\.id), ["glm-5.3-flash"])
        XCTAssertEqual(ModelPicker.filter(catalog, query: "   ").count, catalog.count, "blank query = everything")
        XCTAssertTrue(ModelPicker.groups(catalog, query: "llama").isEmpty)
        XCTAssertEqual(ModelPicker.filter([entry("p", "m", "Modèle")], query: "modele").count, 1,
                       "diacritic-insensitive")
    }

    func testContextLabels() {
        XCTAssertEqual(ModelPicker.contextLabel(200_000), "200K ctx")
        XCTAssertEqual(ModelPicker.contextLabel(128_000), "128K ctx")
        XCTAssertEqual(ModelPicker.contextLabel(131_072), "128K ctx")
        XCTAssertEqual(ModelPicker.contextLabel(32_768), "32K ctx")
        XCTAssertEqual(ModelPicker.contextLabel(400_000), "400K ctx")
        XCTAssertEqual(ModelPicker.contextLabel(1_000_000), "1M ctx")
        XCTAssertEqual(ModelPicker.contextLabel(1_048_576), "1M ctx")
        XCTAssertEqual(ModelPicker.contextLabel(1_500_000), "1.5M ctx")
        XCTAssertEqual(ModelPicker.contextLabel(512), "512 ctx")
        XCTAssertNil(ModelPicker.contextLabel(nil))
        XCTAssertNil(ModelPicker.contextLabel(0))
    }

    func testProviderTitleFallback() {
        XCTAssertEqual(ModelPicker.providerTitle(""), "Other")
        XCTAssertEqual(ModelPicker.providerTitle("zai"), "zai")
    }
}

private extension ModelRef {
    var key: String { provider + "/" + id }
}
