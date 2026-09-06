import Foundation
import os

/// The login Grok Build keeps in `~/.grok/auth.json`.
///
/// Borrowed, like every other credential here — `grok login` writes the file,
/// this only reads it. Refreshing an expired access token is done in memory
/// and never written back: minting one into Grok's own file would race the
/// CLI for a credential this app does not own, the same bargain as
/// Antigravity's Google refresh.
struct GrokCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let email: String?
    let clientID: String
    let source: String

    /// Public OIDC client embedded in the Grok CLI. Used when an auth entry
    /// does not name its own `oidc_client_id`.
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    /// Refresh this far before expiry, so a fetch never walks into a 401
    /// that was avoidable.
    static let refreshBuffer: TimeInterval = 5 * 60

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= Self.refreshBuffer
    }

    static var homeURL: URL {
        if let raw = ProcessInfo.processInfo.environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok")
    }

    static var authURL: URL { homeURL.appendingPathComponent("auth.json") }

    /// The plan name from `/v1/settings`, remembered so the settings row can
    /// show it without another network round-trip. Email still comes from the
    /// file — that is local and does not go stale the same way.
    private static let planLock = NSLock()
    private static var cachedPlan: String?

    static func rememberPlan(_ plan: String?) {
        planLock.lock()
        cachedPlan = plan
        planLock.unlock()
    }

    static func rememberedPlan() -> String? {
        planLock.lock()
        defer { planLock.unlock() }
        return cachedPlan
    }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let credentials = try? load(from: url) else { return nil }
        return ProviderAccount(
            label: credentials.email,
            plan: rememberedPlan(),
            source: "Grok Build",
            manageURL: URL(string: "https://grok.com/?_s=usage")
        )
    }

    static func load(from url: URL = authURL) throws -> GrokCredentials {
        guard let first = try loadAll(from: url).first else {
            throw UsageProviderError.needsAuth
        }
        return first
    }

    /// Every keyed entry. Grok can store more than one account in the same
    /// file; the caller tries them in order.
    static func loadAll(from url: URL = authURL) throws -> [GrokCredentials] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageProviderError.needsAuth
        }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw UsageProviderError.needsAuth
        }

        let candidates = root.compactMap { key, value -> GrokCredentials? in
            decode(entryKey: key, value: value)
        }
        guard !candidates.isEmpty else { throw UsageProviderError.needsAuth }

        // Unexpired first, so a leftover expired entry next to a live one
        // does not make the notch demand `grok login` for no reason.
        return candidates.sorted { a, b in
            switch (a.isExpired, b.isExpired) {
            case (false, true): return true
            case (true, false): return false
            default: return false
            }
        }
    }

    static func decode(entryKey: String, value: Any) -> GrokCredentials? {
        guard let entry = value as? [String: Any],
              let token = trimmed(entry["key"] as? String)
        else { return nil }

        let refresh = trimmed(entry["refresh_token"] as? String)
            ?? trimmed(entry["refresh"] as? String)
        let fileExpiry = date(entry["expires_at"] as? String)
            ?? date(entry["expires"] as? String)
        let jwtExpiry = jwtExpiration(token)
        let expiresAt: Date?
        switch (fileExpiry, jwtExpiry) {
        case let (file?, jwt?): expiresAt = min(file, jwt)
        case let (file?, nil):  expiresAt = file
        case let (nil, jwt?):   expiresAt = jwt
        case (nil, nil):        expiresAt = nil
        }

        let oidc = trimmed(entry["oidc_client_id"] as? String)
        let fromKey = entryKey.split(separator: "::").last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let clientID = [oidc, fromKey].compactMap { $0 }.first { !$0.isEmpty }
            ?? defaultClientID

        return GrokCredentials(
            accessToken: token,
            refreshToken: refresh,
            expiresAt: expiresAt,
            email: trimmed(entry["email"] as? String),
            clientID: clientID,
            source: "Grok Build"
        )
    }

    /// Ask auth.x.ai for a fresh access token. In-memory only.
    static func refresh(_ credentials: GrokCredentials,
                        session: URLSession) async -> GrokCredentials? {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return nil
        }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": credentials.clientID,
            "refresh_token": refreshToken
        ])
        request.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = trimmed(body["access_token"] as? String)
        else {
            Log.usage.error("grok token refresh failed")
            return nil
        }

        let newRefresh = trimmed(body["refresh_token"] as? String) ?? refreshToken
        let lifetime = (body["expires_in"] as? NSNumber)?.doubleValue
        let expiresAt: Date
        if let lifetime, lifetime.isFinite, lifetime > 0 {
            expiresAt = Date().addingTimeInterval(lifetime)
        } else if let jwt = jwtExpiration(access) {
            expiresAt = jwt
        } else {
            expiresAt = Date().addingTimeInterval(60 * 60)
        }

        return GrokCredentials(
            accessToken: access,
            refreshToken: newRefresh,
            expiresAt: expiresAt,
            email: credentials.email,
            clientID: credentials.clientID,
            source: credentials.source
        )
    }

    /// `urlQueryAllowed` treats `+` as safe, and in a form body `+` is a space.
    /// Refresh tokens can contain `+`; encoding it as a plus would mint a
    /// different secret and the token endpoint would reject it.
    static func formBody(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    /// The `exp` claim, unverified — a label of when the token *says* it dies,
    /// not an authorisation.
    static func jwtExpiration(_ token: String) -> Date? {
        guard let claims = CodexCredentials.claims(inJWT: token),
              let exp = claims["exp"] as? NSNumber
        else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// Apple's `ISO8601DateFormatter` rejects more than three fractional
    /// digits, and Grok writes six. Truncate rather than fail: the extra
    /// microseconds never matter for "is this token still good".
    static func date(_ value: String?) -> Date? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        text = clipFractionalSeconds(text)

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func clipFractionalSeconds(_ value: String) -> String {
        guard let range = value.range(of: "\\.\\d+", options: .regularExpression) else {
            return value
        }
        var digits = value[range].dropFirst()
        if digits.count > 3 { digits = digits.prefix(3) }
        while digits.count < 3 { digits.append("0") }
        return value.replacingCharacters(in: range, with: ".\(digits)")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
