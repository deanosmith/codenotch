import Foundation
import SQLite3

/// Identity and token from `~/.grok/auth.json`.
///
/// Grok CLI signs in through `auth.x.ai` and writes the session here. Codenotch
/// only reads it — refreshing is Grok's job, the same bargain as Claude Code's
/// keychain token. Writing a new access token would race the CLI for the file.
///
/// grok.com in Chrome is a **different** session. Since August 2026 the site's
/// billing endpoint requires a browser-held Web Key Exchange proof that lives
/// only inside the page, so the `sso` cookie is not enough to read the Usage
/// tab. The weekly SuperGrok pool on that tab is the same meter `grok login`
/// exposes through `cli-chat-proxy` — that is why the recovery is the CLI,
/// not a second grok.com sign-in.
struct GrokCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    static var chromeCookiesURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies")
    }

    let accessToken: String
    let expiresAt: Date
    let email: String?

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let stored = (try? load(from: url, allowingExpired: true)), !stored.isExpired
        else { return nil }
        return ProviderAccount(
            label: stored.email,
            plan: nil,
            source: "Grok",
            manageURL: URL(string: "https://grok.com/?_s=usage")
        )
    }

    static func load(from url: URL = authURL, allowingExpired: Bool = false) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = pick(from: root)
        else { throw UsageProviderError.needsAuth }

        guard let token = entry["key"] as? String, !token.isEmpty else {
            throw UsageProviderError.needsAuth
        }

        let credentials = GrokCredentials(
            accessToken: token,
            expiresAt: date(entry["expires_at"]) ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
            email: entry["email"] as? String
        )
        // Claude Code refreshes its token the next time it runs. Grok CLI does
        // the same — but only when you actually run `grok`. An expired file
        // with nobody launching the CLI is a sign-out, not a brief stale
        // reading that will fix itself overnight.
        if credentials.isExpired, !allowingExpired { throw UsageProviderError.needsAuth }
        return credentials
    }

    /// Cookie **names** only — never the encrypted value. Enough to tell the
    /// Settings row that grok.com in Chrome is already signed in, so the
    /// prompt does not send someone back to a site they are looking at.
    static func chromeHasGrokSession(cookiesURL: URL = chromeCookiesURL) -> Bool {
        guard let db = SQLiteStore.open(cookiesURL) else { return false }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT name FROM cookies
            WHERE name = 'sso'
              AND (host_key = 'grok.com' OR host_key = '.grok.com')
            LIMIT 1
            """
        return SQLiteStore.rows(in: db, sql: sql).first != nil
    }

    static var signInRoute: SignInRoute {
        if chromeHasGrokSession() {
            return .guidance(
                "You're signed in to grok.com in Chrome. Run grok login so the "
                + "notch can read the same weekly SuperGrok limit — grok.com's "
                + "own session can't be borrowed."
            )
        }
        return .guidance("Run grok login — it signs in and refreshes the token this reads.")
    }

    /// Only a session minted by xAI itself. The file is keyed by
    /// `issuer::client_id`, and Grok also supports a customer IdP whose token
    /// is meant for a private proxy — sending that to cli-chat-proxy.grok.com
    /// would be handing someone else's credential to the public endpoint.
    static let trustedIssuer = "https://auth.x.ai"

    /// The file is keyed by `issuer::client_id`. One signed-in CLI is the
    /// ordinary case; if several sit there, the one that is still live wins,
    /// otherwise the first *trusted* entry.
    static func pick(from root: [String: Any]) -> [String: Any]? {
        let entries = root.compactMap { key, value -> [String: Any]? in
            guard let entry = value as? [String: Any], isTrusted(key: key, entry: entry)
            else { return nil }
            return entry
        }
        if let live = entries.first(where: {
            guard let expiry = date($0["expires_at"]) else { return true }
            return expiry > Date()
        }) { return live }
        return entries.first
    }

    static func isTrusted(key: String, entry: [String: Any]) -> Bool {
        if key.hasPrefix(trustedIssuer) { return true }
        if let issuer = entry["oidc_issuer"] as? String, issuer == trustedIssuer { return true }
        return false
    }

    static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
