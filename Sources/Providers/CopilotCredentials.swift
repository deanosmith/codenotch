import CommonCrypto
import Foundation
import Security
import SQLite3

/// The GitHub session VS Code Copilot Chat already holds.
///
/// Copilot Chat does not write `~/.config/github-copilot/apps.json` — that file
/// belongs to the language server used by vim and Zed. Chat stores a JSON
/// array of GitHub sessions under `vscode.github-authentication` / `github.auth`,
/// encrypted with Electron `safeStorage` and parked in `state.vscdb`.
///
/// Recon on a real Stable install (VS Code 1.136) settled the shape:
/// * The secret key is `secret://{"extensionId":"vscode.github-authentication","key":"github.auth"}`.
/// * The blob is Chromium `v10` (AES-128-CBC), not a keytar item.
/// * The encryption password lives in the login keychain, service
///   `Code Safe Storage`, account `Code Key` — the same bargain as Claude
///   Code's token: attributes are free, the data can prompt, cache it.
/// * There is no `vscodevscode.github-authentication` keychain item any more.
///
/// `~/.config/github-copilot` is only a fallback for an install that never
/// produced a VS Code session. A decrypt failure does *not* fall through to
/// that directory: that would be reading a different account under Copilot's
/// name, which is the Cursor-WebView bug.
struct CopilotCredentials: Sendable {
    let accessToken: String
    let username: String?
    let source: String
    let bundleID: String
    let appName: String

    struct Edition: Equatable {
        let appName: String
        let bundleID: String
        let supportFolder: String
        let keychainService: String
        let keychainAccount: String
        let storeURL: URL

        init(appName: String, bundleID: String, supportFolder: String,
             keychainService: String, keychainAccount: String, storeURL: URL? = nil) {
            self.appName = appName
            self.bundleID = bundleID
            self.supportFolder = supportFolder
            self.keychainService = keychainService
            self.keychainAccount = keychainAccount
            self.storeURL = storeURL ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(
                    "Library/Application Support/\(supportFolder)/User/globalStorage/state.vscdb")
        }
    }

    static let stable = Edition(
        appName: "VS Code",
        bundleID: "com.microsoft.VSCode",
        supportFolder: "Code",
        keychainService: "Code Safe Storage",
        keychainAccount: "Code Key"
    )
    static let insiders = Edition(
        appName: "VS Code Insiders",
        bundleID: "com.microsoft.VSCodeInsiders",
        supportFolder: "Code - Insiders",
        keychainService: "Code - Insiders Safe Storage",
        keychainAccount: "Code - Insiders Key"
    )
    static let editions = [stable, insiders]

