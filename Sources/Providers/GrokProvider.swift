import Foundation
import os

/// Grok Build usage, as the Grok CLI itself reports it.
///
/// Reads `~/.grok/auth.json` — the file `grok login` writes — and calls
/// `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, the same
/// endpoint the CLI uses for its own billing panel. The numbers are Grok's, so
/// this is `.official`.
///
/// The headline is the weekly shared pool. Pay-as-you-go is a second tooltip
/// row only when a cap is actually set; a disabled cap is not a meter.
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok"
    nonisolated let glyph = ProviderGlyph.grok

    private let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    /// The CLI identifies itself this way; the proxy 401s without it.
    static let tokenAuthHeader = "xai-grok-cli"

    private let session: URLSession
    private nonisolated let authURL: URL
    nonisolated private let vault: AccountVault

    init(session: URLSession = .shared,
         authURL: URL = GrokCredentials.authURL,
         vault: AccountVault = .shared) {
        self.session = session
        self.authURL = authURL
        self.vault = vault
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Run grok login once — Grok Build signs in and this reads the same login.")
    }

    nonisolated func liveAccount() -> ProviderAccount? { GrokCredentials.account(from: authURL) }

    nonisolated func account() -> ProviderAccount? {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return saved.asProviderAccount(manageURL: URL(string: "https://grok.com/?_s=usage"))
        }
        return liveAccount()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return decorate(try await savedReading(saved), extra: true)
        }

        var credentials = try GrokCredentials.load(from: authURL)

        if credentials.needsRefresh {
            if let refreshed = await GrokCredentials.refresh(credentials, session: session) {
                credentials = refreshed
            } else if credentials.isExpired {
                throw UsageProviderError.credentialExpired
            }
        }

        return decorate(try await fetch(token: credentials.accessToken,
                                        refresh: {
                                            await GrokCredentials.refresh(credentials, session: session)?.accessToken
                                        },
                                        expired: credentials.isExpired),
                        extra: false)
    }

    /// Same billing URL, but the token lives in the vault. Never writes
    /// `~/.grok/auth.json`.
    private func savedReading(_ account: SavedAccount) async throws -> ProviderSnapshot {
        var current = account
        do {
            current = try await GrokOAuth.fresh(current, session: session)
        } catch {
            if current.isExpired { throw UsageProviderError.credentialExpired }
        }
        if current != account { vault.update(current, provider: id) }

        return try await fetch(token: current.accessToken,
                               refresh: {
                                   let refreshed = try? await GrokOAuth.refresh(current, session: session)
                                   if let refreshed {
                                       vault.update(refreshed, provider: id)
                                       return refreshed.accessToken
                                   }
                                   return nil
                               },
                               expired: current.isExpired)
    }

    private func fetch(token: String,
                       refresh: () async -> String?,
                       expired: Bool,
                       retryingOnUnauthorized: Bool = true) async throws -> ProviderSnapshot {
        var request = URLRequest(url: creditsURL)
        applyAuth(&request, token: token)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 {
            guard retryingOnUnauthorized, let next = await refresh() else {
                throw expired
                    ? UsageProviderError.credentialExpired
                    : UsageProviderError.needsAuth
            }
            return try await fetch(token: next, refresh: { nil }, expired: expired,
                                   retryingOnUnauthorized: false)
        }
        if status == 429 {
            let retry = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageProviderError.rateLimited(retryAfter: retry ?? 0)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("grok usage -> \(body.prefix(900), privacy: .public)")

        let windows = try GrokUsage.windows(fromJSON: body)
        if let plan = await fetchPlan(token: token) {
            GrokCredentials.rememberPlan(plan)
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "weekly"
        )
    }

    private func decorate(_ snapshot: ProviderSnapshot, extra: Bool) -> ProviderSnapshot {
        snapshot.labeled(from: account(), showsActivity: !extra)
    }

    private func fetchPlan(token: String) async -> String? {
        var request = URLRequest(url: settingsURL)
        applyAuth(&request, token: token)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return GrokUsage.planName(from: data)
    }

    private func applyAuth(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.tokenAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
    }
}
