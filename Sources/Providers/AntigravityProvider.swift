import AppKit
import Foundation
import os

/// Gemini, as Antigravity sees it.
///
/// **What this can and cannot report, and why.** Antigravity talks to Google's
/// Cloud Code backend, and the only call that describes the account is
/// `:loadCodeAssist`. It answers with tiers — which plan you are on and which
/// you are not eligible for — and no numbers: no used, no limit, no reset. A
/// packet capture of a signed-in install showed exactly two RPCs, and neither
/// carries a quota.
///
/// So this provider reports the account honestly and says there is nothing
/// metered, rather than inventing a ring. That is the same answer Cursor's free
/// plan gets, and for the same reason: a confident 0% is worse than an admitted
/// blank, especially in something people pay for.
actor AntigravityProvider: UsageProvider {
    nonisolated let id = "gemini"
    // The id stays `gemini`: it keys the archive and the user's connection
    // choice, and changing it would silently discard both.
    nonisolated let displayName = "Antigravity"
    nonisolated let glyph = ProviderGlyph.antigravity

    /// Cloud Code hosts. `daily-` is the one that actually returns the live
    /// weekly fractions for a personal Antigravity account; production often
    /// answers 200 with every bucket at 1.0 (unused). Tried in this order.
    /// The language server is optional — OpenUsage gets the same percentages
    /// with the IDE closed, by refreshing the stored OAuth token and calling
    /// this RPC as User-Agent `antigravity`.
    private let cloudHosts = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    private let session: URLSession
    /// A second session, trusting loopback only, for the local language server.
    private let localSession: URLSession
    nonisolated private let vault: AccountVault
    /// Re-discovering the port and token means spawning `ps` and `lsof`, which
    /// is not something to do every minute. Cached until it stops working.
    private var bridge: AntigravityBridge.Endpoint?

    init(session: URLSession = .shared, vault: AccountVault = .shared) {
        self.session = session
        self.vault = vault
        self.localSession = URLSession(configuration: .ephemeral,
                                       delegate: LocalhostTrust(),
                                       delegateQueue: nil)
    }

    nonisolated var signInRoute: SignInRoute {
        // The VS Code-fork IDE is the app people actually run. The older
        // `Antigravity.app` is a different binary with a different credential
        // store; opening it from Settings is how "Allow access" appeared to
        // do nothing — it signed into the wrong product.
        if NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.antigravity-ide"
        ) != nil {
            return .openApp(bundleID: "com.google.antigravity-ide", name: "Antigravity IDE")
        }
        return .openApp(bundleID: "com.google.antigravity", name: "Antigravity")
    }

    nonisolated func forgetCachedCredential() { AntigravityCredentials.forgetCached() }

    nonisolated func liveAccount() -> ProviderAccount? {
        guard let credentials = try? AntigravityCredentials.load() else { return nil }
        return ProviderAccount(
            label: nil,   // the token carries no address
            plan: credentials.authMethod == "consumer" ? "Personal" : credentials.authMethod,
            source: credentials.source,
            manageURL: URL(string: "https://antigravity.google")
        )
    }

    nonisolated func account() -> ProviderAccount? {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return saved.asProviderAccount(manageURL: URL(string: "https://antigravity.google"))
        }
        return liveAccount()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let saved = vault.resolvedSaved(for: id, hasLive: liveAccount() != nil) {
            return decorate(try await savedReading(saved), extra: true)
        }

        let credentials = try AntigravityCredentials.load()
        // Expired is not signed out: we refresh the stored token ourselves
        // (same as OpenUsage). If that failed, the last reading is still true,
        // just old.
        if credentials.isExpired { throw UsageProviderError.credentialExpired }

        // Cloud Code first — it does not need Antigravity to be running.
        // The language server is a nicer source when it happens to be up,
        // not a requirement.
        if let windows = await cloudQuota(token: credentials.accessToken), !windows.isEmpty {
            return decorate(official(windows), extra: false)
        }
        if let windows = await localQuota(), !windows.isEmpty {
            return decorate(official(windows), extra: false)
        }
        throw UsageProviderError.nothingMetered("Antigravity did not return a quota")
    }

    private func official(_ windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                         fidelity: .official, status: .ok, windows: windows,
                         headlineID: "gemini-weekly")
    }

    private func decorate(_ snapshot: ProviderSnapshot, extra: Bool) -> ProviderSnapshot {
        snapshot.labeled(from: account(), showsActivity: !extra)
    }

    /// Cloud Code only. The language server is the live install's identity
    /// and would report the borrowed account, not this one.
    private func savedReading(_ account: SavedAccount) async throws -> ProviderSnapshot {
        var current = account
        do {
            current = try await AntigravityOAuth.fresh(current, session: session)
        } catch {
            if current.isExpired { throw UsageProviderError.credentialExpired }
        }
        if current != account { vault.update(current, provider: id) }

        if let windows = await cloudQuota(token: current.accessToken), !windows.isEmpty {
            return official(windows)
        }
        throw UsageProviderError.nothingMetered("Antigravity did not return a quota")
    }

    /// Ask Antigravity's language server, if it is running.
    ///
    /// Returns nil rather than throwing when it is not: Antigravity being
    /// closed is the ordinary case, not a fault, and the caller has an honest
    /// answer to fall back to.
    private func localQuota() async -> [LimitWindow]? {
        if let bridge, let windows = try? await AntigravityBridge.quota(
            from: bridge, session: localSession
        ), !windows.isEmpty {
            return windows
        }
        // Cached endpoint gone or never found: the port changes every time
        // Antigravity restarts, so a stale one is expected, not exceptional.
        guard let fresh = AntigravityBridge.discover() else {
            bridge = nil
            return nil
        }
        bridge = fresh
        return try? await AntigravityBridge.quota(from: fresh, session: localSession)
    }

    /// Ask Cloud Code for the quota summary. Empty body, User-Agent
    /// `antigravity` — anything else is 400 "Unknown name" or 403 "no valid
    /// license", which is how this used to silently degrade to a request count.
    private func cloudQuota(token: String) async -> [LimitWindow]? {
        for host in cloudHosts {
            guard let url = URL(string: host + "/v1internal:retrieveUserQuotaSummary") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 15
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { continue }
            let windows = Self.windows(in: data)
            if !windows.isEmpty { return windows }
        }
        return nil
    }

    /// Same parser as the language-server path: remaining-fraction groups.
    static func windows(in data: Data) -> [LimitWindow] {
        AntigravityBridge.windows(in: data)
    }

    /// The plan's display name, for the message the cell shows.
    static func tier(in data: Data) -> String {
        struct Response: Decodable {
            struct Tier: Decodable {
                let id: String?
                let name: String?
                let isDefault: Bool?
            }
            let allowedTiers: [Tier]?
            let currentTier: Tier?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return "Gemini"
        }
        // `currentTier` appears once a tier has been chosen; before that the
        // default among the allowed ones is what you are on.
        let tier = decoded.currentTier
            ?? decoded.allowedTiers?.first(where: { $0.isDefault == true })
            ?? decoded.allowedTiers?.first
        return tier?.name ?? "Gemini"
    }
}