    static var configDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/github-copilot")
    }

    static let secretKey = "secret://{\"extensionId\":\"vscode.github-authentication\",\"key\":\"github.auth\"}"
    static let manageURL = URL(string: "https://github.com/settings/copilot")!

    /// One cache per edition: Stable and Insiders are different keychain
    /// items, and a shared cache would hand Insiders the refusal recorded
    /// against Stable (or the wrong password).
    ///
    /// Held until the item moves — the password does not expire, and
    /// re-reading it is a prompt. The GitHub token itself is decrypted from
    /// `state.vscdb` on every load, so a rotation VS Code has already written
    /// is picked up without asking macOS again.
    private static let cacheLock = NSLock()
    private static var passwordCaches: [String: CredentialCache<Data>] = [:]

    static func forgetCached() {
        cacheLock.lock()
        let caches = Array(passwordCaches.values)
        cacheLock.unlock()
        caches.forEach { $0.forget() }
    }

    static func load(
        editions: [Edition] = editions,
        configDirectory: URL = configDirectory
    ) throws -> CopilotCredentials {
        // A VS Code session that we cannot decrypt must not fall through to
        // `~/.config/github-copilot`: that file is a different product's
        // account, and reading it under Copilot's name is the Cursor-WebView
        // bug. `loadVSCode` returns nil only when that edition has no session
        // blob at all; any failure to read a blob that *is* there propagates.
        for edition in editions {
            if let credentials = try loadVSCode(edition) { return credentials }
        }
        if let credentials = loadConfig(from: configDirectory) { return credentials }
        throw UsageProviderError.needsAuth
    }

    /// Identity that does not need the secret: VS Code caches the GitHub login
    /// in plaintext next to the encrypted session, so Settings can name the
    /// account before the keychain prompt has ever been answered.
    static func account(plan: String?, editions: [Edition] = editions,
                        configDirectory: URL = configDirectory) -> ProviderAccount? {
        for edition in editions {
            if let name = plaintextUsername(from: edition.storeURL) {
                return ProviderAccount(
                    label: name,
                    plan: plan,
                    source: edition.appName,
                    manageURL: manageURL
                )
            }
        }
        if let name = configUsername(from: configDirectory) {
            return ProviderAccount(
                label: name,
                plan: plan,
                source: "GitHub Copilot",
                manageURL: manageURL
            )
        }
        return nil
    }

    static func preferredRoute(editions: [Edition] = editions) -> SignInRoute {
        let chosen = editions.first { FileManager.default.fileExists(atPath: $0.storeURL.path) } ?? Self.stable
        return .openApp(bundleID: chosen.bundleID, name: chosen.appName)
    }

    // MARK: VS Code

    static func loadVSCode(_ edition: Edition) throws -> CopilotCredentials? {
        guard FileManager.default.fileExists(atPath: edition.storeURL.path) else { return nil }
        guard let blob = encryptedSecret(from: edition.storeURL) else { return nil }
        let password = try loadPassword(edition: edition)
        guard let plain = CopilotSafeStorage.decrypt(blob, password: password),
              let sessions = sessions(fromPlaintext: plain),
              let picked = pick(from: sessions)
        else {
            // The item was there and we were let in; the blob is just not a
            // v10 GitHub session. Guessing a different encryption would be
            // how a future VS Code build reports as signed out.
            throw UsageProviderError.badResponse(status: 0)
        }
        return CopilotCredentials(
            accessToken: picked.token,
            username: picked.username ?? plaintextUsername(from: edition.storeURL),
            source: edition.appName,
            bundleID: edition.bundleID,
            appName: edition.appName
        )
    }

    static func encryptedSecret(from store: URL) -> Data? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }
        guard let raw = SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?",
                                         bind: secretKey).first,
              let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bytes = root["data"] as? [Any]
        else { return nil }
        return Data(bytes.compactMap { ($0 as? NSNumber)?.uint8Value })
    }

    static func plaintextUsername(from store: URL) -> String? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }
        for key in ["github.copilot-github", "vscode.github-github"] {
            if let name = SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?",
                                           bind: key).first,
               !name.isEmpty, !name.hasPrefix("{") {
                return name
            }
        }
        return nil
    }

    private static func passwordCache(for edition: Edition) -> CredentialCache<Data> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = passwordCaches[edition.bundleID] { return existing }
        let created = CredentialCache<Data> { _ in false }
        passwordCaches[edition.bundleID] = created
        return created
    }

    private static func loadPassword(edition: Edition) throws -> Data {
        try passwordCache(for: edition).value(
            itemModifiedAt: {
                KeychainItem.modifiedAt(service: edition.keychainService,
                                        account: edition.keychainAccount)
            },
            reload: { try readPassword(edition: edition) }
        )
    }

    private static func readPassword(edition: Edition) throws -> Data {
        guard let winner = KeychainItem.newest(service: edition.keychainService,
                                               account: edition.keychainAccount)
        else { throw UsageProviderError.needsAuth }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: winner.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            Log.usage.error("copilot keychain \(edition.keychainService, privacy: .public) failed: OSStatus \(status)")
            if ClaudeCredentials.wasTransient(status) { throw UsageProviderError.credentialExpired }
            throw ClaudeCredentials.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }
        return data
    }

    // MARK: Sessions

    struct Session {
        let token: String
        let username: String?
        let scopes: Set<String>
    }

    /// Copilot Chat asks GitHub for `read:user user:email repo workflow`. That
    /// session is the one the dashboard is using; a narrower `user:email`-only
    /// neighbour sitting next to it is a different grant, not a fallback.
    static func pick(from sessions: [Session]) -> Session? {
        let live = sessions.filter { !$0.token.isEmpty }
        if let chat = live.first(where: {
            $0.scopes.contains("read:user") && $0.scopes.contains("repo")
        }) { return chat }
        if let readable = live.first(where: { $0.scopes.contains("read:user") }) { return readable }
        return live.first
    }

    static func sessions(fromPlaintext data: Data) -> [Session]? {
        let object = (try? JSONSerialization.jsonObject(with: data))
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let wrapped = object as? [String: Any],
                  let array = wrapped["data"] as? [[String: Any]] {
            rows = array
        } else {
            return nil
        }
        let parsed = rows.compactMap(session(from:))
        return parsed.isEmpty ? nil : parsed
    }

    static func session(from row: [String: Any]) -> Session? {
        let token = (row["accessToken"] as? String) ?? (row["access_token"] as? String)
        guard let token, !token.isEmpty else { return nil }
        let account = row["account"] as? [String: Any]
        let username = (account?["label"] as? String) ?? (row["account"] as? String)
        let scopes = Set((row["scopes"] as? [String]) ?? [])
        return Session(token: token, username: username, scopes: scopes)
    }

    // MARK: Language-server config fallback

    static func loadConfig(from directory: URL) -> CopilotCredentials? {
        if let fromJSON = loadJSONConfig(directory.appendingPathComponent("apps.json"))
            ?? loadJSONConfig(directory.appendingPathComponent("hosts.json")) {
            return fromJSON
        }
        return loadAuthDB(directory.appendingPathComponent("auth.db"))
    }

    static func loadJSONConfig(_ url: URL) -> CopilotCredentials? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for (key, value) in root {
            guard key.contains("github.com"),
                  let entry = value as? [String: Any],
                  let token = (entry["oauth_token"] as? String) ?? (entry["token"] as? String),
                  !token.isEmpty
            else { continue }
            return CopilotCredentials(
                accessToken: token,
                username: entry["user"] as? String,
                source: "GitHub Copilot",
                bundleID: stable.bundleID,
                appName: "VS Code"
            )
        }
        return nil
    }

    static func loadAuthDB(_ url: URL) -> CopilotCredentials? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT CAST(token_ciphertext AS TEXT) FROM oauth_tokens LIMIT 1"
        guard let token = SQLiteStore.rows(in: db, sql: sql).first,
              token.hasPrefix("ghu_") || token.hasPrefix("gho_")
        else { return nil }
        return CopilotCredentials(
            accessToken: token,
            username: nil,
            source: "GitHub Copilot",
            bundleID: stable.bundleID,
            appName: "VS Code"
        )
    }

    static func configUsername(from directory: URL) -> String? {
        for name in ["apps.json", "hosts.json"] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (key, value) in root {
                guard key.contains("github.com"),
                      let entry = value as? [String: Any],
                      let user = entry["user"] as? String, !user.isEmpty
                else { continue }
                return user
            }
        }
        return nil
    }
}

