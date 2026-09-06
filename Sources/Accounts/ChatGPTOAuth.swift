import AppKit
import Foundation
import os

/// ChatGPT's public Codex client, the same one OpenCodex and `codex login` use.
///
/// Extra Codex accounts have to be ours: the live slot still comes from
/// `~/.codex/auth.json`, and writing a second login into that file would steal
/// the CLI's session. We listen on the registered loopback
/// (`http://localhost:1455/auth/callback`) and never invent a redirect the
/// client does not already have.
enum ChatGPTOAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let callbackHost = "localhost"
    static let callbackPort: UInt16 = 1455
    static let callbackPath = "/auth/callback"
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    static func login(session: URLSession = .shared) async throws -> SavedAccount {
        let pkce = PKCE.generate()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codenotch"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "prompt", value: "login")
        ]
        guard let authURL = components.url else { throw AccountLoginError.badRequest }

        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let code = try await OAuthLoopback.waitForCode(
            host: callbackHost,
            port: callbackPort,
            path: callbackPath,
            expectedState: state
        )
        return try await exchange(code: code, verifier: pkce.verifier, session: session)
    }

    static func refresh(_ account: SavedAccount,
                        session: URLSession = .shared) async throws -> SavedAccount {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": account.refreshToken
        ], session: session, existing: account)
    }

    /// Refresh only when the access token is close to dying.
    static func fresh(_ account: SavedAccount,
                      session: URLSession = .shared) async throws -> SavedAccount {
        guard account.needsRefresh else { return account }
        return try await refresh(account, session: session)
    }

    static func exchange(code: String, verifier: String,
                         session: URLSession) async throws -> SavedAccount {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ], session: session, existing: nil)
    }

    /// Split out so a recorded token JSON can be turned into a SavedAccount
    /// without hitting the network.
    static func account(fromTokenJSON data: Data, now: Date = Date(),
                        requireRefresh: Bool = true) throws -> SavedAccount {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = string(body["access_token"]), !access.isEmpty
        else { throw AccountLoginError.missingToken }
        let refresh = string(body["refresh_token"]) ?? ""
        if requireRefresh && refresh.isEmpty { throw AccountLoginError.missingToken }
        let lifetime = (body["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let idToken = string(body["id_token"])
        return SavedAccount(
            id: UUID().uuidString,
            email: CodexCredentials.email(inJWT: idToken) ?? CodexCredentials.email(inJWT: access),
            plan: CodexCredentials.plan(inJWT: idToken) ?? CodexCredentials.plan(inJWT: access),
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(max(60, lifetime) - 60),
            vendorAccountId: CodexCredentials.chatgptAccountId(inJWT: idToken)
                ?? CodexCredentials.chatgptAccountId(inJWT: access),
            addedAt: now
        )
    }

    private static func tokenRequest(_ pairs: [String: String],
                                     session: URLSession,
                                     existing: SavedAccount?) async throws -> SavedAccount {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthForm.body(pairs)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.usage.error("chatgpt token request failed: HTTP \(status)")
            throw AccountLoginError.exchangeFailed(status: status)
        }
        var account = try self.account(fromTokenJSON: data, requireRefresh: existing == nil)
        if let existing {
            account = existing.updating(
                accessToken: account.accessToken,
                refreshToken: account.refreshToken.isEmpty ? existing.refreshToken : account.refreshToken,
                expiresAt: account.expiresAt,
                email: account.email,
                plan: account.plan,
                vendorAccountId: account.vendorAccountId
            )
        }
        return account
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
