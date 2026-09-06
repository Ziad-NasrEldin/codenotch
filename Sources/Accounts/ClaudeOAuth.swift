import AppKit
import Foundation
import os

/// Claude Code's public OAuth client.
///
/// Extra Claude accounts have to be ours: the live slot still comes from
/// Claude Code's keychain, and writing a second login there would steal that
/// session. We listen on the registered loopback
/// (`http://localhost:54545/callback`) and never invent a redirect the client
/// does not already have. The token endpoint wants JSON, not a form body.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    static let redirectURI = "http://localhost:54545/callback"
    static let callbackHost = "localhost"
    static let callbackPort: UInt16 = 54545
    static let callbackPath = "/callback"
    static let scope = "org:create_api_key user:profile user:inference"

    static func login(session: URLSession = .shared) async throws -> SavedAccount {
        let pkce = PKCE.generate()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
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
        return try await exchange(code: code, state: state, verifier: pkce.verifier, session: session)
    }

    static func refresh(_ account: SavedAccount,
                        session: URLSession = .shared) async throws -> SavedAccount {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": account.refreshToken
        ], session: session, existing: account)
    }

    static func fresh(_ account: SavedAccount,
                      session: URLSession = .shared) async throws -> SavedAccount {
        guard account.needsRefresh else { return account }
        return try await refresh(account, session: session)
    }

    static func exchange(code: String, state: String, verifier: String,
                         session: URLSession) async throws -> SavedAccount {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
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
        let account = body["account"] as? [String: Any]
        return SavedAccount(
            id: UUID().uuidString,
            email: string(account?["email_address"])?.lowercased(),
            plan: nil,
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(max(60, lifetime) - 60),
            vendorAccountId: string(account?["uuid"]),
            addedAt: now
        )
    }

    private static func tokenRequest(_ pairs: [String: String],
                                     session: URLSession,
                                     existing: SavedAccount?) async throws -> SavedAccount {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: pairs)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.usage.error("claude token request failed: HTTP \(status)")
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
