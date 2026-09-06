import Foundation
import os
import Security
import SQLite3

/// The OAuth token Antigravity holds for a Google account.
///
/// Borrowed, like every other credential here — Antigravity signs in, this only
/// reads what it stored. There are three places it might live:
///
/// 1. **Antigravity IDE's** `state.vscdb` (`antigravityUnifiedStateSync.oauthToken`).
///    This is the VS Code-fork editor (`com.google.antigravity-ide`). The live
///    login lives here, as a protobuf map, and is what "Allow access…" has to
///    find. The keychain item is *not* this app's.
/// 2. **A file fallback** at `~/.gemini/jetski-standalone-oauth-token`. The
///    language server writes this when the keychain is slow or refused.
/// 3. **The login keychain**, service `gemini` / account `antigravity`, written
///    by the older `Antigravity.app` via Go's keyring package.
///
/// "Allow access…" used to only re-read (3). On a Mac that actually runs the
/// IDE, (3) is a stale token the old app last refreshed days ago, so granting
/// keychain access looks like it did nothing: the prompt succeeds, the token
/// is expired, and the notch stays disconnected. Reading (1) first, and
/// refreshing an expired access token with the stored refresh token the way
/// Antigravity itself does, is what makes the row connect.
struct AntigravityCredentials {
    let accessToken: String
    let expiresAt: Date
    /// `consumer` for a personal Google account; enterprise installs differ.
    let authMethod: String
    let refreshToken: String?
    /// Which store this was borrowed from, for the settings row.
    let source: String

    var isExpired: Bool { expiresAt <= Date() }

    static let service = "gemini"
    static let account = "antigravity"

    /// Held until it expires, for the reason spelled out in `CredentialCache`.
    private static let cache = CredentialCache<AntigravityCredentials> { $0.isExpired }

    static func forgetCached() { cache.forget() }

    /// Antigravity stores through Go's `keyring` package, which base64-encodes
    /// the payload behind this marker rather than writing raw JSON the way
    /// Claude Code does. Decoding it is not optional: without stripping the
    /// prefix the value is not JSON at all.
    private static let goKeyringPrefix = "go-keyring-base64:"

