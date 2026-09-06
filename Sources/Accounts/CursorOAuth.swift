import AppKit
import Foundation
import os

/// Cursor's public Deep Control login.
///
/// Extra Cursor accounts cannot reuse the editor cookie
/// (`WorkosCursorSessionToken` on cursor.com) — that is the live slot, and
/// signing in through a WebView once created a second empty account. This
/// opens `loginDeepControl` and polls `api2.cursor.sh` until the browser
/// approves. There is no localhost callback.
enum CursorOAuth {
    static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
    static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!
    static let refreshURL = URL(string: "https://api2.cursor.sh/auth/exchange_user_api_key")!
    static let usageURL = URL(string: "https://api2.cursor.sh/api/usage/summary")!
    static let periodUsageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!

    static let pollAttempts = 150
    static let pollBaseDelay: TimeInterval = 1
    static let pollMaxDelay: TimeInterval = 10
    static let pollBackoff = 1.2

    static func login(session: URLSession = .shared) async throws -> SavedAccount {
        let pkce = PKCE.generate()
        let uuid = UUID().uuidString
        var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: pkce.challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli")
        ]
        guard let authURL = components.url else { throw AccountLoginError.badRequest }

        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let tokens = try await poll(uuid: uuid, verifier: pkce.verifier, session: session)
        return account(fromAccess: tokens.access, refresh: tokens.refresh)
    }

    static func refresh(_ account: SavedAccount,
                        session: URLSession = .shared) async throws -> SavedAccount {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.usage.error("cursor token refresh failed: HTTP \(status)")
            throw AccountLoginError.exchangeFailed(status: status)
        }
        let tokens = try tokens(fromJSON: data)
        return account.updating(
            accessToken: tokens.access,
            refreshToken: tokens.refresh ?? account.refreshToken,
            expiresAt: expiry(of: tokens.access),
            email: email(in: tokens.access) ?? account.email,
            vendorAccountId: identity(in: tokens.access) ?? account.vendorAccountId
        )
    }

    static func fresh(_ account: SavedAccount,
                      session: URLSession = .shared) async throws -> SavedAccount {
        guard account.needsRefresh else { return account }
        return try await refresh(account, session: session)
    }

    static func poll(uuid: String, verifier: String,
                     session: URLSession,
                     attempts: Int = pollAttempts,
                     baseDelay: TimeInterval = pollBaseDelay) async throws -> (access: String, refresh: String) {
        var delay = baseDelay
        var consecutiveErrors = 0
        for _ in 0..<attempts {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            var components = URLComponents(url: pollURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: verifier)
            ]
            guard let url = components.url else { throw AccountLoginError.badRequest }
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 404 {
                consecutiveErrors = 0
                delay = min(delay * pollBackoff, pollMaxDelay)
                continue
            }
            if (200..<300).contains(status) {
                let tokens = try tokens(fromJSON: data)
                guard let refresh = tokens.refresh, !refresh.isEmpty else {
                    throw AccountLoginError.missingToken
                }
                return (tokens.access, refresh)
            }
            if isTerminalPoll(status) { throw AccountLoginError.rejected }

            consecutiveErrors += 1
            if consecutiveErrors >= 3 { throw AccountLoginError.exchangeFailed(status: status) }
            delay = min(delay * pollBackoff, pollMaxDelay)
        }
        throw AccountLoginError.timedOut
    }

    static func isTerminalPoll(_ status: Int) -> Bool {
        status == 400 || status == 401 || status == 403 || status == 410
    }

    static func tokens(fromJSON data: Data) throws -> (access: String, refresh: String?) {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = string(body["accessToken"]) ?? string(body["access_token"]),
              !access.isEmpty
        else { throw AccountLoginError.missingToken }
        let refresh = string(body["refreshToken"]) ?? string(body["refresh_token"])
        return (access, refresh)
    }

    static func account(fromAccess access: String, refresh: String?,
                        now: Date = Date()) -> SavedAccount {
        SavedAccount(
            id: UUID().uuidString,
            email: email(in: access),
            plan: nil,
            accessToken: access,
            refreshToken: refresh ?? "",
            expiresAt: expiry(of: access, now: now),
            vendorAccountId: identity(in: access),
            addedAt: now
        )
    }

    static func email(in token: String) -> String? {
        CodexCredentials.email(inJWT: token)
    }

    static func identity(in token: String) -> String? {
        guard let claims = CodexCredentials.claims(inJWT: token) else { return nil }
        if let sub = claims["sub"] as? String, !sub.isEmpty { return sub }
        if let sub = claims["sub"] as? NSNumber { return sub.stringValue }
        return nil
    }

    static func expiry(of token: String, now: Date = Date()) -> Date {
        if let claims = CodexCredentials.claims(inJWT: token),
           let exp = claims["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: exp.doubleValue).addingTimeInterval(-5 * 60)
        }
        return now.addingTimeInterval(55 * 60)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
