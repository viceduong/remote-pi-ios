import XCTest
@testable import RemotePi

/// In-memory §12 endpoints (no network) for model + snapshot tests.
final class StubWorkdirService: WorkdirService {
    struct CreateCall {
        let name: String
        let workdir: String?
        let createDir: Bool
        let clientRequestId: String?
    }

    var rootsResult: Result<DirRoots, Error>
    /// Keyed by lower-cased path; unknown paths are "missing".
    var listings: [String: DirListing] = [:]
    var listError: Error?
    /// Consumed in order; when empty, create succeeds.
    var createResults: [Result<SessionSummary, Error>] = []
    private(set) var listCalls: [String] = []
    private(set) var createCalls: [CreateCall] = []

    init(roots: DirRoots) {
        rootsResult = .success(roots)
    }

    init(rootsError: Error) {
        rootsResult = .failure(rootsError)
    }

    func dirRoots() async throws -> DirRoots {
        try rootsResult.get()
    }

    func listDirs(path: String) async throws -> DirListing {
        listCalls.append(path)
        if let listError { throw listError }
        if let listing = listings[path.lowercased()] { return listing }
        return DirListing(path: path, exists: false, isDir: false, parent: WorkdirPath.parent(path))
    }

    func createSession(name: String, workdir: String?, createDir: Bool,
                       clientRequestId: String?) async throws -> SessionSummary {
        createCalls.append(CreateCall(name: name, workdir: workdir, createDir: createDir,
                                      clientRequestId: clientRequestId))
        if !createResults.isEmpty { return try createResults.removeFirst().get() }
        return Self.session(id: "s-\(createCalls.count)", name: name, workdir: workdir ?? "D:\\ai-ching")
    }

    static func session(id: String, name: String, workdir: String?) -> SessionSummary {
        var json: [String: Any] = ["id": id, "name": name.isEmpty ? "untitled" : name,
                                   "running": false, "busy": false, "messageCount": 0,
                                   "createdAt": 0, "lastActivityAt": 0]
        if let workdir { json["workdir"] = workdir }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionSummary.self, from: data)
    }
}

func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "remotepi-tests-\(UUID().uuidString)")!
}

final class WorkdirDecodingTests: XCTestCase {
    private func listing(_ json: String) throws -> DirListing {
        try JSONDecoder().decode(DirListing.self, from: Data(json.utf8))
    }

    private func roots(_ json: String) throws -> DirRoots {
        try JSONDecoder().decode(DirRoots.self, from: Data(json.utf8))
    }

