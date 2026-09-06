import Foundation
import SQLite3
import os

/// Reads Codex usage from the rollout log of the thread it last worked on.
///
/// No credential and no network: Codex records its own rate-limit snapshots
/// locally, the same bargain as reading Claude Code's session files. The newest
/// rollout is found through Codex's thread index rather than by walking the
/// sessions tree, which holds thousands of files.
actor CodexLocalProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex"
    nonisolated let glyph = ProviderGlyph.openai

    private let stateStore: URL
    nonisolated private let authURL: URL
    nonisolated private let vault: AccountVault
    private let session: URLSession
    /// Only the tail matters — the newest snapshot is at the end of the file.
    private let tailBytes = 256 * 1024

    init(stateStore: URL = CodexStore.stateURL,
         authURL: URL = CodexCredentials.authURL,
         vault: AccountVault = .shared,
         session: URLSession = .shared) {
        self.stateStore = stateStore
        self.authURL = authURL
        self.vault = vault
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute { .openApp(bundleID: "com.openai.codex", name: "Codex") }

    nonisolated func liveAccount() -> ProviderAccount? { CodexCredentials.account(from: authURL) }

    nonisolated func account() -> ProviderAccount? {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return saved.asProviderAccount(
                manageURL: URL(string: "https://chatgpt.com/#settings/Account")
            )
        }
        return liveAccount()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return decorate(try await savedReading(saved), extra: true)
        }

        // Codex itself first. The rollout below is a record of what was true
        // during the last turn; this is what is true now, and the two disagree
        // by however long it has been since Codex was used.
        if let live = await liveReading(), !live.windows.isEmpty {
            return decorate(ProviderSnapshot(
                id: id, displayName: displayName, glyph: glyph,
                fidelity: .official, status: .ok, windows: live.windows,
                headlineID: "primary", block: live.block
            ), extra: false)
        }

        guard let rollout = CodexStore.newestRollout(in: stateStore) else {
            throw UsageProviderError.nothingMetered("No Codex threads on this machine yet")
        }
        let text = try tail(of: rollout)
        let windows = try CodexUsage.windows(fromRollout: text)

        return decorate(ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: Self.status(recordedAt: CodexUsage.recordedAt(inRollout: text)),
            windows: windows,
            headlineID: "primary"
        ), extra: false)
    }

    /// Ask Codex's app server for the live figure.
    ///
    /// Off the actor: spawning a process and waiting on a pipe is blocking
    /// work, and doing it here would stall every other read this provider owes.
    /// Nil rather than throwing when Codex is not installed or does not answer
    /// — that is the ordinary case for someone who does not use it, and the
    /// caller has an honest fallback either way.
    private func liveReading() async -> (windows: [LimitWindow], block: UsageBlock?)? {
        guard let executable = CodexBridge.executable() else { return nil }
        let answer = await Task.detached(priority: .utility) { () -> Data? in
            do {
                return try CodexBridge.rateLimits(executable: executable)
            } catch {
                Log.usage.error("codex: app server failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
        guard let answer else { return nil }
        let windows = CodexBridge.windows(in: answer)
        if windows.isEmpty {
            Log.usage.error("codex: app server answered with no windows we understood")
            return nil
        }
        let block = CodexBridge.block(in: answer)
        Log.usage.debug("codex: live reading, \(windows.count) window(s), blocked: \(block != nil)")
        return (windows, block)
    }

    /// WHAM for a Codenotch-held extra account. Must not fall back to the
    /// rollout or the app server: those belong to the borrowed live login.
    private func savedReading(_ account: SavedAccount) async throws -> ProviderSnapshot {
        var current = account
        do {
            current = try await ChatGPTOAuth.fresh(current, session: session)
        } catch {
            if current.isExpired { throw UsageProviderError.credentialExpired }
        }
        if current != account { vault.update(current, provider: id) }

        let (data, status) = try await wham(account: current)
        if status == 401 || status == 403 {
            let refreshed = try await ChatGPTOAuth.refresh(current, session: session)
            vault.update(refreshed, provider: id)
            let retry = try await wham(account: refreshed)
            return try snapshot(fromWHAM: retry.data, status: retry.status, account: refreshed)
        }
        return try snapshot(fromWHAM: data, status: status, account: current)
    }

    private func snapshot(fromWHAM data: Data, status: Int,
                          account: SavedAccount) throws -> ProviderSnapshot {
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        let windows = CodexUsage.windows(fromWHAM: data)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("Codex reported no usage windows")
        }
        let plan = CodexUsage.plan(fromWHAM: data)
        let email = CodexUsage.email(fromWHAM: data)
        if plan != nil || email != nil {
            vault.update(account.updating(email: email, plan: plan), provider: id)
        }
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: "primary"
        )
    }

    private func decorate(_ snapshot: ProviderSnapshot, extra: Bool) -> ProviderSnapshot {
        snapshot.labeled(from: account(), showsActivity: !extra)
    }

    private func wham(account: SavedAccount) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: ChatGPTOAuth.usageURL)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = account.vendorAccountId, !id.isEmpty {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// How long a rollout's own snapshot counts as current.
    ///
    /// Codex does not publish usage; it writes what it saw into a file as it
    /// runs. So the file stops changing the moment you stop using Codex, and
    /// reading it still succeeds instantly — the *fetch* is fresh while the
    /// *reading* may be days old. Every other provider here asks a server and
    /// gets today's answer, which is why only this one needs the distinction.
    static let currentFor: TimeInterval = 5 * 60

    static func status(recordedAt: Date?, now: Date = Date()) -> ProviderStatus {
        // No timestamp to judge by: say stale rather than claim currency we
        // cannot support.
        guard let recordedAt else { return .stale(since: .distantPast) }
        return now.timeIntervalSince(recordedAt) <= currentFor
            ? .ok
            : .stale(since: recordedAt)
    }

    /// Reads the last chunk of a file rather than all of it: rollouts grow
    /// without bound and only the most recent snapshot is wanted.
    private func tail(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw UsageProviderError.nothingMetered("Codex's rollout could not be read")
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shared access to Codex's local state.
enum CodexStore {
    static var stateURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite")
    }

    /// The desktop app's own thread catalogue.
    ///
    /// Codex's *rollouts* are written by the CLI and by the VS Code extension.
    /// The desktop app — ChatGPT.app, which is what most people mean by "Codex"
    /// now — writes none of them; it keeps its threads here instead, with
    /// `source_kind = 'chatgpt'`. Watching only the rollouts meant the notch
    /// could never see the desktop app working at all.
    static var desktopStoreURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sqlite/codex-dev.db")
    }

    /// The most recently touched desktop thread: when, and what it is called.
    static func newestDesktopThread(in url: URL) -> (title: String, updatedAt: Date)? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT source_updated_at, display_title, thread_id
            FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1
            """,
            columns: 3
        )
        guard let row = rows.first, let seconds = Double(row[0]) else { return nil }
        // Seconds since the epoch, with a fractional part — not the
        // milliseconds the `threads` table next door uses.
        let title = row[1].isEmpty ? "Codex" : row[1]
        return (title, Date(timeIntervalSince1970: seconds))
    }

    /// The rollout of the most recently touched thread.
    static func newestRollout(in store: URL) -> URL? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }

        let paths = SQLiteStore.rows(
            in: db,
            sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8"
        )
        return paths
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
