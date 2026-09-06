import Foundation

/// One extra login Codenotch itself holds, as opposed to the borrowed "live"
/// slot that still comes from the owning tool.
///
/// OpenCodex's roster is the model: a stable id, an email, and a refreshable
/// token. Switching here only changes what the notch *reads*. It never writes
/// the editor's or CLI's own store.
struct SavedAccount: Codable, Equatable, Identifiable {
    let id: String
    var email: String?
    var plan: String?
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// Vendor-stable account id. ChatGPT needs it as `ChatGPT-Account-Id`
    /// on WHAM; Google's userinfo `id` is the same idea.
    var vendorAccountId: String?
    var addedAt: Date

    var isExpired: Bool { expiresAt <= Date() }

    var needsRefresh: Bool {
        expiresAt.timeIntervalSinceNow <= 5 * 60
    }

    var summary: String {
        [email, plan.map { $0.capitalized }, "via Codenotch"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    func asProviderAccount(manageURL: URL?) -> ProviderAccount {
        ProviderAccount(label: email, plan: plan, source: "Codenotch", manageURL: manageURL)
    }

    func updating(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        email: String? = nil,
        plan: String? = nil,
        vendorAccountId: String? = nil
    ) -> SavedAccount {
        var copy = self
        if let accessToken { copy.accessToken = accessToken }
        if let refreshToken { copy.refreshToken = refreshToken }
        if let expiresAt { copy.expiresAt = expiresAt }
        if let email { copy.email = email }
        if let plan { copy.plan = plan }
        if let vendorAccountId { copy.vendorAccountId = vendorAccountId }
        return copy
    }
}

/// One row in Settings: the borrowed live login, or a saved extra.
struct AccountEntry: Identifiable, Equatable {
    static let liveID = "live"

    let id: String
    let label: String?
    let plan: String?
    let source: String
    let isLive: Bool
    var isActive: Bool

    var summary: String {
        [label, plan.map { $0.capitalized }, isLive ? "via \(source)" : "via Codenotch"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

extension Notification.Name {
    static let accountRosterDidChange = Notification.Name("CodenotchAccountRosterDidChange")
    /// Posted when an add-account attempt finishes, success or not, so the
    /// Settings button can leave "Waiting for browser…".
    static let accountLoginDidFinish = Notification.Name("CodenotchAccountLoginDidFinish")
}
