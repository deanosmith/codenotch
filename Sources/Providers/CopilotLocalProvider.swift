import Foundation
import os

/// Reads GitHub Copilot usage as the account VS Code Copilot Chat is signed
/// into, from the same `copilot_internal/user` endpoint the status-bar
/// dashboard uses.
actor CopilotLocalProvider: UsageProvider {
    nonisolated let id = "copilot"
    nonisolated let displayName = "Copilot"
    nonisolated let glyph = ProviderGlyph.copilot

    private let session: URLSession
    private let loadCredentials: @Sendable () throws -> CopilotCredentials

    /// The plan the last successful answer named, for the settings row.
    nonisolated(unsafe) private var lastKnownPlan: String?

    init(session: URLSession = .shared,
         loadCredentials: (@Sendable () throws -> CopilotCredentials)? = nil) {
        self.session = session
        self.loadCredentials = loadCredentials ?? { try CopilotCredentials.load() }
    }

    nonisolated var signInRoute: SignInRoute { CopilotCredentials.preferredRoute() }

    nonisolated func account() -> ProviderAccount? {
        CopilotCredentials.account(plan: lastKnownPlan.map(CopilotUsage.humanizePlan))
    }

    nonisolated func forgetCachedCredential() {
        CopilotCredentials.forgetCached()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try loadCredentials()

        var request = URLRequest(url: CopilotUsage.endpoint)
        request.setValue("token \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A readable token that GitHub has aged out is not a sign-out: VS Code
        // refreshes it the next time Copilot runs, the same overnight shape
        // as Claude Code's eight-hour token. `needsAuth` would discard the
        // last reading; `credentialExpired` keeps it, dimmed.
        if status == 401 { throw UsageProviderError.credentialExpired }
        if status == 403 {
            throw UsageProviderError.nothingMetered("No GitHub Copilot on this account")
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status),
              let body = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }

        Log.usage.debug("copilot usage -> \(body.prefix(900), privacy: .public)")

        let read = try CopilotUsage.reading(fromJSON: body)
        lastKnownPlan = read.plan

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: read.windows,
            headlineID: CopilotUsage.headlineID
        )
    }
}
