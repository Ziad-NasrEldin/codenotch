import Foundation
import os

/// Reads Cursor usage as the account the *editor* is signed into, or as a
/// Codenotch-held Deep Control login when that slot is active.
///
/// The live path still borrows the editor cookie. Extra accounts must not:
/// signing into cursor.com inside the app once created a second, empty
/// account, so extras use Bearer tokens from `loginDeepControl` against
/// `api2.cursor.sh` instead.
actor CursorLocalProvider: UsageProvider {
    nonisolated let id = "cursor"
    nonisolated let displayName = "Cursor"
    nonisolated let glyph = ProviderGlyph.cursor

    private let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private let session: URLSession
    nonisolated private let storeURL: URL
    nonisolated private let vault: AccountVault

    init(session: URLSession = .shared,
         storeURL: URL = CursorCredentials.storeURL,
         vault: AccountVault = .shared) {
        self.session = session
        self.storeURL = storeURL
        self.vault = vault
    }

    nonisolated var signInRoute: SignInRoute { .openApp(bundleID: CursorCredentials.bundleID, name: "Cursor") }

    nonisolated func liveAccount() -> ProviderAccount? { CursorCredentials.account(from: storeURL) }

    nonisolated func account() -> ProviderAccount? {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return saved.asProviderAccount(manageURL: URL(string: "https://cursor.com/dashboard"))
        }
        return liveAccount()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return decorate(try await savedReading(saved), extra: true)
        }
        return decorate(try await liveReading(), extra: false)
    }

    private func liveReading() async throws -> ProviderSnapshot {
        // Re-read every time: the editor rotates this, and holding a stale copy
        // would mean signing ourselves out for no reason.
        let credentials = try CursorCredentials.load(from: storeURL)

        var request = URLRequest(url: endpoint)
        request.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("cursor usage -> \(body.prefix(900), privacy: .public)")

        return snapshot(windows: try CursorUsage.windows(fromJSON: body))
    }

    /// Bearer on api2. Must not fall back to the editor cookie: that belongs
    /// to the borrowed live login.
    private func savedReading(_ account: SavedAccount) async throws -> ProviderSnapshot {
        var current = account
        do {
            current = try await CursorOAuth.fresh(current, session: session)
        } catch {
            if current.isExpired { throw UsageProviderError.credentialExpired }
        }
        if current != account { vault.update(current, provider: id) }

        let first = try await extraUsage(token: current.accessToken)
        if first.status == 401 || first.status == 403 {
            let refreshed = try await CursorOAuth.refresh(current, session: session)
            vault.update(refreshed, provider: id)
            let retry = try await extraUsage(token: refreshed.accessToken)
            return try snapshot(fromExtra: retry)
        }
        return try snapshot(fromExtra: first)
    }

    private func extraUsage(token: String) async throws -> (data: Data, status: Int, period: Bool) {
        var request = URLRequest(url: CursorOAuth.usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return (data, status, false) }

        if status == 401 || status == 403 { return (data, status, false) }

        var period = URLRequest(url: CursorOAuth.periodUsageURL)
        period.httpMethod = "POST"
        period.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        period.setValue("application/json", forHTTPHeaderField: "Content-Type")
        period.setValue("application/json", forHTTPHeaderField: "Accept")
        period.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        period.httpBody = Data("{}".utf8)
        period.timeoutInterval = 15
        let (periodData, periodResponse) = try await session.data(for: period)
        return (periodData, (periodResponse as? HTTPURLResponse)?.statusCode ?? 0, true)
    }

    private func snapshot(fromExtra result: (data: Data, status: Int, period: Bool)) throws -> ProviderSnapshot {
        if result.status == 429 { throw UsageProviderError.rateLimited(retryAfter: 60) }
        if result.status == 401 || result.status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(result.status) else {
            throw UsageProviderError.badResponse(status: result.status)
        }
        let body = String(data: result.data, encoding: .utf8) ?? ""
        Log.usage.debug("cursor extra usage -> \(body.prefix(900), privacy: .public)")
        return snapshot(windows: try CursorUsage.windows(fromAnyJSON: body))
    }

    private func snapshot(windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "cursor_models"
        )
    }

    private func decorate(_ snapshot: ProviderSnapshot, extra: Bool) -> ProviderSnapshot {
        snapshot.labeled(from: account(), showsActivity: !extra)
    }
}
