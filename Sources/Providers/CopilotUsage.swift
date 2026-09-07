import Foundation

/// Parses `GET https://api.github.com/copilot_internal/user`, the same payload
/// VS Code Copilot Chat uses for the status-bar dashboard.
///
/// Recorded from a live Copilot Business seat, 2026-09-07:
///
/// ```json
/// { "copilot_plan": "business",
///   "quota_reset_date": "2026-10-01",
///   "quota_reset_date_utc": "2026-10-01T00:00:00.000Z",
///   "quota_snapshots": {
///     "chat": { "unlimited": true, "percent_remaining": 100.0 },
///     "completions": { "unlimited": true, "percent_remaining": 100.0 },
///     "premium_interactions": {
///       "unlimited": false, "percent_remaining": 96.9,
///       "entitlement": 50000, "credits_used": 1543,
///       "token_based_billing": true } } }
/// ```
///
/// VS Code reports **percent remaining**. The notch shows **used**, so the
/// ring is `1 - percent_remaining/100`. `unlimited` buckets are omitted, not
/// drawn as 0%. The headline is declared as `credits` so a rename of the
/// wire key (`premium_models` vs `premium_interactions`) cannot silently
/// change what the ring means.
enum CopilotUsage {
    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!
    static let headlineID = "credits"

    struct Reading {
        let windows: [LimitWindow]
        let plan: String?
        let login: String?
    }

    static func reading(fromJSON json: String) throws -> Reading {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let plan = string(root["copilot_plan"])
        let login = string(root["login"])
        let resetsAt = date(root["quota_reset_date_utc"]) ?? day(root["quota_reset_date"])
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        let tokenBilled = bool(root["token_based_billing"]) == true

        var windows: [LimitWindow] = []
        if let headline = headlineBucket(in: snapshots, plan: plan),
           let window = window(headline.bucket, id: headlineID,
                               label: label(for: headline.key, tokenBilled: tokenBilled,
                                            snapshot: headline.bucket),
                               resetsAt: resetsAt) {
            windows.append(window)
        }

        for key in ["chat", "completions"] where key != headlineKey(in: snapshots, plan: plan) {
            guard let bucket = snapshots[key] as? [String: Any],
                  let window = window(bucket, id: key,
                                      label: label(for: key, tokenBilled: tokenBilled,
                                                   snapshot: bucket),
                                      resetsAt: resetsAt)
            else { continue }
            windows.append(window)
        }

        guard !windows.isEmpty else {
            let named = plan.map { "the \($0) plan" } ?? "this plan"
            throw UsageProviderError.nothingMetered("GitHub Copilot has nothing metered on \(named)")
        }
        return Reading(windows: windows, plan: plan, login: login)
    }

    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        try reading(fromJSON: json).windows
    }

    /// Paid plans lead with AI credits / premium interactions. Copilot Free
    /// leads with chat, matching VS Code's own quota service.
    static func headlineKey(in snapshots: [String: Any], plan: String?) -> String? {
        if isFree(plan) { return snapshots["chat"] != nil ? "chat" : nil }
        if snapshots["premium_models"] is [String: Any] { return "premium_models" }
        if snapshots["premium_interactions"] is [String: Any] { return "premium_interactions" }
        return nil
    }

    private static func headlineBucket(in snapshots: [String: Any], plan: String?)
        -> (key: String, bucket: [String: Any])? {
        guard let key = headlineKey(in: snapshots, plan: plan),
              let bucket = snapshots[key] as? [String: Any]
        else { return nil }
        return (key, bucket)
    }

    static func isFree(_ plan: String?) -> Bool {
        guard let plan else { return false }
        return plan.lowercased().contains("free")
    }

    /// A bucket only becomes a window when it is actually metered. Unlimited
    /// chat on a Business seat is not a 0% ring.
    static func window(_ bucket: [String: Any], id: String, label: String,
                       resetsAt: Date?) -> LimitWindow? {
        if bool(bucket["unlimited"]) == true { return nil }
        guard let remaining = percent(bucket["percent_remaining"]) else { return nil }
        let used = max(0, 1 - remaining)
        return LimitWindow(id: id, label: label, usedFraction: used, resetsAt: resetsAt)
    }

    static func label(for key: String, tokenBilled: Bool, snapshot: [String: Any]) -> String {
        let billed = tokenBilled || bool(snapshot["token_based_billing"]) == true
        switch key {
        case "premium_models", "premium_interactions", headlineID:
            return billed ? "AI Credits" : "Premium Requests"
        case "chat": return "Chat"
        case "completions": return "Completions"
        default: return key
        }
    }

    static func humanizePlan(_ plan: String) -> String {
        plan.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func percent(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        return number.doubleValue / 100
    }

    private static func bool(_ any: Any?) -> Bool? {
        (any as? Bool) ?? (any as? NSNumber).map { $0.boolValue }
    }

    private static func string(_ any: Any?) -> String? {
        (any as? String).flatMap { $0.isEmpty ? nil : $0 }
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

    /// `quota_reset_date` is a calendar day, midnight UTC.
    static func day(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date(any) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
