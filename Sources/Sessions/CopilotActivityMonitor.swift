import AppKit
import Combine
import Foundation

/// Notices when Copilot Chat in VS Code is mid-turn, so the Copilot ring
/// spins like the others.
///
/// The credential adapter only reads usage. Activity is a different file —
/// Copilot Chat's transcript — and without this monitor the ring stayed idle
/// through a live agent run. See `CopilotActivity` for why the transcript is
/// the signal and the session index is only a fallback.
@MainActor
final class CopilotActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let roots: [(url: URL, bundleID: String?)]
    private let interval: TimeInterval
    private var timer: Timer?

    init(workspaceStorage: URL? = nil, interval: TimeInterval = 2) {
        if let workspaceStorage {
            self.roots = [(workspaceStorage, nil)]
        } else {
            self.roots = CopilotCredentials.editions.map {
                (CopilotActivity.workspaceStorage(for: $0), $0.bundleID)
            }
        }
        self.interval = interval
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let running = Self.runningEditors()
        var found: [AgentSession] = []
        for root in roots {
            let launched: Date?
            if let id = root.bundleID {
                launched = CopilotActivity.vscodeLaunchDate(
                    running: running.filter { $0.bundleID == id })
            } else {
                launched = CopilotActivity.vscodeLaunchDate(running: running)
            }
            found += CopilotActivity.read(
                workspaceStorage: root.url, vscodeLaunchedAt: launched)
        }
        found.sort { $0.since > $1.since }
        guard found != sessions else { return }
        sessions = found
    }

    static func runningEditors() -> [(bundleID: String?, launchDate: Date?)] {
        NSWorkspace.shared.runningApplications.map {
            (bundleID: $0.bundleIdentifier, launchDate: $0.launchDate)
        }
    }
}
