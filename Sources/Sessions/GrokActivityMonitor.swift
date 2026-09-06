import AppKit
import Combine
import Foundation

/// Reports whether Grok Build is mid-turn.
///
/// Grok publishes no session status field — no equivalent of Claude Code's
/// `status` or Cursor's `unfinishedRunAt`. What it does do is append to a
/// session's `updates.jsonl` continuously while a turn runs, so a file written
/// moments ago means work is happening now.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. The window is longer than Codex's because
/// Grok can think for a while between two tool calls.
@MainActor
final class GrokActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let root: URL
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        root: URL = GrokCredentials.homeURL.appendingPathComponent("sessions"),
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 45
    ) {
        self.root = root
        self.interval = interval
        self.staleAfter = staleAfter
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
        let found = Self.read(root: root, staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    /// Two levels only: `sessions/<workspace>/<id>/updates.jsonl`. A recursive
    /// walk would stat every historical session on a two-second timer.
    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        guard let workspaces = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var newest: (session: URL, workspace: URL, modified: Date)?
        for workspace in workspaces {
            guard (try? workspace.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let sessions = try? manager.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for session in sessions {
                let updates = session.appendingPathComponent("updates.jsonl")
                guard let modified = (try? manager.attributesOfItem(atPath: updates.path))?[.modificationDate] as? Date
                else { continue }
                if newest == nil || modified > newest!.modified {
                    newest = (session, workspace, modified)
                }
            }
        }

        guard let newest,
              let session = session(
                id: newest.session.lastPathComponent,
                workspace: newest.workspace,
                modified: newest.modified,
                staleAfter: staleAfter,
                now: now
              )
        else { return [] }
        return [session]
    }

    static func session(
        id: String, workspace: URL, modified: Date,
        staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        guard now.timeIntervalSince(modified) <= staleAfter else { return nil }
        return AgentSession(
            id: "grok.\(id)",
            name: workspaceName(workspace),
            detail: "Working",
            state: .busy,
            waitingFor: nil,
            since: modified
        )
    }

    /// The workspace folder is a percent-encoded path. Decode it and keep the
    /// last component so the tooltip says `codenotch` rather than the whole
    /// home-directory URL. Subagent worktrees keep the generic name: their
    /// folder is a UUID, which is not something to read.
    static func workspaceName(_ url: URL) -> String {
        let encoded = url.lastPathComponent
        let decoded = encoded.removingPercentEncoding ?? encoded
        let last = URL(fileURLWithPath: decoded).lastPathComponent
        if last.hasPrefix("subagent-") || last.isEmpty { return "Grok" }
        return last
    }
}
