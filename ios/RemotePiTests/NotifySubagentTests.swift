import XCTest
@testable import RemotePi

final class NotifySubagentTests: XCTestCase {
    func testSkipSubagentsDecodesWithDefaultOn() throws {
        let withField = try JSONDecoder().decode(NotifySettings.self, from: Data(#"{"enabled":true,"skipSubagents":false}"#.utf8))
        XCTAssertFalse(withField.skipSubagents)
        let older = try JSONDecoder().decode(NotifySettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(older.skipSubagents, "servers without the field default to skipping subagents")
    }

    func testToggleProducesPatchOnlyWhenChanged() throws {
        let saved = NotifySettings(enabled: true, hasDeviceKey: true, skipSubagents: true)
        var draft = NotifyDraft(settings: saved)
        XCTAssertNil(draft.patch(against: saved).skipSubagents)
        draft.skipSubagents = false
        let patch = draft.patch(against: saved)
        XCTAssertEqual(patch.skipSubagents, false)
        let json = String(data: try JSONEncoder().encode(patch), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"skipSubagents\":false"))
    }
}
