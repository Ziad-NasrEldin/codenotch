import AppKit
import Foundation
import os

/// Grok Build's public OIDC client.
///
/// Extra Grok accounts have to be ours: the live slot still comes from
/// `~/.grok/auth.json`, and writing a second login there would steal the CLI's
/// session. We listen on the registered loopback
/// (`http://127.0.0.1:56121/callback`) and never invent a redirect the client
/// does not already have.
enum GrokOAuth {
    static let clientID = GrokCredentials.defaultClientID
    static let discoveryURL = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
    static let fallbackAuthorizeURL = URL(string: "https://auth.x.ai/oauth2/auth")!
    static let fallbackTokenURL = GrokCredentials.refreshURL
    static let redirectURI = "http://127.0.0.1:56121/callback"
    static let callbackHost = "127.0.0.1"
    static let callbackPort: UInt16 = 56121
    static let callbackPath = "/callback"
    static let scope = "openid profile email offline_access grok-cli:access api:access"

    static func login(session: URLSession = .shared) async throws -> SavedAccount {
        let endpoints = await discover(session: session)
        let pkce = PKCE.generate()
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: UUID().uuidString),
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
        return try await exchange(code: code, verifier: pkce.verifier,
                                  tokenURL: endpoints.token, session: session)
    }

    static func refresh(_ account: SavedAccount,
                        session: URLSession = .shared) async throws -> SavedAccount {
        let tokenURL = await discover(session: session).token
        return try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": account.refreshToken
        ], tokenURL: tokenURL, session: session, existing: account)
    }

    static func fresh(_ account: SavedAccount,
                      session: URLSession = .shared) async throws -> SavedAccount {
        guard account.needsRefresh else { return account }
        return try await refresh(account, session: session)
    }

    static func exchange(code: String, verifier: String,
                         tokenURL: URL,
                         session: URLSession) async throws -> SavedAccount {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ], tokenURL: tokenURL, session: session, existing: nil)
    }

    static func discover(session: URLSession) async -> (authorize: URL, token: URL) {
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let endpoints = try? endpoints(fromDiscoveryJSON: data)
        else {
            return (fallbackAuthorizeURL, fallbackTokenURL)
        }
        return endpoints
    }

    static func endpoints(fromDiscoveryJSON data: Data) throws -> (authorize: URL, token: URL) {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authorize = validatedEndpoint(body["authorization_endpoint"]),
              let token = validatedEndpoint(body["token_endpoint"])
        else { throw AccountLoginError.badRequest }
        return (authorize, token)
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
            plan: nil,
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(max(60, lifetime) - 120),
            vendorAccountId: subject(inJWT: idToken) ?? subject(inJWT: access),
            addedAt: now
        )
    }

    static func subject(inJWT token: String?) -> String? {
        guard let token, let claims = CodexCredentials.claims(inJWT: token),
              let sub = claims["sub"] as? String
        else { return nil }
        let trimmed = sub.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenRequest(_ pairs: [String: String],
                                     tokenURL: URL,
                                     session: URLSession,
                                     existing: SavedAccount?) async throws -> SavedAccount {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthForm.body(pairs)
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.usage.error("grok token request failed: HTTP \(status)")
            throw AccountLoginError.exchangeFailed(status: status)
        }
        var account = try self.account(fromTokenJSON: data, requireRefresh: existing == nil)
        if let existing {
            account = existing.updating(
                accessToken: account.accessToken,
                refreshToken: account.refreshToken.isEmpty ? existing.refreshToken : account.refreshToken,
                expiresAt: account.expiresAt,
                email: account.email,
                vendorAccountId: account.vendorAccountId
            )
        }
        return account
    }

    private static func validatedEndpoint(_ value: Any?) -> URL? {
        guard let text = string(value), let url = URL(string: text) else { return nil }
        guard url.scheme?.lowercased() == "https" else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard host == "x.ai" || host.hasSuffix(".x.ai") else { return nil }
        return url
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
