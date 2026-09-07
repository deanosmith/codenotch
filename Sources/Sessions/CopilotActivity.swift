import Foundation
import SQLite3

/// Live Copilot Chat work, read from the files VS Code itself writes while a
/// turn runs.
///
/// Copilot publishes no session registry the way Claude Code does. What it
/// does write, continuously, is GitHub Copilot Chat's event-stream transcript
/// (`GitHub.copilot-chat/transcripts/<id>.jsonl`) and, on save, the workspace
/// `chat.ChatSessionStore.index`. The transcript is the one that moves during
/// a turn — `assistant.turn_start`, `tool.execution_start`, then the matching
/// `*_end` / `*_complete` — so that is what the spinner follows.
///
/// The index is a fallback for Ask-mode chats that never open a transcript:
/// `timing.lastRequestStarted` without a later `lastRequestEnded` is VS Code's
/// own "still in progress" contract. Pending/NeedsInput are rewritten to
/// Cancelled when the index is flushed, so `lastResponseState` on disk is not
/// a live signal and is ignored.
enum CopilotActivity {
    /// How long a turn may go without a new transcript event before it is
    /// treated as over. Tools can sit in `execution_start` for a long time
    /// (a test run, a build); thinking before the first tool is shorter.
    static let toolStaleAfter: TimeInterval = 15 * 60
    static let turnStaleAfter: TimeInterval = 90

