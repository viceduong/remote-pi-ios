import XCTest
@testable import RemotePi

/// In-memory §14 endpoints (no network) for model + snapshot tests.
final class StubNotifyService: NotifyService {
    var settings: NotifySettings
    var getError: Error?
    var putError: Error?
    var testResult: Result<NotifyTestResult, Error> = .success(NotifyTestResult(ok: true, status: "200"))
    private(set) var patches: [NotifySettingsPatch] = []
    private(set) var getCalls = 0
    private(set) var testCalls = 0

    init(settings: NotifySettings = NotifySettings()) {
        self.settings = settings
    }

    func notifySettings() async throws -> NotifySettings {
        getCalls += 1
        if let getError { throw getError }
        return settings
    }

    func updateNotifySettings(_ patch: NotifySettingsPatch) async throws {
        if let putError { throw putError }
        patches.append(patch)
        // Mimic the server merge (secrets → has* flags only).
        if let enabled = patch.enabled { settings.enabled = enabled }
        if let server = patch.barkServer { settings.barkServer = server }
        if let key = patch.deviceKey { settings.hasDeviceKey = !key.isEmpty }
        if let enc = patch.encryption {
            if let enabled = enc.enabled { settings.encryption.enabled = enabled }
            if let algorithm = enc.algorithm { settings.encryption.algorithm = algorithm }
            if let mode = enc.mode { settings.encryption.mode = mode }
            if let key = enc.key { settings.encryption.hasKey = !key.isEmpty }
        }
        if let level = patch.level { settings.level = level }
    }

    func sendTestNotification() async throws -> NotifyTestResult {
        testCalls += 1
        return try testResult.get()
    }
}

