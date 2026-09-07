import SQLite3
import XCTest
@testable import Codenotch

/// Pinned to `GET https://api.github.com/copilot_internal/user` recorded from
/// a live Copilot Business seat on 2026-09-07. The endpoint is not a published
/// API, so this is what fails first if GitHub changes it.
final class CopilotUsageTests: XCTestCase {
    /// Verbatim enough: tracking fields dropped, quota shape intact.
    private let live = """
    {"login":"deanosmith","copilot_plan":"business",\
    "quota_reset_date":"2026-10-01",\
    "quota_reset_date_utc":"2026-10-01T00:00:00.000Z",\
    "token_based_billing":true,\
    "quota_snapshots":{\
      "chat":{"unlimited":true,"percent_remaining":100.0,"quota_id":"chat"},\
      "completions":{"unlimited":true,"percent_remaining":100.0,"quota_id":"completions"},\
      "premium_interactions":{"unlimited":false,"percent_remaining":96.9,\
        "quota_id":"premium_interactions","entitlement":50000,"credits_used":1543,\
        "token_based_billing":true,"overage_permitted":true}}}
    """

    private func windows(_ json: String) throws -> [LimitWindow] {
        try CopilotUsage.windows(fromJSON: json)
    }

    func testReadsThePercentageTheDashboardShows() throws {
        let w = try windows(live)
        XCTAssertEqual(w.map(\.id), ["credits"])
        XCTAssertEqual(w[0].label, "AI Credits")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.031, accuracy: 0.0001)
        XCTAssertEqual(w[0].summary, "3% Used · 97% left")
    }

    func testUnlimitedBucketsAreNotDrawnAsZero() throws {
        XCTAssertEqual(try windows(live).count, 1)
    }

    func testResetComesFromTheUtcTimestamp() throws {
        let reset = try XCTUnwrap(windows(live)[0].resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.year, from: reset), 2026)
        XCTAssertEqual(utc.component(.month, from: reset), 10)
        XCTAssertEqual(utc.component(.day, from: reset), 1)
        XCTAssertEqual(utc.component(.hour, from: reset), 0)
    }

    /// `premium_models` is the post-June 2026 name. When both sit in the
    /// payload the newer one is the dashboard, and promoting the old key
    /// would make the ring change subject without changing shape.
    func testPremiumModelsWinsOverPremiumInteractions() throws {
        let json = """
        {"copilot_plan":"individual_pro","token_based_billing":true,\
         "quota_snapshots":{\
           "premium_models":{"unlimited":false,"percent_remaining":50},\
           "premium_interactions":{"unlimited":false,"percent_remaining":10}}}
        """
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["credits"])
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(w[0].label, "AI Credits")
    }

    func testLegacyPremiumRequestsKeepThatName() throws {
        let json = """
        {"copilot_plan":"individual_pro","token_based_billing":false,\
         "quota_snapshots":{"premium_interactions":{"unlimited":false,"percent_remaining":80}}}
        """
        XCTAssertEqual(try windows(json)[0].label, "Premium Requests")
        XCTAssertEqual(try windows(json)[0].usedFraction ?? -1, 0.2, accuracy: 0.0001)
    }

    /// Copilot Free meters chat (and completions), not premium interactions.
    func testFreePlanLeadsWithChat() throws {
        let json = """
        {"copilot_plan":"free","quota_reset_date":"2026-10-01",\
         "quota_snapshots":{\
           "chat":{"unlimited":false,"percent_remaining":40},\
           "completions":{"unlimited":false,"percent_remaining":10},\
           "premium_interactions":{"unlimited":true,"percent_remaining":100}}}
        """
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["credits", "completions"])
        XCTAssertEqual(w[0].label, "Chat")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(w[1].label, "Completions")
        XCTAssertEqual(w[1].usedFraction ?? -1, 0.9, accuracy: 0.0001)
        let snap = ProviderSnapshot(
            id: "copilot", displayName: "Copilot", glyph: .copilot,
            fidelity: .official, status: .ok, windows: w,
            headlineID: CopilotUsage.headlineID
        )
        XCTAssertEqual(snap.headline?.id, "credits")
        XCTAssertEqual(snap.usedFraction ?? -1, 0.6, accuracy: 0.0001)
    }

    func testCalendarResetDateIsMidnightUTC() throws {
        let json = """
        {"copilot_plan":"business",\
         "quota_reset_date":"2026-10-01",\
         "quota_snapshots":{"premium_interactions":{"unlimited":false,"percent_remaining":90}}}
        """
        let reset = try XCTUnwrap(windows(json)[0].resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: reset), 0)
        XCTAssertEqual(utc.component(.day, from: reset), 1)
    }

    func testAllUnlimitedIsNothingMetered() {
        let json = """
        {"copilot_plan":"business","quota_snapshots":{\
          "chat":{"unlimited":true,"percent_remaining":100},\
          "premium_interactions":{"unlimited":true,"percent_remaining":100}}}
        """
        XCTAssertThrowsError(try windows(json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testMissingSnapshotsAreNothingMetered() {
        XCTAssertThrowsError(try windows(#"{"copilot_plan":"business"}"#)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testGarbageIsABadResponseRatherThanAGuess() {
        XCTAssertThrowsError(try windows("not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testTheDeclaredHeadlineSurvivesAMissingCreditsWindow() throws {
        let json = """
        {"copilot_plan":"business","quota_snapshots":{\
          "chat":{"unlimited":false,"percent_remaining":50}}}
        """
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["chat"])
        let snap = ProviderSnapshot(
            id: "copilot", displayName: "Copilot", glyph: .copilot,
            fidelity: .official, status: .ok, windows: w,
            headlineID: CopilotUsage.headlineID
        )
        XCTAssertNil(snap.headline, "a chat percentage must not wear the credits ring")
        XCTAssertEqual(snap.headlineText, "—")
    }

    func testHumanizesThePlanTheWayTheRowWritesIt() {
        XCTAssertEqual(CopilotUsage.humanizePlan("business"), "Business")
        XCTAssertEqual(CopilotUsage.humanizePlan("individual_pro"), "Individual Pro")
    }
}

final class CopilotCredentialsTests: XCTestCase {
    private let password = Data("codenotch-test-key".utf8)

    private let sessionsJSON = """
    [{"id":"s1","accessToken":"gho_narrow","account":{"label":"octocat","id":"1"},\
      "scopes":["user:email"]},\
     {"id":"s2","accessToken":"gho_copilot","account":{"label":"octocat","id":"1"},\
      "scopes":["read:user","repo","workflow","user:email"]}]
    """

    func testDecryptsTheV10BlobVSCodeWrites() throws {
        let plain = Data(sessionsJSON.utf8)
        let blob = CopilotSafeStorage.encrypt(plain, password: password)
        XCTAssertEqual(blob.prefix(3), Data("v10".utf8))
        let roundtrip = try XCTUnwrap(CopilotSafeStorage.decrypt(blob, password: password))
        XCTAssertEqual(roundtrip, plain)
    }

    func testAForeignPrefixIsRefusedRatherThanGuessed() {
        XCTAssertNil(CopilotSafeStorage.decrypt(Data("v11xxxx".utf8), password: password))
    }

    func testPicksTheSessionCopilotChatAskedFor() throws {
        let sessions = try XCTUnwrap(CopilotCredentials.sessions(fromPlaintext: Data(sessionsJSON.utf8)))
        let picked = try XCTUnwrap(CopilotCredentials.pick(from: sessions))
        XCTAssertEqual(picked.token, "gho_copilot")
        XCTAssertEqual(picked.username, "octocat")
    }

    func testANarrowerGrantIsUsedWhenItIsTheOnlyOne() throws {
        let json = """
        [{"accessToken":"gho_email","account":{"label":"octocat"},"scopes":["user:email"]}]
        """
        let sessions = try XCTUnwrap(CopilotCredentials.sessions(fromPlaintext: Data(json.utf8)))
        XCTAssertEqual(CopilotCredentials.pick(from: sessions)?.token, "gho_email")
    }

    func testReadsAppsJSONAsAFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"github.com:Iv23example":{"user":"octocat","oauth_token":"ghu_fromapps"}}
        """
        try json.write(to: dir.appendingPathComponent("apps.json"), atomically: true, encoding: .utf8)
        let creds = try XCTUnwrap(CopilotCredentials.loadConfig(from: dir))
        XCTAssertEqual(creds.accessToken, "ghu_fromapps")
        XCTAssertEqual(creds.username, "octocat")
    }

    func testAnEncryptedAuthDBRowIsSkipped() throws {
        // A ciphertext that is not a live ghu_/gho_ token is ZCode's enc:v1
        // lesson: skip rather than send garbage and read it as signed out.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(CopilotCredentials.loadAuthDB(dir.appendingPathComponent("auth.db")))
    }

    func testMissingEverythingIsNeedsAuth() {
        let missing = URL(fileURLWithPath: "/tmp/codenotch-no-vscode-\(UUID().uuidString)")
        let edition = CopilotCredentials.Edition(
            appName: "Missing", bundleID: "com.example.missing",
            supportFolder: "MissingCode",
            keychainService: "none", keychainAccount: "none"
        )
        XCTAssertThrowsError(
            try CopilotCredentials.load(editions: [edition], configDirectory: missing)
        ) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    /// A session blob we cannot open must not be replaced by the language
    /// server's token — that is a different GitHub account wearing Copilot's name.
    func testAReadableVSCodeBlobDoesNotFallThroughToAppsJSON() throws {
        let store = try makeVSCodeStore(blobBytes: Array("v10not-a-real-cipher".utf8),
                                        username: "from-vscode")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }
        try """
        {"github.com:Iv23example":{"user":"other-account","oauth_token":"ghu_other"}}
        """.write(to: config.appendingPathComponent("apps.json"), atomically: true, encoding: .utf8)

        let edition = CopilotCredentials.Edition(
            appName: "VS Code",
            bundleID: "com.example.codenotch-copilot-test",
            supportFolder: "Unused",
            keychainService: "codenotch-copilot-test-no-such-item",
            keychainAccount: "none",
            storeURL: store
        )
        defer { CopilotCredentials.forgetCached() }

        XCTAssertThrowsError(
            try CopilotCredentials.load(editions: [edition], configDirectory: config)
        ) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth (the VS Code blob), got \(error)")
            }
        }
        XCTAssertEqual(CopilotCredentials.account(plan: "Business", editions: [edition])?.label,
                       "from-vscode")
    }

    func testAppsJSONIsUsedWhenVSCodeHasNoSession() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {"github.com:Iv23example":{"user":"octocat","oauth_token":"ghu_fromapps"}}
        """.write(to: dir.appendingPathComponent("apps.json"), atomically: true, encoding: .utf8)
        let edition = CopilotCredentials.Edition(
            appName: "Missing", bundleID: "com.example.missing-session",
            supportFolder: "MissingCode",
            keychainService: "none", keychainAccount: "none"
        )
        let creds = try CopilotCredentials.load(editions: [edition], configDirectory: dir)
        XCTAssertEqual(creds.accessToken, "ghu_fromapps")
    }

    func testPreferredRouteOpensVSCode() {
        let route = CopilotCredentials.preferredRoute()
        guard case .openApp(let bundleID, let name) = route else {
            return XCTFail("expected openApp, got \(route)")
        }
        XCTAssertTrue(bundleID == "com.microsoft.VSCode" || bundleID == "com.microsoft.VSCodeInsiders")
        XCTAssertTrue(name == "VS Code" || name == "VS Code Insiders")
    }

    private func makeVSCodeStore(blobBytes: [UInt8], username: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-vscode-\(UUID().uuidString)")
        let dbURL = dir.appendingPathComponent("User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value TEXT);", nil, nil, nil)
        let payload = "{\"type\":\"Buffer\",\"data\":[\(blobBytes.map(String.init).joined(separator: ","))]}"
        insert(db, key: CopilotCredentials.secretKey, value: payload)
        if let username {
            insert(db, key: "github.copilot-github", value: username)
        }
        return dbURL
    }

    private func insert(_ db: OpaquePointer?, key: String, value: String) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        sqlite3_step(statement)
    }
}

final class CopilotLocalProviderTests: XCTestCase {
    override func tearDown() {
        CopilotHTTPStub.reset([])
        super.tearDown()
    }

    private let live = """
    {"login":"deanosmith","copilot_plan":"business",\
    "quota_reset_date":"2026-10-01",\
    "quota_reset_date_utc":"2026-10-01T00:00:00.000Z",\
    "token_based_billing":true,\
    "quota_snapshots":{\
      "chat":{"unlimited":true,"percent_remaining":100.0},\
      "completions":{"unlimited":true,"percent_remaining":100.0},\
      "premium_interactions":{"unlimited":false,"percent_remaining":96.9,\
        "entitlement":50000,"credits_used":1543,"token_based_billing":true}}}
    """

    private func provider() -> CopilotLocalProvider {
        CopilotLocalProvider(session: CopilotHTTPStub.session(), loadCredentials: {
            CopilotCredentials(accessToken: "gho_test", username: "octocat",
                               source: "VS Code", bundleID: "com.microsoft.VSCode",
                               appName: "VS Code")
        })
    }

    func testTheOfficialSnapshotAgreesWithTheDashboard() async throws {
        CopilotHTTPStub.reset([.init(status: 200, body: Data(live.utf8))])
        let snapshot = try await provider().fetchSnapshot()
        XCTAssertEqual(snapshot.id, "copilot")
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headlineID, "credits")
        XCTAssertEqual(snapshot.windows.map(\.id), ["credits"])
        XCTAssertEqual(snapshot.usedFraction ?? -1, 0.031, accuracy: 0.0001)
        XCTAssertEqual(snapshot.headlineText, "3%")
        XCTAssertEqual(CopilotHTTPStub.lastAuthorization, "token gho_test")
        XCTAssertEqual(CopilotHTTPStub.lastAPIVersion, "2025-04-01")
    }

    func testNeedsAuthTellsYouToSignInInVSCode() {
        let snap = ProviderSnapshot(
            id: "copilot", displayName: "Copilot", glyph: .copilot,
            fidelity: .official, status: .needsAuth, windows: []
        )
        XCTAssertEqual(snap.statusMessage, "Sign in to GitHub Copilot in VS Code")
    }

    func testA401IsCredentialExpiredNotASignOut() async {
        CopilotHTTPStub.reset([.init(status: 401)])
        do {
            _ = try await provider().fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
        } catch {
            XCTFail("expected credentialExpired, got \(error)")
        }
    }

    func testA403IsNothingMetered() async {
        CopilotHTTPStub.reset([.init(status: 403)])
        do {
            _ = try await provider().fetchSnapshot()
            XCTFail("expected nothingMetered")
        } catch UsageProviderError.nothingMetered {
        } catch {
            XCTFail("expected nothingMetered, got \(error)")
        }
    }

    func testA429IsRateLimited() async {
        CopilotHTTPStub.reset([.init(status: 429)])
        do {
            _ = try await provider().fetchSnapshot()
            XCTFail("expected rateLimited")
        } catch UsageProviderError.rateLimited {
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }
}

private final class CopilotHTTPStub: URLProtocol {
    struct Answer {
        let status: Int
        var body: Data = Data()
    }

    private static let lock = NSLock()
    private static var queued: [Answer] = []
    static var lastAuthorization: String?
    static var lastAPIVersion: String?

    static func reset(_ answers: [Answer]) {
        lock.lock()
        queued = answers
        lastAuthorization = nil
        lastAPIVersion = nil
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CopilotHTTPStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lastAPIVersion = request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
        let answer = Self.queued.isEmpty ? Answer(status: 500) : Self.queued.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: answer.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CopilotGlyphTests: XCTestCase {
    func testTheMarkIsEvenOddLoopsInTheUnitBox() {
        let outline = GlyphOutline.copilot
        XCTAssertGreaterThanOrEqual(outline.count, 3, "eyes plus the body")
        for loop in outline {
            XCTAssertGreaterThan(loop.count, 20)
            for p in loop {
                XCTAssertTrue((-0.01...1.01).contains(p.x), "x outside the unit box: \(p.x)")
                XCTAssertTrue((-0.01...1.01).contains(p.y), "y outside the unit box: \(p.y)")
            }
        }
    }

    func testItFillsTheBox() {
        let points = GlyphOutline.copilot.flatMap { $0 }
        let xs = points.map(\.x), ys = points.map(\.y)
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        XCTAssertEqual(span, 1, accuracy: 0.02)
    }

    func testTheMarkMatchesTheProviderGlyph() {
        XCTAssertEqual(ProviderGlyph.copilot.rawValue, "copilot")
        XCTAssertEqual(ProviderGlyph.copilot.outline, GlyphOutline.copilot)
        XCTAssertEqual(ProviderGlyph.copilot.assetName, "glyph-copilot")
    }
}