    func testListingFullShape() throws {
        let l = try listing(#"""
        {"path":"D:\\ai-ching","exists":true,"isDir":true,"allowed":true,"parent":"D:\\",
         "entries":[{"name":"ios","path":"D:\\ai-ching\\ios"},{"name":"server","path":"D:\\ai-ching\\server"}],
         "truncated":true}
        """#)
        XCTAssertEqual(l.path, "D:\\ai-ching")
        XCTAssertTrue(l.exists)
        XCTAssertTrue(l.isDir)
        XCTAssertTrue(l.allowed)
        XCTAssertEqual(l.parent, "D:\\")
        XCTAssertEqual(l.entries.map(\.name), ["ios", "server"])
        XCTAssertEqual(l.entries.map(\.path), ["D:\\ai-ching\\ios", "D:\\ai-ching\\server"])
        XCTAssertTrue(l.truncated)
    }

    func testListingNullParentAtRootAndMissingFolder() throws {
        let root = try listing(#"{"path":"D:\\","exists":true,"isDir":true,"allowed":true,"parent":null,"entries":[],"truncated":false}"#)
        XCTAssertNil(root.parent)
        XCTAssertTrue(root.entries.isEmpty)

        let missing = try listing(#"{"path":"D:\\new\\app","exists":false,"isDir":false,"allowed":true,"parent":"D:\\new","entries":[]}"#)
        XCTAssertFalse(missing.exists)
        XCTAssertFalse(missing.isDir)
        XCTAssertFalse(missing.truncated, "absent truncated → false")
    }

    func testListingTolerantEntriesAndMissingKeys() throws {
        // Bad items dropped, bare names joined to the path, name-only object
        // gets a path, dupes (case-insensitive) dropped, missing keys default.
        let l = try listing(#"""
        {"path":"D:\\work","entries":[42, null, "alpha", {"name":"beta"}, {"path":"D:\\work\\Gamma"},
                                       {"name":"x","path":"D:\\work\\gamma"}, {"foo":1}]}
        """#)
        XCTAssertTrue(l.exists, "absent exists/isDir → a listing that came back exists")
        XCTAssertTrue(l.isDir)
        XCTAssertTrue(l.allowed)
        XCTAssertEqual(l.parent, "D:\\", "absent parent → derived from the path")
        XCTAssertEqual(l.entries.map(\.name), ["alpha", "beta", "Gamma"])
        XCTAssertEqual(l.entries.map(\.path), ["D:\\work\\alpha", "D:\\work\\beta", "D:\\work\\Gamma"])
    }

    func testListingEntriesNotAnArray() throws {
        let l = try listing(#"{"path":"D:\\x","exists":true,"isDir":true,"entries":"nope","truncated":"yes"}"#)
        XCTAssertTrue(l.entries.isEmpty)
        XCTAssertFalse(l.truncated)
    }

    func testRootsFullShape() throws {
        let r = try roots(#"""
        {"roots":["D:\\"],"default":"D:\\ai-ching",
         "recent":[{"path":"D:\\ai-ching","lastUsedAt":1761500000000,"sessions":12},
                   {"path":"D:\\projects\\site","lastUsedAt":1761400000000,"sessions":1},
                   {"path":"d:\\AI-CHING","lastUsedAt":1,"sessions":1}]}
        """#)
        XCTAssertTrue(r.isUsable)
        XCTAssertEqual(r.roots, ["D:\\"])
        XCTAssertEqual(r.defaultDir, "D:\\ai-ching")
        XCTAssertEqual(r.recent.map(\.path), ["D:\\ai-ching", "D:\\projects\\site"], "case-insensitive dedupe, order kept")
        XCTAssertEqual(r.recent.first?.sessions, 12)
        XCTAssertEqual(r.recent.first?.lastUsedAt, 1761500000000)
        XCTAssertEqual(r.recent.last?.name, "site")
    }

    func testRootsTolerantForms() throws {
        let r = try roots(#"""
        {"roots":[{"path":"D:\\"},"E:\\work",7,""],"recent":["D:\\a",{"path":"D:\\b","sessions":"many"},{"nope":true}]}
        """#)
        XCTAssertEqual(r.roots, ["D:\\", "E:\\work"])
        XCTAssertEqual(r.recent.map(\.path), ["D:\\a", "D:\\b"])
        XCTAssertNil(r.recent[1].sessions)
        XCTAssertNil(r.defaultDir)
    }

    func testRootsFromNonSection12JSONIsUnusable() throws {
        let r = try roots(#"{"ok":true}"#)
        XCTAssertFalse(r.isUsable)
        XCTAssertTrue(r.recent.isEmpty)
    }

    func testRejectionParsing() {
        let forbidden = WorkdirRejection.parse(
            status: 403, data: Data(#"{"error":"outside roots","code":"workdir_forbidden","roots":["D:\\"]}"#.utf8),
            dirsEndpoint: false)
        XCTAssertEqual(forbidden?.code, WorkdirRejection.forbidden)
        XCTAssertEqual(forbidden?.roots, ["D:\\"])
        XCTAssertEqual(forbidden?.errorDescription, "Not allowed — must be inside D:\\")

        let notDir = WorkdirRejection.parse(status: 400, data: Data(#"{"code":"workdir_not_dir"}"#.utf8),
                                            dirsEndpoint: false)
        XCTAssertEqual(notDir?.code, WorkdirRejection.notDir)

        // /api/dirs 403 without a code is still a path rejection.
        let dirs403 = WorkdirRejection.parse(status: 403, data: Data("{}".utf8), dirsEndpoint: true)
        XCTAssertEqual(dirs403?.status, 403)

        XCTAssertNil(WorkdirRejection.parse(status: 401, data: Data(#"{"code":"workdir_forbidden"}"#.utf8),
                                            dirsEndpoint: true))
        XCTAssertNil(WorkdirRejection.parse(status: 500, data: Data(), dirsEndpoint: true))
        XCTAssertNil(WorkdirRejection.parse(status: 409, data: Data(#"{"code":"session_live"}"#.utf8),
                                            dirsEndpoint: false), "unrelated errors stay APIError")
        XCTAssertNil(WorkdirRejection.parse(status: 400, data: Data("{}".utf8), dirsEndpoint: false))
    }

    func testQueryEncodingEscapesSeparators() {
        let encoded = "D:\\a&b=c+d#e".addingPercentEncoding(withAllowedCharacters: APIClient.queryValueAllowed)
        XCTAssertEqual(encoded, "D:%5Ca%26b%3Dc%2Bd%23e")
    }
}

final class WorkdirPathTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(WorkdirPath.normalize("  d:/foo//bar/ "), "D:\\foo\\bar")
        XCTAssertEqual(WorkdirPath.normalize("D:"), "D:\\")
        XCTAssertEqual(WorkdirPath.normalize("D:\\"), "D:\\")
        XCTAssertEqual(WorkdirPath.normalize(""), "")
        XCTAssertEqual(WorkdirPath.normalize("\\\\server\\share"), "\\\\server\\share")
    }

    func testIsAbsolute() {
        XCTAssertTrue(WorkdirPath.isAbsolute("D:\\x"))
        XCTAssertTrue(WorkdirPath.isAbsolute("c:/x"))
        XCTAssertTrue(WorkdirPath.isAbsolute("D:"))
        XCTAssertFalse(WorkdirPath.isAbsolute("projects\\x"))
        XCTAssertFalse(WorkdirPath.isAbsolute("\\\\server\\share"))
        XCTAssertFalse(WorkdirPath.isAbsolute("/usr/local"))
        XCTAssertFalse(WorkdirPath.isAbsolute("1:\\x"))
    }

    func testParent() {
        XCTAssertEqual(WorkdirPath.parent("D:\\a\\b"), "D:\\a")
        XCTAssertEqual(WorkdirPath.parent("D:\\a"), "D:\\")
        XCTAssertEqual(WorkdirPath.parent("D:\\a\\b\\"), "D:\\a")
        XCTAssertNil(WorkdirPath.parent("D:\\"))
        XCTAssertNil(WorkdirPath.parent(""))
    }

    func testAppendingName() {
        XCTAssertEqual(WorkdirPath.appending("new", to: "D:\\a"), "D:\\a\\new")
        XCTAssertEqual(WorkdirPath.appending("new", to: "D:\\"), "D:\\new")
        XCTAssertEqual(WorkdirPath.appending(" new ", to: "D:\\a\\"), "D:\\a\\new")
        XCTAssertEqual(WorkdirPath.appending("", to: "D:\\a"), "D:\\a")
    }

    func testLastComponent() {
        XCTAssertEqual(WorkdirPath.lastComponent("D:\\ai-ching\\ios"), "ios")
        XCTAssertEqual(WorkdirPath.lastComponent("D:\\ai-ching\\"), "ai-ching")
        XCTAssertEqual(WorkdirPath.lastComponent("D:\\"), "D:\\")
        XCTAssertEqual(WorkdirPath.lastComponent("D:"), "D:\\")
    }

    func testRootContainmentIsCaseInsensitive() {
        XCTAssertTrue(WorkdirPath.isInside("d:\\AI-Ching\\sub", root: "D:\\ai-ching"))
        XCTAssertTrue(WorkdirPath.isInside("D:\\ai-ching", root: "d:\\AI-CHING\\"))
        XCTAssertFalse(WorkdirPath.isInside("D:\\ai-chingX", root: "D:\\ai-ching"), "prefix is not containment")
        XCTAssertTrue(WorkdirPath.isInside("d:\\anything\\deep", root: "D:\\"))
        XCTAssertTrue(WorkdirPath.isInside("D:\\", root: "D:\\"))
        XCTAssertFalse(WorkdirPath.isInside("E:\\x", root: "D:\\"))
        XCTAssertTrue(WorkdirPath.isInsideAny("e:\\work\\a", roots: ["D:\\", "E:\\Work"]))
        XCTAssertFalse(WorkdirPath.isInsideAny("C:\\Windows", roots: ["D:\\", "E:\\Work"]))
        XCTAssertTrue(WorkdirPath.same("d:/x/", "D:\\X"))
    }

    func testValidation() {
        XCTAssertNil(WorkdirPath.validationError(""))
        XCTAssertNil(WorkdirPath.validationError("D:\\projects\\app"))
        XCTAssertNotNil(WorkdirPath.validationError("projects\\app"))
        XCTAssertNotNil(WorkdirPath.validationError("\\\\server\\share"))
        XCTAssertNotNil(WorkdirPath.validationError("D:\\a\\..\\b"))
        XCTAssertNotNil(WorkdirPath.validationError("D:\\a|b"))
        XCTAssertNotNil(WorkdirPath.validationError("D:\\a:b"))
        XCTAssertNotNil(WorkdirPath.validationError("D:\\a\u{01}b"))
        XCTAssertNotNil(WorkdirPath.validationError("D:\\" + String(repeating: "a", count: 300)))
    }

    func testFolderNameValidation() {
        XCTAssertNil(WorkdirPath.folderNameError("weather-app"))
        XCTAssertNil(WorkdirPath.folderNameError("v1.2"))
        XCTAssertNotNil(WorkdirPath.folderNameError(""))
        XCTAssertNotNil(WorkdirPath.folderNameError(".."))
        XCTAssertNotNil(WorkdirPath.folderNameError("a/b"))
        XCTAssertNotNil(WorkdirPath.folderNameError("a\\b"))
        XCTAssertNotNil(WorkdirPath.folderNameError("trailing."))
        XCTAssertNotNil(WorkdirPath.folderNameError("CON"))
        XCTAssertNotNil(WorkdirPath.folderNameError("com1.txt"))
    }
}

final class WorkdirStatusTests: XCTestCase {
    private let roots = ["D:\\"]

    func testTexts() {
        XCTAssertEqual(WorkdirStatus.existing.text, "Existing folder")
        XCTAssertEqual(WorkdirStatus.willCreate.text, "Will be created")
        XCTAssertEqual(WorkdirStatus.notAllowed(roots: ["D:\\"]).text, "Not allowed — must be inside D:\\")
        XCTAssertEqual(WorkdirStatus.notAllowed(roots: ["D:\\", "E:\\w"]).text,
                       "Not allowed — must be inside D:\\ or E:\\w")
        XCTAssertEqual(WorkdirStatus.notADirectory.text, "Not a folder")
    }

    func testFromListing() {
        XCTAssertEqual(WorkdirStatus.from(listing: DirListing(path: "D:\\a"), roots: roots), .existing)
        XCTAssertEqual(WorkdirStatus.from(listing: DirListing(path: "D:\\a", exists: false, isDir: false),
                                          roots: roots), .willCreate)
        XCTAssertEqual(WorkdirStatus.from(listing: DirListing(path: "D:\\a.txt", exists: true, isDir: false),
                                          roots: roots), .notADirectory)
        XCTAssertEqual(WorkdirStatus.from(listing: DirListing(path: "D:\\a", allowed: false), roots: roots),
                       .notAllowed(roots: roots))
    }

    func testFromError() {
        let forbidden = WorkdirRejection(status: 403, code: WorkdirRejection.forbidden, message: "", roots: ["E:\\"])
        XCTAssertEqual(WorkdirStatus.from(error: forbidden, roots: roots), .notAllowed(roots: ["E:\\"]))
        let bare403 = WorkdirRejection(status: 403, code: nil, message: "", roots: [])
        XCTAssertEqual(WorkdirStatus.from(error: bare403, roots: roots), .notAllowed(roots: roots))
        let missing = WorkdirRejection(status: 404, code: WorkdirRejection.missing, message: "", roots: [])
        XCTAssertEqual(WorkdirStatus.from(error: missing, roots: roots), .willCreate)
        let notDir = WorkdirRejection(status: 400, code: WorkdirRejection.notDir, message: "", roots: [])
        XCTAssertEqual(WorkdirStatus.from(error: notDir, roots: roots), .notADirectory)
        let bad = WorkdirRejection(status: 400, code: "workdir_invalid", message: "Reserved name", roots: [])
        XCTAssertEqual(WorkdirStatus.from(error: bad, roots: roots), .invalid("Reserved name"))
        XCTAssertEqual(WorkdirStatus.from(error: APIError.http(404, "Not Found", nil), roots: roots), .willCreate)
        if case .unknown = WorkdirStatus.from(error: APIError.offline, roots: roots) {} else {
            XCTFail("network failure → unknown (server decides)")
        }
    }

    func testPreflightAndAllowsCreate() {
        XCTAssertEqual(WorkdirStatus.preflight("E:\\x", roots: roots), .notAllowed(roots: roots))
        XCTAssertNil(WorkdirStatus.preflight("d:\\x", roots: roots))
        XCTAssertNil(WorkdirStatus.preflight("E:\\x", roots: []), "unknown roots → ask the server")
        if case .invalid = WorkdirStatus.preflight("relative", roots: roots) {} else { XCTFail() }
        XCTAssertTrue(WorkdirStatus.existing.allowsCreate)
        XCTAssertTrue(WorkdirStatus.willCreate.allowsCreate)
        XCTAssertTrue(WorkdirStatus.serverDefault(nil).allowsCreate)
        XCTAssertTrue(WorkdirStatus.unknown("x").allowsCreate)
        XCTAssertFalse(WorkdirStatus.notAllowed(roots: roots).allowsCreate)
        XCTAssertFalse(WorkdirStatus.notADirectory.allowsCreate)
        XCTAssertFalse(WorkdirStatus.invalid("x").allowsCreate)
    }

    func testCreateFailureMapping() {
        let forbidden = WorkdirStatus.createFailure(
            WorkdirRejection(status: 403, code: WorkdirRejection.forbidden, message: "x", roots: ["D:\\"]), roots: [])
        XCTAssertEqual(forbidden.status, .notAllowed(roots: ["D:\\"]))
        XCTAssertEqual(forbidden.message, "Not allowed — must be inside D:\\")
        let notDir = WorkdirStatus.createFailure(
            WorkdirRejection(status: 400, code: WorkdirRejection.notDir, message: "x", roots: []), roots: roots)
        XCTAssertEqual(notDir.status, .notADirectory)
        let missing = WorkdirStatus.createFailure(
            WorkdirRejection(status: 404, code: WorkdirRejection.missing, message: "x", roots: []), roots: roots)
        XCTAssertNil(missing.status)
        let offline = WorkdirStatus.createFailure(APIError.offline, roots: roots)
        XCTAssertNil(offline.status)
        XCTAssertEqual(offline.message, APIError.offline.errorDescription)
    }
}

@MainActor
final class NewSessionModelTests: XCTestCase {
    private let info = DirRoots(roots: ["D:\\"],
                                recent: [RecentDir(path: "D:\\ai-ching", lastUsedAt: 2, sessions: 3)],
                                defaultDir: "D:\\ai-ching")

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeModel(_ stub: StubWorkdirService, defaults: UserDefaults = freshDefaults()) -> NewSessionModel {
        NewSessionModel(api: stub, memory: WorkdirMemory(serverKey: "srv", defaults: defaults), debounceNanos: 0)
    }

    func testLoadPrefillsServerDefaultAndChecksIt() async {
        let stub = StubWorkdirService(roots: info)
        stub.listings["d:\\ai-ching"] = DirListing(path: "D:\\ai-ching", parent: "D:\\")
        let model = makeModel(stub)
        XCTAssertEqual(model.path, "")
        await model.loadRoots()
        XCTAssertTrue(model.showsFolderUI)
        XCTAssertEqual(model.path, "D:\\ai-ching")
        await waitFor { model.status != .checking }
        XCTAssertEqual(model.status, .existing)
        XCTAssertEqual(model.browseStart, "D:\\ai-ching")
    }

    func testLastUsedFolderWinsOverDefault() async {
        let defaults = freshDefaults()
        WorkdirMemory(serverKey: "srv", defaults: defaults).remember("d:/projects/site/")
        WorkdirMemory(serverKey: "other", defaults: defaults).remember("D:\\elsewhere")
        let stub = StubWorkdirService(roots: info)
        let model = makeModel(stub, defaults: defaults)
        XCTAssertEqual(model.path, "D:\\projects\\site", "per-server memory, normalized")
        await model.loadRoots()
        XCTAssertEqual(model.path, "D:\\projects\\site")
        await waitFor { model.status != .checking }
        XCTAssertEqual(model.status, .willCreate, "missing inside a root")
        XCTAssertNil(model.browseStart)
    }

    func testOutsideRootsIsRejectedLocally() async {
        let stub = StubWorkdirService(roots: info)
        let model = makeModel(stub)
        await model.loadRoots()
        await waitFor { model.status != .checking }
        let callsBefore = stub.listCalls.count
        model.path = "E:\\stuff"
        XCTAssertEqual(model.status, .notAllowed(roots: ["D:\\"]))
        XCTAssertFalse(model.canCreate)
        model.path = "relative\\dir"
        if case .invalid = model.status {} else { XCTFail("relative path is invalid") }
        model.path = ""
        XCTAssertEqual(model.status, .serverDefault("D:\\ai-ching"))
        XCTAssertTrue(model.canCreate)
        XCTAssertEqual(stub.listCalls.count, callsBefore, "no request for local verdicts")
    }

    func testOldServerHidesFolderUIAndCreatesByName() async {
        let stub = StubWorkdirService(rootsError: APIError.http(404, "Not Found", nil))
        let defaults = freshDefaults()
        WorkdirMemory(serverKey: "srv", defaults: defaults).remember("D:\\x")
        let model = makeModel(stub, defaults: defaults)
        await model.loadRoots()
        XCTAssertEqual(model.support, .unsupported)
        XCTAssertFalse(model.showsFolderUI)
        XCTAssertNil(model.requestedWorkdir)
        model.name = "  Plain  "
        let session = await model.create()
        XCTAssertNotNil(session)
        XCTAssertEqual(stub.createCalls.count, 1)
        XCTAssertEqual(stub.createCalls[0].name, "Plain")
        XCTAssertNil(stub.createCalls[0].workdir)
        XCTAssertFalse(stub.createCalls[0].createDir)
        XCTAssertNotNil(stub.createCalls[0].clientRequestId)
        XCTAssertEqual(WorkdirMemory(serverKey: "srv", defaults: defaults).lastUsed, "D:\\x",
                       "an old server never overwrites the remembered folder")
    }

    func testCreateRetryReusesClientRequestIdAndRemembersFolder() async {
        let stub = StubWorkdirService(roots: info)
        stub.createResults = [.failure(APIError.offline)]
        let defaults = freshDefaults()
        let model = makeModel(stub, defaults: defaults)
        await model.loadRoots()
        model.path = "D:\\projects\\new-app"
        await waitFor { model.status != .checking }
        XCTAssertEqual(model.status, .willCreate)

        let first = await model.create()
        XCTAssertNil(first)
        XCTAssertEqual(model.createError, APIError.offline.errorDescription)
        let second = await model.create()
        XCTAssertNotNil(second)
        XCTAssertEqual(stub.createCalls.count, 2)
        XCTAssertEqual(stub.createCalls[0].clientRequestId, stub.createCalls[1].clientRequestId,
                       "retry reuses the idempotency key")
        XCTAssertEqual(stub.createCalls[1].workdir, "D:\\projects\\new-app")
        XCTAssertTrue(stub.createCalls[1].createDir)
        XCTAssertNil(model.createError)
        XCTAssertEqual(WorkdirMemory(serverKey: "srv", defaults: defaults).lastUsed, "D:\\projects\\new-app")
    }

    func testForbiddenCreateShowsInlineErrorAndNewInputsGetANewId() async {
        let stub = StubWorkdirService(roots: DirRoots(roots: ["D:\\"]))
        stub.createResults = [.failure(WorkdirRejection(status: 403, code: WorkdirRejection.forbidden,
                                                        message: "no", roots: ["D:\\"]))]
        let model = makeModel(stub)
        await model.loadRoots()
        model.path = "D:\\junction\\escape"
        await waitFor { model.status != .checking }
        _ = await model.create()
        XCTAssertEqual(model.createError, "Not allowed — must be inside D:\\")
        XCTAssertEqual(model.status, .notAllowed(roots: ["D:\\"]))
        XCTAssertFalse(model.canCreate)

        model.path = "D:\\projects\\ok"
        XCTAssertNil(model.createError, "editing clears the error")
        await waitFor { model.status != .checking }
        _ = await model.create()
        XCTAssertEqual(stub.createCalls.count, 2)
        XCTAssertNotEqual(stub.createCalls[0].clientRequestId, stub.createCalls[1].clientRequestId,
                          "different inputs → a new request")
    }

    func testBrowserUpNavigation() {
        let stub = StubWorkdirService(roots: info)
        let single = FolderBrowserModel(api: stub, roots: ["D:\\"], start: nil)
        XCTAssertEqual(single.path, "D:\\", "starts at the first root")
        XCTAssertNil(single.upDestination, "single root: nowhere above it")

        let nested = FolderBrowserModel(api: stub, roots: ["D:\\"], start: "D:\\ai-ching\\ios")
        nested.seedForTesting(DirListing(path: "D:\\ai-ching\\ios", parent: "D:\\ai-ching"))
        XCTAssertEqual(nested.upDestination ?? nil, "D:\\ai-ching")
        XCTAssertTrue(nested.canUse)

        let multi = FolderBrowserModel(api: stub, roots: ["D:\\", "E:\\work"], start: "E:\\work")
        multi.seedForTesting(DirListing(path: "E:\\work", parent: nil))
        if let destination = multi.upDestination {
            XCTAssertNil(destination, "above a root → the root list")
        } else {
            XCTFail("several roots → up goes to the root list")
        }
        multi.goUp()
        XCTAssertEqual(multi.state, .rootList)
        XCTAssertNil(multi.path)
        XCTAssertFalse(multi.canUse)
    }
}
