import AppKit
import Foundation

enum AccountLoginError: Error, Equatable {
    case unsupported
    case badRequest
    case missingToken
    case exchangeFailed(status: Int)
    case rejected
    case timedOut
}

/// The one place Settings goes to add a Codenotch-held login.
enum AccountLogin {
    static func add(provider: String, session: URLSession = .shared) async throws -> SavedAccount {
        if ClaudeProfile.isClaude(providerID: provider) {
            return try await ClaudeOAuth.login(session: session)
        }
        switch provider {
        case "cursor": return try await CursorOAuth.login(session: session)
        case "codex":  return try await ChatGPTOAuth.login(session: session)
        case "gemini": return try await AntigravityOAuth.login(session: session)
        case "grok":   return try await GrokOAuth.login(session: session)
        default:       throw AccountLoginError.unsupported
        }
    }

    static func fresh(_ account: SavedAccount,
                      provider: String,
                      session: URLSession) async throws -> SavedAccount {
        if ClaudeProfile.isClaude(providerID: provider) {
            return try await ClaudeOAuth.fresh(account, session: session)
        }
        switch provider {
        case "cursor": return try await CursorOAuth.fresh(account, session: session)
        case "codex":  return try await ChatGPTOAuth.fresh(account, session: session)
        case "gemini": return try await AntigravityOAuth.fresh(account, session: session)
        case "grok":   return try await GrokOAuth.fresh(account, session: session)
        default:       return account
        }
    }

    static func displayName(for provider: String) -> String {
        if ClaudeProfile.isClaude(providerID: provider) {
            return ClaudeProfile.slug(fromProviderID: provider)
                .map { "Claude (\($0))" } ?? "Claude"
        }
        switch provider {
        case "cursor": return "Cursor"
        case "codex":  return "Codex"
        case "gemini": return "Antigravity"
        case "grok":   return "Grok"
        default:       return provider
        }
    }

    @MainActor
    static func presentError(_ error: Error, provider: String) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        let name = displayName(for: provider)
        let alert = NSAlert()
        alert.messageText = "Could not add a \(name) account"
        alert.informativeText = message(for: error, name: name)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func message(for error: Error, name: String) -> String {
        switch error {
        case OAuthLoopbackError.portBusy(let port):
            return "Port \(port) is already in use — \(name) may already be signing in. Finish or cancel that login and try again."
        case OAuthLoopbackError.timedOut, AccountLoginError.timedOut:
            return "The browser sign-in timed out. Try Add account again."
        case OAuthLoopbackError.cancelled:
            return "The sign-in was cancelled."
        case OAuthLoopbackError.badCallback:
            return "The sign-in came back in a shape that was not understood. Try again."
        case AccountLoginError.exchangeFailed(let status):
            return "The token endpoint answered HTTP \(status)."
        case AccountLoginError.missingToken:
            return "The token endpoint did not return a refreshable login."
        case AccountLoginError.rejected:
            return "\(name) rejected the login. If the browser is already signed in to the live account, use a private window and pick the other one."
        default:
            return (error as NSError).localizedDescription
        }
    }
}
