import XCTest
@testable import Codenotch

/// Copilot Chat writes an event stream while a turn runs. These pin what
/// counts as working — and what must not, or the ring would spin after the
/// chat had finished.
final class CopilotActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_776_400)
    private let launched = Date(timeIntervalSince1970: 1_788_770_000)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func event(_ type: String, at date: Date) -> String {
        "{\"type\":\"\(type)\",\"timestamp\":\"\(iso(date))\"}"
    }

    private func transcript(_ events: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-transcript-\(UUID().uuidString).jsonl")
        try events.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func session(events: [String],
                         launchedAt: Date? = Date(timeIntervalSince1970: 1_788_770_000),
                         now: Date? = nil) throws -> AgentSession? {
        let url = try transcript(events)
        defer { try? FileManager.default.removeItem(at: url) }
        return CopilotActivity.session(
            fromTranscript: url,
            workspace: "demo",
            vscodeLaunchedAt: launchedAt,
            now: now ?? self.now
        )
    }

    func testALiveToolRunIsBusy() throws {
        let start = now.addingTimeInterval(-20)
        let found = try session(events: [
            event("assistant.turn_start", at: start),
            event("tool.execution_start", at: start.addingTimeInterval(2))
        ])
        XCTAssertEqual(found?.state, .busy)
        XCTAssertEqual(found?.name, "demo")
        XCTAssertEqual(found?.detail, "VS Code")
    }

    func testAFinishedTurnIsNotBusy() throws {
        let start = now.addingTimeInterval(-20)
        XCTAssertNil(try session(events: [
            event("assistant.turn_start", at: start),
            event("assistant.turn_end", at: start.addingTimeInterval(5))
        ]))
    }

    /// VS Code writes a leftover `turn_start` at the same instant as `turn_end`
    /// when a turn completes. That is not a new turn.
    func testADanglingTurnStartAtTheSameInstantIsNotBusy() throws {
        let end = now.addingTimeInterval(-20)
        XCTAssertNil(try session(events: [
            event("assistant.turn_start", at: end.addingTimeInterval(-8)),
            event("assistant.turn_end", at: end),
            event("assistant.turn_start", at: end)
        ]))
    }

    func testAFreshTurnStartIsBusy() throws {
        let start = now.addingTimeInterval(-5)
        XCTAssertEqual(try session(events: [
            event("assistant.turn_start", at: start)
        ])?.state, .busy)
    }

    func testATurnIsNotBusyWhenVSCodeIsNotRunning() throws {
        XCTAssertNil(try session(events: [
            event("assistant.turn_start", at: now.addingTimeInterval(-5))
        ], launchedAt: nil))
    }

    func testATurnFromBeforeThisLaunchIsNotBusy() throws {
        XCTAssertNil(try session(events: [
            event("assistant.turn_start", at: launched.addingTimeInterval(-60)),
            event("tool.execution_start", at: launched.addingTimeInterval(-50))
        ]))
    }

    func testAStaleToolStartIsNotBusy() throws {
        let start = now.addingTimeInterval(-(CopilotActivity.toolStaleAfter + 10))
        XCTAssertNil(try session(events: [
            event("tool.execution_start", at: start)
        ]))
    }

    /// Ask mode never opens a transcript. VS Code's own timing contract is
    /// `lastRequestStarted` with no later `lastRequestEnded`.
    func testAnOpenIndexRequestIsBusy() {
        let started = now.addingTimeInterval(-10).timeIntervalSince1970 * 1000
        let json = """
        {"version":1,"entries":{"abc":{\
          "title":"Fix the build",\
          "timing":{"created":1,"lastRequestStarted":\(started)}\
        }}}
        """
        let found = CopilotActivity.sessions(
            fromIndexJSON: json, workspace: "demo",
            vscodeLaunchedAt: launched, staleAfter: 90, now: now)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.name, "Fix the build")
        XCTAssertEqual(found.first?.state, .busy)
    }

    func testAFinishedIndexRequestIsNotBusy() {
        let started = now.addingTimeInterval(-30).timeIntervalSince1970 * 1000
        let ended = now.addingTimeInterval(-5).timeIntervalSince1970 * 1000
        let json = """
        {"version":1,"entries":{"abc":{\
          "title":"Done",\
          "timing":{"created":1,"lastRequestStarted":\(started),"lastRequestEnded":\(ended)}\
        }}}
        """
        XCTAssertTrue(CopilotActivity.sessions(
            fromIndexJSON: json, workspace: "demo",
            vscodeLaunchedAt: launched, staleAfter: 90, now: now).isEmpty)
    }

    func testVSCodeNotRunningIsNotASession() {
        XCTAssertNil(CopilotActivity.vscodeLaunchDate(running: []))
        XCTAssertEqual(
            CopilotActivity.vscodeLaunchDate(
                running: [(bundleID: "com.microsoft.VSCode", launchDate: nil)]),
            .distantPast)
        XCTAssertNil(CopilotActivity.vscodeLaunchDate(
            running: [(bundleID: "com.apple.Safari", launchDate: Date())]))
    }

    func testTheWorkspaceFolderIsTheSessionName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-ws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {"folder":"file:///Users/octocat/work/k8s-airflow-dags"}
        """.write(to: root.appendingPathComponent("workspace.json"),
                  atomically: true, encoding: .utf8)
        XCTAssertEqual(CopilotActivity.workspaceName(at: root), "k8s-airflow-dags")
    }
}
