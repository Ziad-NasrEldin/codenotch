import Foundation

/// Form-urlencoded bodies for token endpoints.
///
/// `urlQueryAllowed` treats `+` as safe, and in a form body `+` is a space.
/// Refresh tokens can contain `+`; encoding it as a plus would mint a
/// different secret and the token endpoint would reject it.
enum OAuthForm {
    static func body(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}
