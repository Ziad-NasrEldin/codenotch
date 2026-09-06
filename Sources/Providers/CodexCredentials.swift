import Foundation

/// Identity from `~/.codex/auth.json`.
///
/// Codex needs no credential to *read usage* — that comes from its rollout logs
/// — so this exists only to say whose readings these are. The address lives in
/// the id token's claims, which is a plain base64 payload; the signature is
/// never checked because nothing is being authorised, only labelled.
enum CodexCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = claims(inJWT: idToken)
        else { return nil }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return ProviderAccount(
            label: claims["email"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String,
            source: "Codex",
            manageURL: URL(string: "https://chatgpt.com/#settings/Account")
        )
    }

    static func email(inJWT token: String?) -> String? {
        guard let token, let claims = claims(inJWT: token) else { return nil }
        return nonempty((claims["email"] as? String)?.lowercased())
    }

    static func plan(inJWT token: String?) -> String? {
        guard let token, let claims = claims(inJWT: token) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return nonempty(auth?["chatgpt_plan_type"] as? String)
    }

    static func chatgptAccountId(inJWT token: String?) -> String? {
        guard let token, let claims = claims(inJWT: token) else { return nil }
        if let id = nonempty(claims["chatgpt_account_id"] as? String) { return id }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return nonempty(auth?["chatgpt_account_id"] as? String)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// The middle segment of a JWT, base64url-decoded. No verification: this is
    /// a label, not an authorisation.
    static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
