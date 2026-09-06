import Foundation
import Security

/// Extra accounts Codenotch owns, plus which one each provider is reading.
///
/// Secrets live in *our* keychain item, not Codex's or Antigravity's. The
/// active slot is a UserDefaults id (`live` or a saved account id), so switching
/// is a local choice and never a write into another app's login.
final class AccountVault: @unchecked Sendable {
    static let shared = AccountVault()
    static let liveID = AccountEntry.liveID

    private let lock = NSLock()
    private let store: RosterStore
    private let defaults: UserDefaults
    private enum Keys {
        static let active = "activeAccounts"
    }

    init(store: RosterStore = KeychainRosterStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func saved(for provider: String) -> [SavedAccount] {
        lock.lock(); defer { lock.unlock() }
        return store.load()[provider] ?? []
    }

    func activeID(for provider: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let map = defaults.dictionary(forKey: Keys.active) as? [String: String] ?? [:]
        return map[provider] ?? Self.liveID
    }

    func setActive(provider: String, id: String) {
        lock.lock()
        var map = defaults.dictionary(forKey: Keys.active) as? [String: String] ?? [:]
        map[provider] = id
        defaults.set(map, forKey: Keys.active)
        lock.unlock()
        notify()
    }

    /// The saved credential the ring should use, or nil when the live slot is
    /// selected (or the saved id is gone).
    func activeSaved(for provider: String) -> SavedAccount? {
        let id = activeID(for: provider)
        guard id != Self.liveID else { return nil }
        return saved(for: provider).first { $0.id == id }
    }

    /// What the ring should actually read.
    ///
    /// Live wins when it exists and is selected. A selected saved id that is
    /// gone, or a live selection with no borrowed login, falls through to the
    /// first saved extra so a machine without Codex/Antigravity installed can
    /// still show a Codenotch-held account.
    func resolvedSaved(for provider: String, hasLive: Bool) -> SavedAccount? {
        let list = saved(for: provider)
        let id = activeID(for: provider)
        if id != Self.liveID, let match = list.first(where: { $0.id == id }) {
            return match
        }
        if !hasLive { return list.first }
        return nil
    }

    /// Drop every extra login. Reset uses this; the borrowed live slots are
    /// someone else's and stay put.
    func clear() {
        lock.lock()
        store.save([:])
        defaults.removeObject(forKey: Keys.active)
        lock.unlock()
        notify()
    }

    func upsert(_ account: SavedAccount, provider: String) {
        lock.lock()
        var all = store.load()
        var list = all[provider] ?? []
        let active: String
        if let index = list.firstIndex(where: { $0.id == account.id
            || identitiesMatch($0, account) }) {
            let kept = list[index]
            list[index] = SavedAccount(
                id: kept.id,
                email: account.email ?? kept.email,
                plan: account.plan ?? kept.plan,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken.isEmpty ? kept.refreshToken : account.refreshToken,
                expiresAt: account.expiresAt,
                vendorAccountId: account.vendorAccountId ?? kept.vendorAccountId,
                addedAt: kept.addedAt
            )
            active = kept.id
        } else {
            list.append(account)
            active = account.id
        }
        all[provider] = list
        store.save(all)
        var map = defaults.dictionary(forKey: Keys.active) as? [String: String] ?? [:]
        map[provider] = active
        defaults.set(map, forKey: Keys.active)
        lock.unlock()
        notify()
    }

    func update(_ account: SavedAccount, provider: String) {
        lock.lock()
        var all = store.load()
        var list = all[provider] ?? []
        guard let index = list.firstIndex(where: { $0.id == account.id }) else {
            lock.unlock()
            return
        }
        list[index] = account
        all[provider] = list
        store.save(all)
        lock.unlock()
    }

    func remove(provider: String, id: String) {
        guard id != Self.liveID else { return }
        lock.lock()
        var all = store.load()
        all[provider] = (all[provider] ?? []).filter { $0.id != id }
        if all[provider]?.isEmpty == true { all[provider] = nil }
        store.save(all)
        var map = defaults.dictionary(forKey: Keys.active) as? [String: String] ?? [:]
        if map[provider] == id { map[provider] = Self.liveID }
        defaults.set(map, forKey: Keys.active)
        lock.unlock()
        notify()
    }

    /// Next slot, or nil when there is nothing to switch to.
    @discardableResult
    func cycle(provider: String, hasLive: Bool) -> String? {
        let ids = slots(provider: provider, hasLive: hasLive)
        guard ids.count > 1 else { return nil }
        let current = activeID(for: provider)
        let index = ids.firstIndex(of: current) ?? 0
        let next = ids[(index + 1) % ids.count]
        setActive(provider: provider, id: next)
        return next
    }

    func entries(provider: String, live: ProviderAccount?, hasLive: Bool) -> [AccountEntry] {
        let active = activeID(for: provider)
        var rows: [AccountEntry] = []
        if hasLive {
            rows.append(AccountEntry(
                id: Self.liveID,
                label: live?.label,
                plan: live?.plan,
                source: live?.source ?? "the owning tool",
                isLive: true,
                isActive: active == Self.liveID
            ))
        }
        for account in saved(for: provider) {
            rows.append(AccountEntry(
                id: account.id,
                label: account.email,
                plan: account.plan,
                source: "Codenotch",
                isLive: false,
                isActive: active == account.id
            ))
        }
        if !hasLive, active == Self.liveID, let first = rows.first {
            var copy = first
            copy.isActive = true
            rows[0] = copy
        }
        return rows
    }

    func canAddAccounts(provider: String) -> Bool {
        ClaudeProfile.isClaude(providerID: provider)
            || ["cursor", "codex", "gemini", "grok"].contains(provider)
    }

    func slots(provider: String, hasLive: Bool) -> [String] {
        (hasLive ? [Self.liveID] : []) + saved(for: provider).map(\.id)
    }

    private func identitiesMatch(_ existing: SavedAccount, _ incoming: SavedAccount) -> Bool {
        if let a = existing.vendorAccountId, let b = incoming.vendorAccountId, !a.isEmpty, a == b {
            return true
        }
        if let a = existing.email?.lowercased(), let b = incoming.email?.lowercased(), !a.isEmpty, a == b {
            return true
        }
        return false
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .accountRosterDidChange, object: nil)
        }
    }
}

protocol RosterStore: AnyObject {
    func load() -> [String: [SavedAccount]]
    func save(_ roster: [String: [SavedAccount]])
}

final class MemoryRosterStore: RosterStore {
    var roster: [String: [SavedAccount]] = [:]
    func load() -> [String: [SavedAccount]] { roster }
    func save(_ roster: [String: [SavedAccount]]) { self.roster = roster }
}

/// Our own item, so we can write it. Never Codex's or Antigravity's.
final class KeychainRosterStore: RosterStore {
    static let service = "com.vinz.codenotch.accounts"
    static let account = "roster"

    func load() -> [String: [SavedAccount]] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: [SavedAccount]].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ roster: [String: [SavedAccount]]) {
        // Encode failure must not write `{}` — that would wipe every extra
        // login because we could not serialise the new one.
        guard let data = try? JSONEncoder().encode(roster) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