/// Chromium OSCrypt `v10` as Electron `safeStorage` writes it on macOS.
///
/// Password from the `… Safe Storage` keychain item, then
/// `PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16)` → AES-128-CBC with a
/// 16-space IV. Anything that is not `v10` is refused rather than guessed.
enum CopilotSafeStorage {
    static let prefix = Data("v10".utf8)
    static let salt = Data("saltysalt".utf8)
    static let iterations: UInt32 = 1003
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    static func decrypt(_ blob: Data, password: Data) -> Data? {
        guard blob.starts(with: prefix) else { return nil }
        let key = deriveKey(password)
        let ciphertext = blob.dropFirst(prefix.count)
        return crypt(ciphertext, key: key, operation: CCOperation(kCCDecrypt))
    }

    /// Exposed so a test can mint a fixture with the same scheme, rather than
    /// checking the live keychain.
    static func encrypt(_ plaintext: Data, password: Data) -> Data {
        let key = deriveKey(password)
        let cipher = crypt(plaintext, key: key, operation: CCOperation(kCCEncrypt)) ?? Data()
        return prefix + cipher
    }

    static func deriveKey(_ password: Data) -> Data {
        var derived = Data(count: kCCKeySizeAES128)
        _ = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        kCCKeySizeAES128
                    )
                }
            }
        }
        return derived
    }

    private static func crypt(_ data: Data, key: Data, operation: CCOperation) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        let inputCount = data.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, inputCount,
                            outputBytes.baseAddress, capacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}
