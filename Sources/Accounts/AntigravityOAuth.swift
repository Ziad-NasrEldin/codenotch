import AppKit
import Foundation
import os

/// Antigravity's public desktop OAuth client.
///
/// Same bargain as ChatGPT: the live slot stays in Antigravity's own store,
/// extra logins live here, and the redirect is the one the client already
/// registers (`http://127.0.0.1:51121/callback`).
enum AntigravityOAuth {
    static let clientID = AntigravityCredentials.oauthClientID
    static let clientSecret = AntigravityCredentials.oauthClientSecret
    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    static let redirectURI = "http://127.0.0.1:51121/callback"
    static let callbackHost = "127.0.0.1"
    static let callbackPort: UInt16 = 51121
    static let callbackPath = "/callback"
    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs"
    ]

    static func login(session: URLSession = .shared) async throws -> SavedAccount {
        let pkce = PKCE.generate()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = components.url else { throw AccountLoginError.badRequest }

        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let code = try await OAuthLoopback.waitForCode(
            host: callbackHost,
            port: callbackPort,
            path: callbackPath,
            expectedState: state
        )
        var account = try await exchange(code: code, verifier: pkce.verifier, session: session)
        if let identity = try? await identity(accessToken: account.accessToken, session: session) {
            account = account.updating(email: identity.email, vendorAccountId: identity.id)
        }
        if account.plan == nil { account.plan = "Personal" }
        return account
    }

    static func refresh(_ account: SavedAccount,
                        session: URLSession = .shared) async throws -> SavedAccount {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": account.refreshToken
        ], session: session, existing: account)
    }

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
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ], session: session, existing: nil)
    }

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
            plan: "Personal",
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(max(60, lifetime) - 60),
            vendorAccountId: nil,
            addedAt: now
        )
    }

    static func identity(accessToken: String,
                         session: URLSession) async throws -> (email: String?, id: String?) {
        var request = URLRequest(url: userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AccountLoginError.exchangeFailed(status: 0) }
        return (string(body["email"])?.lowercased(), string(body["id"]))
    }

    static func identity(fromUserInfoJSON data: Data) -> (email: String?, id: String?) {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (string(body["email"])?.lowercased(), string(body["id"]))
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
            Log.usage.error("antigravity token request failed: HTTP \(status)")
            throw AccountLoginError.exchangeFailed(status: status)
        }
        var account = try self.account(fromTokenJSON: data, requireRefresh: existing == nil)
        if let existing {
            // Google often omits the refresh token on refresh.
            account = existing.updating(
                accessToken: account.accessToken,
                refreshToken: account.refreshToken.isEmpty ? existing.refreshToken : account.refreshToken,
                expiresAt: account.expiresAt,
                email: account.email,
                plan: account.plan ?? existing.plan,
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
