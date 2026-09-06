import AppKit
import Combine
import Foundation
import SQLite3

/// Reads what Cursor's agents are doing.
///
/// Two sources, because "Cursor" is no longer one program:
///
/// 1. **The editor's `composerHeaders`.** A run in flight sets `unfinishedRunAt`;
///    a turn that wants you sets `hasBlockingPendingActions` / `hasPendingPlan`.
///    Those flags are not cleared reliably, so a header only counts when the
///    stamp is still recent and belongs to the editor now running.
/// 2. **`~/.cursor/acp-sessions`.** T3 Code and `cursor-agent` record titled
///    threads there, not in `state.vscdb`. A session whose `store.db` (or its
///    WAL) was written moments ago is mid-turn. Untitled folders are probes
///    and are ignored.
///
/// The editor database is in **WAL mode**, so it must be opened without
/// `immutable`: that flag tells SQLite to ignore the write-ahead log, which
/// means reading whatever was true at the last checkpoint.
@MainActor
final class CursorActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let store: URL
    private let acpRoot: URL
    private let interval: TimeInterval
    /// How long a conversation may go without being written to before its run
    /// is treated as over.
    ///
    /// Measured over 33,484 gaps between consecutive writes inside a run on a
    /// real store: p50 0.7s, p99 38.1s, p99.9 239.3s, longest 826.0s. So the
    /// window has to clear fourteen minutes to never cut a live run, and the
    /// asymmetry says to clear it: dropping the spinner on an agent that is
    /// still working is visible on the headline surface, while an abandoned run
    /// lingering another five minutes is not — and the killed-editor case,
    /// which is the one that used to linger for ever, is now retired instantly
    /// by the launch check rather than by waiting this out.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(store: URL = CursorCredentials.storeURL,
         acpRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cursor/acp-sessions"),
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 15 * 60) {
        self.store = store
        self.acpRoot = acpRoot
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        // Polled rather than watched: the interesting writes land in the WAL
        // sidecar, and a directory event tells us a byte moved, not that a run
        // started. Two seconds is well inside "did that finish yet?".
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
        let found = Self.read(store: store, acpRoot: acpRoot,
                              cursorLaunchedAt: Self.cursorLaunchDate(),
                              staleAfter: staleAfter)
        guard found != sessions else { return }
        sessions = found
    }

    /// When the running editor started, or nil if Cursor is not running at all.
    ///
    /// The same question `ProcessLiveness` answers for agents that write a pid —
    /// "does the process that claimed this still exist?" — asked the only way a
    /// composer row allows, since it records no pid: against the editor as a
    /// whole. `session(fromHeader:...)` below says what it is needed for.
    ///
    /// A bundle-id miss would be indistinguishable from a closed editor and
    /// would silently retire every Cursor row for ever, so fall back to the
    /// bundle name. `launchDate` needs the same care for a different reason: it
    /// is optional and usually absent — of 123 running applications on the
    /// machine this was written on, 105 had none, Finder and Chrome among them.
    /// "Running, start time unknown" must not collapse into "not running", so it
    /// answers `.distantPast`: every row then predates it and the staleness
    /// window alone decides, which is the behaviour we had before this check.
    static func cursorLaunchDate() -> Date? {
        let running = NSWorkspace.shared.runningApplications
        let cursor = running.first { $0.bundleIdentifier == CursorCredentials.bundleID }
            ?? running.first { $0.bundleURL?.lastPathComponent == "Cursor.app" }
        return launchDate(found: cursor != nil, launchDate: cursor?.launchDate)
    }

    /// The two-state answer above, split out because `NSRunningApplication`
    /// cannot be built in a test and this is the half worth pinning.
    static func launchDate(found: Bool, launchDate: Date?) -> Date? {
        guard found else { return nil }
        return launchDate ?? .distantPast
    }

    static func read(store: URL, acpRoot: URL,
                     cursorLaunchedAt: Date?,
                     staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        (composerSessions(store: store, cursorLaunchedAt: cursorLaunchedAt,
                          staleAfter: staleAfter, now: now)
         + acpSessions(root: acpRoot, staleAfter: staleAfter, now: now))
            .sorted { $0.since > $1.since }
    }

    /// Compatibility for tests that only exercise the editor store.
    static func read(store: URL, cursorLaunchedAt: Date?,
                     staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        composerSessions(store: store, cursorLaunchedAt: cursorLaunchedAt,
                         staleAfter: staleAfter, now: now)
    }

    static func composerSessions(store: URL, cursorLaunchedAt: Date?,
                                 staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        guard let db = SQLiteStore.open(store) else { return [] }
        defer { sqlite3_close(db) }

        let values = SQLiteStore.rows(
            in: db,
            sql: "SELECT value FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40"
        )
        return values
            .compactMap {
                session(fromHeader: $0, cursorLaunchedAt: cursorLaunchedAt,
                        staleAfter: staleAfter, now: now)
            }
            .sorted { $0.since > $1.since }
    }

    /// Only sessions that are *doing* something are worth a row — an editor
    /// with forty idle chats in its history is not forty things happening.
    ///
    /// `unfinishedRunAt` is set when a run begins and cleared when it ends, but
    /// two things leave it set on a run that is over and neither clears it: the
    /// editor killed mid-run, and a run abandoned with the editor still up.
    ///
    /// It cannot date either of them. Measured against a real store, its value
    /// is the *composer's creation time*, not the current run's: one row there
    /// has two user turns seven minutes apart, was killed during the second,
    /// and still reports the first. So it is a flag, and the timestamp that
    /// answers "is this still going" has to be
    /// `conversationCheckpointLastUpdatedAt`, which Cursor moves on every
    /// message and tool result (falling back to `lastUpdatedAt`, which a
    /// quarter of rows carry instead).
    ///
    /// That one timestamp settles both cases:
    ///
    /// - Written before the editor's current launch, it belongs to a process
    ///   that is already gone — as does everything, when Cursor is not running
    ///   at all and `cursorLaunchedAt` is nil.
    /// - Written longer than `staleAfter` ago, the conversation has stopped
    ///   being written to, which is the only evidence an abandoned run leaves.
    static func session(fromHeader json: String,
                        cursorLaunchedAt: Date?,
                        staleAfter: TimeInterval,
                        now: Date = Date()) -> AgentSession? {
        guard let data = json.data(using: .utf8),
              let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = head["composerId"] as? String
        else { return nil }

        let blocked = (head["hasBlockingPendingActions"] as? Bool) == true
            || (head["hasPendingPlan"] as? Bool) == true
        let runStart = date(head["unfinishedRunAt"])
        // A quarter of rows carry `lastUpdatedAt` and no checkpoint at all.
        let lastWrite = date(head["conversationCheckpointLastUpdatedAt"])
            ?? date(head["lastUpdatedAt"])

        let isRunning: Bool = {
            guard let runStart, let cursorLaunchedAt else { return false }
            // Nothing written yet means the composer was only just created, and
            // since `unfinishedRunAt` *is* its creation time that is the most
            // recent thing to have happened to it. The same value on a chat
            // opened last week is correctly stale.
            let touched = lastWrite ?? runStart
            guard touched >= cursorLaunchedAt else { return false }
            return now.timeIntervalSince(touched) <= staleAfter
        }()

        let state: AgentSession.State
        if blocked { state = .waiting }
        else if isRunning { state = .busy }
        else { return nil }

        // `runStart` is the composer's creation time, so it dates a busy row the
        // way it always has — from when the chat began. A row that is merely
        // waiting must not borrow it: a session blocked since this morning did
        // not start waiting when the chat was opened last week.
        let since = (isRunning ? runStart : nil)
            ?? lastWrite
            ?? date(head["createdAt"])
            ?? now

        return AgentSession(
            id: "cursor.\(id)",
            name: (head["name"] as? String) ?? "Untitled chat",
            detail: (head["subtitle"] as? String) ?? "Cursor",
            state: state,
            waitingFor: blocked ? "needs your input" : nil,
            since: since
        )
    }

    /// Titled ACP threads whose store was written inside `staleAfter`.
    /// Recency is the signal: the folder has no status field.
    static func acpSessions(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let stamp = [mtime(folder.appendingPathComponent("store.db-wal")),
                         mtime(folder.appendingPathComponent("store.db"))]
                .compactMap { $0 }
                .max()
            guard let stamp, now.timeIntervalSince(stamp) <= staleAfter else { return nil }
            guard let title = acpTitle(in: folder), !title.isEmpty else { return nil }
            let cwd = acpCwd(in: folder)
            return AgentSession(
                id: "cursor.acp.\(folder.lastPathComponent)",
                name: title,
                detail: "Agent · \(cwd)",
                state: .busy,
                waitingFor: nil,
                since: stamp
            )
        }
    }

    /// Cursor writes its timestamps as milliseconds since the epoch.
    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func acpMeta(in folder: URL) -> [String: Any]? {
        let url = folder.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func acpTitle(in folder: URL) -> String? {
        acpMeta(in: folder)?["title"] as? String
    }

    /// Last path component of the session cwd, so the tooltip says `codenotch`
    /// rather than the whole home-directory URL.
    static func acpCwd(in folder: URL) -> String {
        let raw = acpMeta(in: folder)?["cwd"] as? String ?? ""
        let last = URL(fileURLWithPath: raw).lastPathComponent
        return last.isEmpty ? "Agent" : last
    }
}
