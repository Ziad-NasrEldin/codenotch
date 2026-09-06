import CryptoKit
import Foundation

/// PKCE verifier + S256 challenge for the public vendor clients.
enum PKCE {
    static func generate() -> (verifier: String, challenge: String) {
        let verifier = base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, base64URL(Data(digest)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