    static func workspaceStorage(for edition: CopilotCredentials.Edition) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/\(edition.supportFolder)/User/workspaceStorage")
    }

    /// When the running editor started, or nil if neither Stable nor Insiders
    /// is up. Same two-state answer Cursor uses: a miss must not collapse into
    /// "running, start unknown", and a missing `launchDate` must not collapse
    /// into "not running".
    static func vscodeLaunchDate(
        running: [(bundleID: String?, launchDate: Date?)]
    ) -> Date? {
        let ids = Set(CopilotCredentials.editions.map(\.bundleID))
        let found = running.first { ids.contains($0.bundleID ?? "") }
        guard found != nil else { return nil }
        return found?.launchDate ?? .distantPast
    }

    static func read(
        workspaceStorage: URL,
        vscodeLaunchedAt: Date?,
        now: Date = Date()
    ) -> [AgentSession] {
        guard let vscodeLaunchedAt else { return [] }
        let workspaces = (try? FileManager.default.contentsOfDirectory(
            at: workspaceStorage,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        var found: [AgentSession] = []
        for workspace in workspaces {
            let name = workspaceName(at: workspace)
            let transcripts = workspace
                .appendingPathComponent("GitHub.copilot-chat/transcripts")
            if let live = newestLiveTranscript(
                in: transcripts, workspace: name,
                vscodeLaunchedAt: vscodeLaunchedAt, now: now
            ) {
                found.append(live)
                continue
            }
            if let fromIndex = sessions(
                fromIndexAt: workspace.appendingPathComponent("state.vscdb"),
                workspace: name,
                vscodeLaunchedAt: vscodeLaunchedAt,
                staleAfter: turnStaleAfter,
                now: now
            ).first {
                found.append(fromIndex)
            }
        }
        return found.sorted { $0.since > $1.since }
    }

    static func newestLiveTranscript(
        in directory: URL, workspace: String,
        vscodeLaunchedAt: Date, now: Date
    ) -> AgentSession? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        let jsonl = files.filter { $0.pathExtension == "jsonl" }
        var best: AgentSession?
        for url in jsonl {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate)
            if let mtime, now.timeIntervalSince(mtime) > toolStaleAfter { continue }
            guard let session = session(
                fromTranscript: url, workspace: workspace,
                vscodeLaunchedAt: vscodeLaunchedAt, now: now
            ) else { continue }
            if best == nil || session.since > best!.since { best = session }
        }
        return best
    }

    /// One Copilot Chat transcript. Busy when a turn or a tool has started and
    /// not yet ended, and that start is recent enough that a killed editor
    /// cannot leave it spinning.
    static func session(
        fromTranscript url: URL,
        workspace: String,
        vscodeLaunchedAt: Date?,
        now: Date
    ) -> AgentSession? {
        guard let vscodeLaunchedAt,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        var lastTurnStart: Date?
        var lastTurnEnd: Date?
        var lastToolStart: Date?
        var lastToolComplete: Date?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let event = transcriptEvent(String(line)) else { continue }
            switch event.type {
            case "assistant.turn_start":
                lastTurnStart = event.at
            case "assistant.turn_end":
                lastTurnEnd = event.at
            case "tool.execution_start":
                lastToolStart = event.at
            case "tool.execution_complete":
                lastToolComplete = event.at
            default:
                break
            }
        }

        // A dangling `turn_start` written at the same instant as `turn_end`
        // is how VS Code serialises the end of a completed turn, not a new
        // one. Equal timestamps therefore do not count as in flight.
        let toolInFlight = isInFlight(start: lastToolStart, end: lastToolComplete)
        let turnInFlight = isInFlight(start: lastTurnStart, end: lastTurnEnd)

        let since: Date
        let staleAfter: TimeInterval
        if toolInFlight, let start = lastToolStart {
            since = start
            staleAfter = toolStaleAfter
        } else if turnInFlight, let start = lastTurnStart {
            since = start
            staleAfter = turnStaleAfter
        } else {
            return nil
        }

        guard since >= vscodeLaunchedAt,
              now.timeIntervalSince(since) <= staleAfter
        else { return nil }

        return AgentSession(
            id: "copilot.\(url.deletingPathExtension().lastPathComponent)",
            name: workspace,
            detail: "VS Code",
            state: .busy,
            waitingFor: nil,
            since: since
        )
    }

    /// VS Code's documented "still in progress": `lastRequestStarted` with no
    /// later `lastRequestEnded`.
    static func sessions(
        fromIndexJSON json: String,
        workspace: String,
        vscodeLaunchedAt: Date?,
        staleAfter: TimeInterval,
        now: Date
    ) -> [AgentSession] {
        guard let vscodeLaunchedAt,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [String: Any]
        else { return [] }

        return entries.compactMap { id, raw -> AgentSession? in
            guard let entry = raw as? [String: Any] else { return nil }
            let timing = entry["timing"] as? [String: Any] ?? [:]
            guard let started = millis(timing["lastRequestStarted"]) else { return nil }
            let ended = millis(timing["lastRequestEnded"])
            guard isInFlight(start: started, end: ended) else { return nil }
            guard started >= vscodeLaunchedAt,
                  now.timeIntervalSince(started) <= staleAfter
            else { return nil }
            let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AgentSession(
                id: "copilot.\(id)",
                name: title ?? workspace,
                detail: "VS Code",
                state: .busy,
                waitingFor: nil,
                since: started
            )
        }
    }

    static func sessions(
        fromIndexAt db: URL,
        workspace: String,
        vscodeLaunchedAt: Date?,
        staleAfter: TimeInterval,
        now: Date
    ) -> [AgentSession] {
        guard let store = SQLiteStore.open(db) else { return [] }
        defer { sqlite3_close(store) }
        let sql = "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index' LIMIT 1"
        guard let json = SQLiteStore.rows(in: store, sql: sql).first else { return [] }
        return sessions(fromIndexJSON: json, workspace: workspace,
                        vscodeLaunchedAt: vscodeLaunchedAt, staleAfter: staleAfter, now: now)
    }

    static func isInFlight(start: Date?, end: Date?) -> Bool {
        guard let start else { return false }
        guard let end else { return true }
        return start > end
    }

    static func workspaceName(at folder: URL) -> String {
        let meta = folder.appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: meta),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "Copilot Chat" }
        let uri = (root["folder"] as? String) ?? (root["workspace"] as? String)
        guard let uri, let url = URL(string: uri) else { return "Copilot Chat" }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? "Copilot Chat" : name
    }

    private static func transcriptEvent(_ line: String) -> (type: String, at: Date)? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String,
              let at = isoDate(root["timestamp"] as? String)
        else { return nil }
        return (type, at)
    }

    private static func millis(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }
}