    /// Public desktop OAuth client embedded in Antigravity's own language
    /// server. Refreshing with it does not write anything back — the new
    /// access token lives only in this process, the same bargain as borrowing
    /// Claude Code's token without minting one.
    static let oauthClientID =
        "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let oauthClientSecret = "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"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static var ideStoreURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
            )
    }

    static var jetskiURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    }

    static func load() throws -> AntigravityCredentials {
        try cache.value(itemModifiedAt: newestStamp, reload: read)
    }

    private static func newestStamp() -> Date? {
        [
            fileStamp(ideStoreURL),
            fileStamp(jetskiURL),
            KeychainItem.modifiedAt(service: service, account: account)
        ].compactMap { $0 }.max()
    }

    private static func fileStamp(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func read() throws -> AntigravityCredentials {
        // IDE first: that is the app people actually run. The keychain item
        // belongs to the older Electron shell and is often days stale, which
        // is exactly the "Allow access does nothing" failure.
        let found = readIDE() ?? readJetski() ?? readKeychain()
        guard var credentials = found else { throw UsageProviderError.needsAuth }

        if credentials.isExpired, let refreshed = refresh(credentials) {
            credentials = refreshed
        }
        return credentials
    }

    private static func readIDE(from url: URL = ideStoreURL) -> AntigravityCredentials? {
        guard FileManager.default.fileExists(atPath: url.path),
              let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        guard let raw = SQLiteStore.rows(
            in: db,
            sql: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "antigravityUnifiedStateSync.oauthToken"
        ).first, let data = raw.data(using: .utf8) else { return nil }
        return decodeIDEToken(data)
    }

    private static func readJetski(from url: URL = jetskiURL) -> AntigravityCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // The file is raw JSON, not the go-keyring envelope.
        if let json = decodeJSON(data, source: "Antigravity") { return json }
        return decode(data)
    }

    private static func readKeychain() -> AntigravityCredentials? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            Log.usage.error("antigravity keychain read failed: OSStatus \(status)")
            return nil
        }
        return decode(data)
    }

    /// Split out so the decoding can be tested against a real stored value
    /// without a keychain.
    static func decode(_ data: Data) -> AntigravityCredentials? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix(goKeyringPrefix) {
            text = String(text.dropFirst(goKeyringPrefix.count))
        }
        let payload: Data
        if let nested = Data(base64Encoded: text) {
            payload = nested
        } else if let json = decodeJSON(Data(text.utf8), source: "Antigravity") {
            return json
        } else {
            return nil
        }
        return decodeJSON(payload, source: "Antigravity")
    }

    static func decodeJSON(_ data: Data, source: String) -> AntigravityCredentials? {
        struct Stored: Decodable {
            struct Token: Decodable {
                let access_token: String
                /// RFC 3339 with fractional seconds *and an offset* —
                /// "2026-08-31T21:53:49.575961+07:00". Not UTC, and not
                /// milliseconds since the epoch like Claude's. Parsing it as
                /// either is how a token that is live reads as long expired.
                let expiry: String
                let refresh_token: String?
            }
            let auth_method: String
            let token: Token
        }

        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let expiry = parse(stored.token.expiry)
        else { return nil }

        return AntigravityCredentials(
            accessToken: stored.token.access_token,
            expiresAt: expiry,
            authMethod: stored.auth_method,
            refreshToken: stored.token.refresh_token,
            source: source
        )
    }

    /// Antigravity IDE stores a protobuf map in `state.vscdb`, base64-wrapped
    /// twice: the sqlite value is base64 of a sentinel-key map, and the
    /// `oauthTokenInfoSentinelKey` entry is base64 of the token message.
    static func decodeIDEToken(_ data: Data) -> AntigravityCredentials? {
        let proto: Data
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: text) {
            proto = decoded
        } else {
            proto = data
        }
        return decodeIDEProtobuf(proto)
    }

    static func decodeIDEProtobuf(_ data: Data) -> AntigravityCredentials? {
        // repeated MapEntry { string key = 1; Wrapper value = 2 { bytes payload = 1 } }
        for entry in Proto.fields(data) where entry.field == 1 {
            guard case .bytes(let blob) = entry.payload else { continue }
            let inner = Proto.fields(blob)
            guard let key = inner.first(where: { $0.field == 1 })?.string,
                  key == "oauthTokenInfoSentinelKey",
                  let wrapper = inner.first(where: { $0.field == 2 })?.bytes
            else { continue }
            let payload = Proto.fields(wrapper).first(where: { $0.field == 1 })?.bytes
                ?? wrapper
            let tokenProto: Data
            if let text = String(data: payload, encoding: .utf8),
               let decoded = Data(base64Encoded: text) {
                tokenProto = decoded
            } else {
                tokenProto = payload
            }
            return decodeOAuthTokenInfo(tokenProto)
        }
        return nil
    }

    static func decodeOAuthTokenInfo(_ data: Data) -> AntigravityCredentials? {
        let fields = Proto.fields(data)
        guard let access = fields.first(where: { $0.field == 1 })?.string, !access.isEmpty
        else { return nil }
        let refresh = fields.first(where: { $0.field == 3 })?.string
        let expiry: Date
        if let stamp = fields.first(where: { $0.field == 4 }) {
            expiry = stamp.timestamp ?? Date.distantPast
        } else {
            expiry = Date.distantPast
        }
        return AntigravityCredentials(
            accessToken: access,
            expiresAt: expiry,
            authMethod: "consumer",
            refreshToken: refresh,
            source: "Antigravity IDE"
        )
    }

    /// Ask Google for a fresh access token. In-memory only: writing it back
    /// would race the editor for a credential we do not own.
    static func refresh(_ credentials: AntigravityCredentials,
                        session: URLSession = .shared) -> AntigravityCredentials? {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return nil
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": oauthClientID,
            "client_secret": oauthClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        request.timeoutInterval = 15

        guard let data = urlData(request, session: session),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String, !access.isEmpty
        else {
            Log.usage.error("antigravity token refresh failed")
            return nil
        }
        let lifetime = (body["expires_in"] as? Double) ?? 3600
        return AntigravityCredentials(
            accessToken: access,
            expiresAt: Date().addingTimeInterval(lifetime - 60),
            authMethod: credentials.authMethod,
            refreshToken: refreshToken,
            source: credentials.source
        )
    }

    /// `urlQueryAllowed` treats `+` as safe, and in a form body `+` is a space.
    /// Refresh tokens can contain `+`; encoding it as a plus would mint a
    /// different secret and Google would reject it.
    static func formBody(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func urlData(_ request: URLRequest, session: URLSession) -> Data? {
        let box = WaitBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.result = data
            if error != nil { box.result = nil }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                box.result = nil
            }
            box.done.signal()
        }
        task.resume()
        if box.done.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            return nil
        }
        return box.result
    }

    /// Fractional seconds are not optional in this field, but a formatter that
    /// demands them fails on a whole-second timestamp — so try both.
    static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

/// Tiny protobuf reader for the two Antigravity IDE messages we actually
/// need. Not a general decoder.
enum Proto {
    struct Field {
        let field: Int
        let payload: Payload
        var bytes: Data? {
            if case .bytes(let data) = payload { return data }
            return nil
        }
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
        var varint: UInt64? {
            if case .varint(let value) = payload { return value }
            return nil
        }
        /// `google.protobuf.Timestamp` (field 1 = seconds) or a raw varint.
        var timestamp: Date? {
            if let seconds = varint {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            guard let data = bytes else { return nil }
            if let seconds = fields(data).first(where: { $0.field == 1 })?.varint {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            return nil
        }
    }

    enum Payload {
        case varint(UInt64)
        case bytes(Data)
    }

    static func fields(_ data: Data) -> [Field] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Field] = []
        while i < bytes.count {
            guard let (key, afterKey) = varint(bytes, i) else { break }
            i = afterKey
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let (value, after) = varint(bytes, i) else { return out }
                i = after
                out.append(Field(field: field, payload: .varint(value)))
            case 2:
                guard let (length, after) = varint(bytes, i) else { return out }
                i = after
                let end = i + Int(length)
                guard end <= bytes.count else { return out }
                out.append(Field(field: field, payload: .bytes(Data(bytes[i..<end]))))
                i = end
            default:
                return out
            }
        }
        return out
    }

    private static func varint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var n: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            n |= UInt64(b & 0x7f) << shift
            if b < 0x80 { return (n, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

private final class WaitBox: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var result: Data?
}