final class NotifyDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> NotifySettings {
        try JSONDecoder().decode(NotifySettings.self, from: Data(json.utf8))
    }

    func testDecodesContractShape() throws {
        let s = try decode("""
        {"enabled":true,"barkServer":"https://bark.example.com","hasDeviceKey":true,
         "encryption":{"enabled":true,"algorithm":"AES256","mode":"GCM","hasKey":true},
         "level":"timeSensitive"}
        """)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.barkServer, "https://bark.example.com")
        XCTAssertTrue(s.hasDeviceKey)
        XCTAssertTrue(s.encryption.enabled)
        XCTAssertTrue(s.encryption.hasKey)
        XCTAssertEqual(s.algorithm, .aes256)
        XCTAssertEqual(s.mode, .gcm)
        XCTAssertEqual(s.parsedLevel, .timeSensitive)
        XCTAssertNil(s.encryption.hasIv)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let s = try decode("{}")
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.barkServer, "https://api.day.app")
        XCTAssertFalse(s.hasDeviceKey)
        XCTAssertFalse(s.encryption.enabled)
        XCTAssertEqual(s.algorithm, .aes128)
        XCTAssertEqual(s.mode, .cbc)
        XCTAssertEqual(s.parsedLevel, .active)
    }

    func testToleratesMalformedAndLooseValues() throws {
        let s = try decode("""
        {"enabled":1,"barkServer":"","hasDeviceKey":"true","encryption":"garbage","level":42,"extra":[1,2]}
        """)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.barkServer, "https://api.day.app")
        XCTAssertTrue(s.hasDeviceKey)
        XCTAssertEqual(s.encryption, NotifySettings.Encryption())
        XCTAssertEqual(s.level, "active")
    }

    func testEncryptionDefaultsOnWhenKeyConfigured() throws {
        let s = try decode(#"{"encryption":{"hasKey":true,"algorithm":"aes-192","mode":"ecb"}}"#)
        XCTAssertTrue(s.encryption.enabled, "§14: encryption defaults ON when a key is configured")
        XCTAssertEqual(s.algorithm, .aes192)
        XCTAssertEqual(s.mode, .ecb)
    }

    func testWrappedShape() throws {
        let s = try decode(#"{"notify":{"enabled":true,"hasDeviceKey":true,"level":"passive"}}"#)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.parsedLevel, .passive)
    }

    func testCriticalLevelAndUnknownValues() throws {
        XCTAssertEqual(try decode(#"{"level":"critical"}"#).parsedLevel, .critical)
        let odd = try decode(#"{"level":"loud","encryption":{"algorithm":"DES","mode":"CTR"}}"#)
        XCTAssertNil(odd.parsedLevel)
        XCTAssertNil(odd.algorithm)
        XCTAssertNil(odd.mode)
    }

    func testWireValueParsing() {
        XCTAssertEqual(BarkAlgorithm(wire: "AES128"), .aes128)
        XCTAssertEqual(BarkAlgorithm(wire: "aes_256"), .aes256)
        XCTAssertEqual(BarkAlgorithm(wire: "aes-192-cbc"), .aes192)
        XCTAssertNil(BarkAlgorithm(wire: "AES512"))
        XCTAssertEqual(BarkMode(wire: "gcm"), .gcm)
        XCTAssertEqual(BarkMode(wire: "aes-128-cbc"), .cbc)
        XCTAssertNil(BarkMode(wire: "CTR"))
        XCTAssertEqual(BarkLevel(wire: "time-sensitive"), .timeSensitive)
        XCTAssertEqual(BarkLevel(wire: "TimeSensitive"), .timeSensitive)
    }

    func testDecodesTestResult() throws {
        let ok = try JSONDecoder().decode(NotifyTestResult.self, from: Data(#"{"ok":true,"status":200}"#.utf8))
        XCTAssertEqual(ok, NotifyTestResult(ok: true, status: "200"))

        let failed = try JSONDecoder().decode(NotifyTestResult.self, from: Data(
            #"{"ok":false,"status":400,"error":"failed to get device token"}"#.utf8))
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.failureMessage, "failed to get device token (status 400)")

        let unconfigured = try JSONDecoder().decode(NotifyTestResult.self, from: Data(
            #"{"ok":false,"status":0,"error":"no device key"}"#.utf8))
        XCTAssertEqual(unconfigured.failureMessage, "no device key", "status 0 = not sent; don't show it")

        let nested = try JSONDecoder().decode(NotifyTestResult.self, from: Data(
            #"{"ok":false,"status":"timeout","error":{"message":"Bark unreachable"}}"#.utf8))
        XCTAssertEqual(nested.error, "Bark unreachable")
        XCTAssertEqual(nested.status, "timeout")
    }

    func testTestResultWithoutOkIsNotAResult() {
        // An old server's 404 body must not be mistaken for a result.
        XCTAssertThrowsError(try JSONDecoder().decode(NotifyTestResult.self, from: Data(
            #"{"message":"Route POST:/api/notify/test not found","error":"Not Found","statusCode":404}"#.utf8)))
    }

    func testPatchOmitsNilFields() throws {
        let patch = NotifySettingsPatch(enabled: true, encryption: .init(key: "k"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["enabled", "encryption"])
        let enc = try XCTUnwrap(json["encryption"] as? [String: Any])
        XCTAssertEqual(Set(enc.keys), ["key"])
        XCTAssertTrue(NotifySettingsPatch().isEmpty)
        XCTAssertTrue(NotifySettingsPatch(encryption: .init()).isEmpty)
    }
}

final class BarkValidationTests: XCTestCase {
    func testKeyLengthPerAlgorithm() {
        XCTAssertNil(BarkValidation.keyError(String(repeating: "a", count: 16), algorithm: .aes128))
        XCTAssertNil(BarkValidation.keyError(String(repeating: "b", count: 24), algorithm: .aes192))
        XCTAssertNil(BarkValidation.keyError(String(repeating: "c", count: 32), algorithm: .aes256))
        XCTAssertEqual(BarkValidation.keyError("short", algorithm: .aes128),
                       "AES-128 needs a 16-character key (entered 5)")
        XCTAssertNotNil(BarkValidation.keyError(String(repeating: "a", count: 16), algorithm: .aes256))
        XCTAssertNotNil(BarkValidation.keyError(String(repeating: "é", count: 16), algorithm: .aes128),
                        "non-ASCII keys are refused (Bark uses raw bytes)")
    }

    func testIvLengthPerMode() {
        XCTAssertEqual(BarkMode.cbc.ivLength, 16)
        XCTAssertEqual(BarkMode.gcm.ivLength, 12)
        XCTAssertNil(BarkMode.ecb.ivLength)
        XCTAssertNil(BarkValidation.ivError("1111111111111111", mode: .cbc))
        XCTAssertNil(BarkValidation.ivError("111111111111", mode: .gcm))
        XCTAssertEqual(BarkValidation.ivError("1111111111111111", mode: .gcm),
                       "GCM needs a 12-character IV (entered 16)")
        XCTAssertNil(BarkValidation.ivError("anything", mode: .ecb))
    }

    func testDeviceKeyExtraction() {
        XCTAssertEqual(BarkValidation.deviceKey(from: "  AbC123xyz  "), "AbC123xyz")
        XCTAssertEqual(BarkValidation.deviceKey(from: "https://api.day.app/AbC123xyz/Title/Body"), "AbC123xyz")
        XCTAssertEqual(BarkValidation.deviceKey(from: "https://api.day.app/AbC123xyz/"), "AbC123xyz")
        XCTAssertEqual(BarkValidation.deviceKey(from: "AbC123xyz/"), "AbC123xyz")
        XCTAssertNil(BarkValidation.deviceKeyError("AbC_12-3"))
        XCTAssertNotNil(BarkValidation.deviceKeyError(""))
        XCTAssertNotNil(BarkValidation.deviceKeyError("has space"))
    }

    func testServerNormalization() {
        XCTAssertEqual(BarkValidation.normalizedServer("https://api.day.app/"), "https://api.day.app")
        XCTAssertEqual(BarkValidation.normalizedServer("bark.example.com:8080"), "https://bark.example.com:8080")
        XCTAssertEqual(BarkValidation.normalizedServer("http://10.0.0.2:8080"), "http://10.0.0.2:8080")
        XCTAssertNil(BarkValidation.normalizedServer(""))
        XCTAssertNil(BarkValidation.normalizedServer("ftp://x.y"))
        XCTAssertNil(BarkValidation.normalizedServer("https://"))
        XCTAssertNil(BarkValidation.normalizedServer("bad host"))
    }
}

final class NotifyDraftTests: XCTestCase {
    private let configured = NotifySettings(
        enabled: true, hasDeviceKey: true,
        encryption: .init(enabled: true, algorithm: "AES128", mode: "CBC", hasKey: true),
        level: "active")

    func testUnchangedDraftHasNoPatchOrIssues() {
        let draft = NotifyDraft(settings: configured)
        XCTAssertTrue(draft.patch(against: configured).isEmpty)
        XCTAssertTrue(draft.issues(against: configured).isEmpty)
        XCTAssertEqual(draft.key, "", "secrets are write-only — never prefilled")
        XCTAssertEqual(draft.deviceKey, "")
    }

    func testEnablingRequiresDeviceKey() {
        let fresh = NotifySettings()
        var draft = NotifyDraft(settings: fresh)
        draft.enabled = true
        XCTAssertNotNil(draft.issues(against: fresh).deviceKey)
        draft.deviceKey = "https://api.day.app/Key123/"
        XCTAssertTrue(draft.issues(against: fresh).isEmpty)
        let patch = draft.patch(against: fresh)
        XCTAssertEqual(patch.enabled, true)
        XCTAssertEqual(patch.deviceKey, "Key123")
        XCTAssertNil(patch.encryption)
    }

    func testFirstDeviceKeyWithSwitchOffSendsExplicitDisable() {
        // Server: enabled defaults ON once a device key is set.
        let fresh = NotifySettings()
        var draft = NotifyDraft(settings: fresh)
        draft.deviceKey = "Key123"
        let patch = draft.patch(against: fresh)
        XCTAssertEqual(patch.enabled, false)
        XCTAssertEqual(patch.deviceKey, "Key123")
    }

    func testEncryptionRequiresKeyOfAlgorithmLength() {
        let fresh = NotifySettings(enabled: true, hasDeviceKey: true)
        var draft = NotifyDraft(settings: fresh)
        draft.encryptionEnabled = true
        draft.algorithm = .aes256
        XCTAssertEqual(draft.issues(against: fresh).key, "Enter a 32-character key")
        draft.key = String(repeating: "k", count: 16)
        XCTAssertEqual(draft.issues(against: fresh).key, "AES-256 needs a 32-character key (entered 16)")
        draft.key = String(repeating: "k", count: 32)
        XCTAssertTrue(draft.issues(against: fresh).isEmpty, "IV is optional")
        let enc = draft.patch(against: fresh).encryption
        XCTAssertEqual(enc?.enabled, true)
        XCTAssertEqual(enc?.algorithm, "AES256")
        XCTAssertEqual(enc?.key, String(repeating: "k", count: 32))
        XCTAssertNil(enc?.iv)
        XCTAssertNil(enc?.mode)
    }

    func testAlgorithmChangeRequiresReenteringKey() {
        var draft = NotifyDraft(settings: configured)
        draft.algorithm = .aes192
        XCTAssertEqual(draft.issues(against: configured).key,
                       "Re-enter the key — AES-192 uses 24 characters")
        draft.key = String(repeating: "x", count: 24)
        XCTAssertNil(draft.issues(against: configured).key)
    }

    func testIvValidatedWhenEnteredAndClearedOnModeChange() {
        var draft = NotifyDraft(settings: configured)
        draft.iv = "123"
        XCTAssertEqual(draft.issues(against: configured).iv, "CBC needs a 16-character IV (entered 3)")
        draft.iv = "1234567890123456"
        XCTAssertNil(draft.issues(against: configured).iv)
        XCTAssertEqual(draft.patch(against: configured).encryption?.iv, "1234567890123456")

        draft.iv = ""
        draft.mode = .gcm
        XCTAssertTrue(draft.issues(against: configured).isEmpty)
        let enc = draft.patch(against: configured).encryption
        XCTAssertEqual(enc?.mode, "GCM")
        XCTAssertEqual(enc?.iv, "", "a stale CBC IV is cleared so the server accepts GCM")

        draft.mode = .ecb
        draft.iv = "ignored"
        XCTAssertNil(draft.issues(against: configured).iv)
        XCTAssertEqual(draft.patch(against: configured).encryption?.iv, "")
    }

    func testLevelAndServerChanges() {
        var draft = NotifyDraft(settings: configured)
        draft.level = .timeSensitive
        draft.barkServer = "bark.example.com/"
        let patch = draft.patch(against: configured)
        XCTAssertEqual(patch.level, "timeSensitive")
        XCTAssertEqual(patch.barkServer, "https://bark.example.com")
        draft.barkServer = "not a url"
        XCTAssertNotNil(draft.issues(against: configured).server)
    }

    func testCriticalLevelIsPreserved() {
        var critical = configured
        critical.level = "critical"
        let draft = NotifyDraft(settings: critical)
        XCTAssertEqual(draft.level, .critical)
        XCTAssertNil(draft.patch(against: critical).level)
    }
}

@MainActor
final class NotificationSettingsModelTests: XCTestCase {
    func testLoadSaveReloadClearsSecrets() async {
        let stub = StubNotifyService()
        let model = NotificationSettingsModel(service: stub)
        await model.loadIfNeeded()
        XCTAssertEqual(model.saved, NotifySettings())
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.canTest, "no device key yet")

        model.draft.enabled = true
        model.draft.deviceKey = "Key123"
        XCTAssertTrue(model.canSave)
        let ok = await model.save()
        XCTAssertTrue(ok)
        XCTAssertEqual(stub.patches.count, 1)
        XCTAssertEqual(stub.getCalls, 2, "re-reads the server state after PUT")
        XCTAssertEqual(model.draft.deviceKey, "", "write-only secret is cleared after save")
        XCTAssertEqual(model.saved?.hasDeviceKey, true)
        XCTAssertTrue(model.didSave)
        XCTAssertFalse(model.hasChanges)
    }

    func testOldServerIsUnsupported() async {
        let stub = StubNotifyService()
        stub.getError = APIError.http(404, "Not Found", nil)
        let model = NotificationSettingsModel(service: stub)
        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .unsupported)
    }

    func testOtherLoadErrorIsFailure() async {
        let stub = StubNotifyService()
        stub.getError = APIError.offline
        let model = NotificationSettingsModel(service: stub)
        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .failed("Cannot reach server"))
    }

    func testSendTestSavesPendingChangesFirst() async {
        let stub = StubNotifyService(settings: NotifySettings(enabled: true, hasDeviceKey: true))
        let model = NotificationSettingsModel(service: stub)
        await model.loadIfNeeded()
        model.draft.level = .passive
        await model.sendTest()
        XCTAssertEqual(stub.patches.map(\.level), ["passive"])
        XCTAssertEqual(stub.testCalls, 1)
        XCTAssertEqual(model.testOutcome, .sent)
    }

    func testSendTestFailureIsShown() async {
        let stub = StubNotifyService(settings: NotifySettings(enabled: true, hasDeviceKey: true))
        stub.testResult = .success(NotifyTestResult(ok: false, status: "400", error: "bad key"))
        let model = NotificationSettingsModel(service: stub)
        await model.loadIfNeeded()
        await model.sendTest()
        XCTAssertEqual(model.testOutcome, .failed("bad key (status 400)"))
    }

    func testSaveErrorKeepsDraft() async {
        let stub = StubNotifyService(settings: NotifySettings(enabled: true, hasDeviceKey: true))
        stub.putError = APIError.http(400, "encryption key must be 16 characters for AES128", "invalid_notify_settings")
        let model = NotificationSettingsModel(service: stub)
        await model.loadIfNeeded()
        model.draft.encryptionEnabled = true
        model.draft.key = String(repeating: "k", count: 16)
        let ok = await model.save()
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(model.draft.key.count, 16, "typed secret survives a failed save")
    }
}

final class DeepLinkTests: XCTestCase {
    private func parse(_ string: String) -> DeepLink? {
        guard let url = URL(string: string) else { return nil }
        return DeepLink.parse(url)
    }

    func testParsesSessionLinks() {
        XCTAssertEqual(parse("remotepi://session/0123456789abcdef"), .session(id: "0123456789abcdef"))
        XCTAssertEqual(parse("remotepi://session/1730000000000_9b2f6c1e-1d0a-4f5e-9a7b-2c3d4e5f6a7b"),
                       .session(id: "1730000000000_9b2f6c1e-1d0a-4f5e-9a7b-2c3d4e5f6a7b"))
        XCTAssertEqual(parse("REMOTEPI://Session/abc/"), .session(id: "abc"))
        XCTAssertEqual(parse("remotepi://session/abc?from=bark"), .session(id: "abc"))
        XCTAssertEqual(parse("remotepi:///session/abc"), .session(id: "abc"))
    }

    func testBareSchemeIsHome() {
        XCTAssertEqual(parse("remotepi://"), .home, "the server's test push uses remotepi://")
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(parse("https://session/abc"))
        XCTAssertNil(parse("remotepi://session"))
        XCTAssertNil(parse("remotepi://session/"))
        XCTAssertNil(parse("remotepi://chat/abc"))
        XCTAssertNil(parse("remotepi://session/abc/extra"))
        XCTAssertNil(parse("remotepi://session/.."))
        XCTAssertNil(parse("remotepi://session/a%2Fb"))
        XCTAssertNil(parse("remotepi://session/" + String(repeating: "a", count: 129)))
    }

    func testRouterQueuesSessionAndReportsBadLinks() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "remotepi://session/abc")!)
        XCTAssertEqual(router.pendingSessionId, "abc")
        XCTAssertNil(router.banner)

        router.pendingSessionId = nil
        router.handle(URL(string: "remotepi://")!)
        XCTAssertNil(router.pendingSessionId)
        XCTAssertNil(router.banner)

        router.handle(URL(string: "remotepi://nope/x/y")!)
        XCTAssertNil(router.pendingSessionId)
        XCTAssertEqual(router.banner?.isError, true)
    }
}
