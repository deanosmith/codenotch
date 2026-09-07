import SQLite3
import XCTest
@testable import Codenotch

/// Pinned to a response recorded from a live SuperGrok CLI session. Credits
/// is the weekly Grok Build allowance — the one number this account's own
/// endpoint actually states.
final class GrokUsageTests: XCTestCase {
    private let credits = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-09-05T08:21:18.802818+00:00",\
    "end":"2026-09-12T08:21:18.802818+00:00"},\
    "creditUsagePercent":8.0,\
    "onDemandCap":{"val":0},"onDemandUsed":{"val":0},\
    "productUsage":[{"product":"GrokBuild","usagePercent":8.0}],\
    "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},\
    "topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-09-05T08:21:18.802818+00:00",\
    "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
    """

    private func windows() throws -> [LimitWindow] {
        try GrokUsage.windows(creditsJSON: credits)
    }

    func testTheRingIsTheCreditsPercentage() throws {
        let credits = try XCTUnwrap(windows().first { $0.id == "credits" })
        XCTAssertEqual(credits.label, "Grok Build")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.08, accuracy: 0.0001)
    }

    func testWeeklyCreditsHaveTheirOwnReset() throws {
        let credits = try XCTUnwrap(windows().first { $0.id == "credits" })
        let reset = try XCTUnwrap(credits.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.month, from: reset), 9)
        XCTAssertEqual(utc.component(.day, from: reset), 12)
    }

    /// An empty config has nothing to draw a ring from — not a reading of
    /// zero, an absence of one.
    func testAnEmptyConfigIsNotASuccessfulReading() {
        XCTAssertThrowsError(try GrokUsage.windows(
            creditsJSON: #"{"config":{}}"#
        )) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// `creditUsagePercent` is absent; the product array is the reading. The
    /// ring is still declared as `headlineID: "credits"`.
    func testProductOnlyCreditsStillUseTheHeadlineID() throws {
        let productOnly = """
        {"config":{"productUsage":[{"product":"GrokBuild","usagePercent":33.0}],\
        "billingPeriodEnd":"2026-09-12T08:21:18.802818+00:00"}}
        """
        let w = try GrokUsage.windows(creditsJSON: productOnly)
        let credits = try XCTUnwrap(w.first { $0.id == "credits" })
        XCTAssertEqual(credits.label, "Grok Build")
        XCTAssertEqual(credits.usedFraction ?? -1, 0.33, accuracy: 0.0001)
        let snap = ProviderSnapshot(
            id: "grok", displayName: "Grok", glyph: .grok,
            fidelity: .official, status: .ok, windows: w, headlineID: "credits"
        )
        XCTAssertEqual(snap.headline?.id, "credits")
        XCTAssertEqual(snap.usedFraction ?? -1, 0.33, accuracy: 0.0001)
    }

    func testGarbageIsABadResponseRatherThanAGuess() {
        XCTAssertThrowsError(try GrokUsage.windows(creditsJSON: "not json")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testHumanizesTheProductNameTheWayTheModalWritesIt() {
        XCTAssertEqual(GrokUsage.humanize("GrokBuild"), "Grok Build")
    }
}

final class GrokCredentialsTests: XCTestCase {
    private func writeAuth(expiresAt: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        let json = """
        {"https://auth.x.ai::aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee":{\
          "key":"gsk_test","email":"octocat@x.ai",\
          "expires_at":"\(expiresAt)","oidc_issuer":"https://auth.x.ai"}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testALiveTokenLoads() throws {
        let url = try writeAuth(expiresAt: "2099-01-01T00:00:00.000Z")
        defer { try? FileManager.default.removeItem(at: url) }
        let creds = try GrokCredentials.load(from: url)
        XCTAssertEqual(creds.email, "octocat@x.ai")
        XCTAssertFalse(creds.isExpired)
        XCTAssertEqual(GrokCredentials.account(from: url)?.label, "octocat@x.ai")
    }

    /// An expired CLI file is a sign-out. Claude Code would refresh itself
    /// overnight; Grok CLI only does that when you run `grok`, so treating
    /// this as `credentialExpired` left a dash and "Waiting for the first
    /// reading…" on a session that would never come back.
    func testAnExpiredTokenIsNeedsAuth() throws {
        let url = try writeAuth(expiresAt: "2026-07-13T20:16:20.058262Z")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try GrokCredentials.load(from: url)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
        XCTAssertNil(GrokCredentials.account(from: url), "Settings must not pretend the CLI is still signed in")
        let creds = try GrokCredentials.load(from: url, allowingExpired: true)
        XCTAssertTrue(creds.isExpired)
    }

    func testChromeSessionIsDetectedFromCookieNamesOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-cookies-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT);", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO cookies (host_key, name) VALUES ('.grok.com', 'sso');", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertTrue(GrokCredentials.chromeHasGrokSession(cookiesURL: url))
    }

    func testAMissingChromeStoreIsNotASession() {
        let missing = URL(fileURLWithPath: "/tmp/codenotch-no-chrome-\(UUID().uuidString)/Cookies")
        XCTAssertFalse(GrokCredentials.chromeHasGrokSession(cookiesURL: missing))
    }

    func testNeedsAuthNamesTheCLINotGrokCom() {
        let snap = ProviderSnapshot(
            id: "grok", displayName: "Grok", glyph: .grok,
            fidelity: .official, status: .needsAuth, windows: []
        )
        XCTAssertEqual(snap.statusMessage,
                       "Run grok login — grok.com in Chrome is a different session")
    }
}
