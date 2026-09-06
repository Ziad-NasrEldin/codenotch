import XCTest
@testable import Codenotch

final class AccountVaultTests: XCTestCase {
    private var defaults: UserDefaults!
    private var vault: AccountVault!

    override func setUp() {
        let name = "AccountVaultTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
    }

    func testTheLiveSlotIsTheDefault() {
        XCTAssertEqual(vault.activeID(for: "codex"), AccountVault.liveID)
        XCTAssertNil(vault.resolvedSaved(for: "codex", hasLive: true))
    }

    func testUpsertBecomesTheActiveReading() {
        let account = sample(id: "a", email: "a@b.c")
        vault.upsert(account, provider: "codex")
        XCTAssertEqual(vault.activeID(for: "codex"), "a")
        XCTAssertEqual(vault.resolvedSaved(for: "codex", hasLive: true)?.email, "a@b.c")
    }

    /// Signing in the same address again refreshes the tokens, it does not
    /// grow a second row — that is how a re-login looks like a duplicate.
    func testTheSameIdentityIsMerged() {
        vault.upsert(sample(id: "a", email: "a@b.c", vendor: "acct-1"), provider: "codex")
        vault.upsert(sample(id: "b", email: "a@b.c", vendor: "acct-1", token: "new"), provider: "codex")
        XCTAssertEqual(vault.saved(for: "codex").count, 1)
        XCTAssertEqual(vault.saved(for: "codex")[0].id, "a", "the original id is kept")
        XCTAssertEqual(vault.saved(for: "codex")[0].accessToken, "new")
    }

    func testRemovingTheActiveSlotFallsBackToLive() {
        vault.upsert(sample(id: "a", email: "a@b.c"), provider: "codex")
        vault.remove(provider: "codex", id: "a")
        XCTAssertEqual(vault.activeID(for: "codex"), AccountVault.liveID)
        XCTAssertTrue(vault.saved(for: "codex").isEmpty)
    }

    func testCycleWalksLiveThenSaved() {
        vault.upsert(sample(id: "a", email: "a@b.c"), provider: "codex")
        vault.upsert(sample(id: "b", email: "b@c.d"), provider: "codex")
        vault.setActive(provider: "codex", id: AccountVault.liveID)
        XCTAssertEqual(vault.cycle(provider: "codex", hasLive: true), "a")
        XCTAssertEqual(vault.cycle(provider: "codex", hasLive: true), "b")
        XCTAssertEqual(vault.cycle(provider: "codex", hasLive: true), AccountVault.liveID)
    }

    /// No Codex install, but a Codenotch-held login: read that rather than
    /// claiming there is nothing.
    func testALiveSelectionWithNoBorrowedLoginUsesTheFirstSaved() {
        vault.upsert(sample(id: "a", email: "a@b.c"), provider: "codex")
        vault.setActive(provider: "codex", id: AccountVault.liveID)
        XCTAssertEqual(vault.resolvedSaved(for: "codex", hasLive: false)?.id, "a")
        let rows = vault.entries(provider: "codex", live: nil, hasLive: false)
        XCTAssertTrue(rows[0].isActive)
    }

    func testClearDropsEveryExtraLogin() {
        vault.upsert(sample(id: "a", email: "a@b.c"), provider: "codex")
        vault.upsert(sample(id: "g", email: "g@g.com"), provider: "gemini")
        vault.clear()
        XCTAssertTrue(vault.saved(for: "codex").isEmpty)
        XCTAssertTrue(vault.saved(for: "gemini").isEmpty)
        XCTAssertEqual(vault.activeID(for: "codex"), AccountVault.liveID)
    }

    func testEveryProviderCanGrowARoster() {
        for id in ["claude", "cursor", "codex", "gemini", "grok"] {
            XCTAssertTrue(vault.canAddAccounts(provider: id), id)
        }
        XCTAssertFalse(vault.canAddAccounts(provider: "perplexity"))
    }

    private func sample(id: String, email: String, vendor: String? = nil,
                        token: String = "tok") -> SavedAccount {
        SavedAccount(id: id, email: email, plan: "plus", accessToken: token,
                     refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
                     vendorAccountId: vendor, addedAt: Date())
    }
}

final class OAuthHelperTests: XCTestCase {
    func testAFormBodyEncodesPlusRatherThanTreatingItAsASpace() {
        let body = String(data: OAuthForm.body(["refresh_token": "ab+cd/ef"]), encoding: .utf8)
        XCTAssertEqual(body, "refresh_token=ab%2Bcd%2Fef")
    }

    func testPKCEChallengeIsS256WithoutPadding() {
        let pair = PKCE.generate()
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge.count, 43)
        XCTAssertFalse(pair.challenge.contains("="))
        XCTAssertFalse(pair.challenge.contains("+"))
        XCTAssertFalse(pair.challenge.contains("/"))
    }

    func testTheLoopbackReadsAValidCallback() throws {
        let request = "GET /auth/callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertEqual(try OAuthLoopback.parseCode(from: request, path: "/auth/callback",
                                                   expectedState: "xyz"), "abc")
    }

    func testTheLoopbackRejectsAMismatchedState() {
        let request = "GET /auth/callback?code=abc&state=nope HTTP/1.1\r\n\r\n"
        XCTAssertThrowsError(try OAuthLoopback.parseCode(from: request, path: "/auth/callback",
                                                         expectedState: "xyz")) {
            XCTAssertEqual($0 as? OAuthLoopbackError, .badCallback)
        }
    }

    func testTheLoopbackRejectsTheWrongPath() {
        let request = "GET /other?code=abc&state=xyz HTTP/1.1\r\n\r\n"
        XCTAssertThrowsError(try OAuthLoopback.parseCode(from: request, path: "/auth/callback",
                                                         expectedState: "xyz"))
    }
}

final class ChatGPTOAuthParseTests: XCTestCase {
    func testATokenResponseBecomesASavedAccount() throws {
        let jwt = Self.jwt([
            "email": "A@B.C",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-9",
                "chatgpt_plan_type": "plus"
            ]
        ])
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,"id_token":"\(jwt)"}
        """
        let account = try ChatGPTOAuth.account(fromTokenJSON: Data(json.utf8),
                                               now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(account.email, "a@b.c")
        XCTAssertEqual(account.plan, "plus")
        XCTAssertEqual(account.vendorAccountId, "acct-9")
        XCTAssertEqual(account.accessToken, "at")
        XCTAssertEqual(account.refreshToken, "rt")
        XCTAssertEqual(account.expiresAt.timeIntervalSince1970, 1_000 + 3540, accuracy: 1)
    }

    func testARefreshResponseMayOmitTheRefreshToken() throws {
        let json = #"{"access_token":"new","expires_in":100}"#
        let account = try ChatGPTOAuth.account(fromTokenJSON: Data(json.utf8),
                                               requireRefresh: false)
        XCTAssertEqual(account.accessToken, "new")
        XCTAssertTrue(account.refreshToken.isEmpty)
    }

    func testALoginResponseWithoutARefreshTokenIsRefused() {
        let json = #"{"access_token":"at","expires_in":100}"#
        XCTAssertThrowsError(try ChatGPTOAuth.account(fromTokenJSON: Data(json.utf8)))
    }

    private static func jwt(_ payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return "\(b64(header)).\(b64(body)).sig"
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class AntigravityOAuthParseTests: XCTestCase {
    func testUserInfoSuppliesTheAddress() {
        let json = #"{"email":"Me@Gmail.com","id":"123"}"#
        let identity = AntigravityOAuth.identity(fromUserInfoJSON: Data(json.utf8))
        XCTAssertEqual(identity.email, "me@gmail.com")
        XCTAssertEqual(identity.id, "123")
    }
}

final class AntigravityRosterAccountTests: XCTestCase {
    func testASavedAccountIsWhatTheRingReads() {
        let name = "AntigravityRosterAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "g", email: "extra@g.com", plan: "Personal",
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: "123", addedAt: Date()),
                     provider: "gemini")
        let provider = AntigravityProvider(vault: vault)
        XCTAssertEqual(provider.account()?.label, "extra@g.com")
        XCTAssertEqual(provider.account()?.source, "Codenotch")
    }
}

final class CodexRosterAccountTests: XCTestCase {
    func testASavedAccountIsWhatTheRingReads() {
        let name = "CodexRosterAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "a", email: "extra@b.c", plan: "plus",
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: "acct", addedAt: Date()),
                     provider: "codex")
        let missing = URL(fileURLWithPath: "/tmp/no-codex-\(UUID().uuidString)")
        let provider = CodexLocalProvider(stateStore: missing, authURL: missing, vault: vault)
        XCTAssertEqual(provider.account()?.label, "extra@b.c")
        XCTAssertEqual(provider.account()?.source, "Codenotch")
        XCTAssertNil(provider.liveAccount())
    }

    func testTheLiveSlotIsReportedWhenNothingIsSaved() {
        let name = "CodexRosterAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        let missing = URL(fileURLWithPath: "/tmp/no-codex-\(UUID().uuidString)")
        let provider = CodexLocalProvider(stateStore: missing, authURL: missing, vault: vault)
        XCTAssertNil(provider.account())
        XCTAssertNil(provider.liveAccount())
    }
}

@MainActor
final class RosterStoreTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "codex"
        let displayName = "Codex"
        let glyph = ProviderGlyph.openai
        var live: ProviderAccount?
        var fetches = 0
        func liveAccount() -> ProviderAccount? { live }
        func account() -> ProviderAccount? { live }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            fetches += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: [])
        }
    }

    func testSummariesCarryTheRoster() {
        let name = "RosterStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "a", email: "extra@b.c", plan: "plus",
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: nil, addedAt: Date()),
                     provider: "codex")
        let stub = Stub()
        stub.live = ProviderAccount(label: "live@b.c", plan: "plus",
                                    source: "Codex", manageURL: nil)
        let archiveName = "RosterStoreTests.archive.\(UUID().uuidString)"
        let archiveDefaults = UserDefaults(suiteName: archiveName)!
        archiveDefaults.removePersistentDomain(forName: archiveName)
        let store = UsageStore(providers: [stub],
                               archive: UsageArchive(defaults: archiveDefaults),
                               vault: vault)
        let summary = store.providerSummaries[0]
        XCTAssertTrue(summary.canAddAccounts)
        XCTAssertEqual(summary.accounts.count, 2)
        XCTAssertEqual(summary.accounts[0].id, AccountEntry.liveID)
        XCTAssertTrue(summary.accounts[0].isLive)
        XCTAssertEqual(summary.accounts[1].label, "extra@b.c")
        XCTAssertFalse(summary.accounts[1].isLive)
        XCTAssertTrue(summary.accounts[1].isActive)
    }

    func testSelectingASavedAccountDropsThePreviousReading() {
        let name = "RosterStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "a", email: "extra@b.c", plan: nil,
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: nil, addedAt: Date()),
                     provider: "codex")
        vault.setActive(provider: "codex", id: AccountEntry.liveID)
        let archiveName = "RosterStoreTests.forget.\(UUID().uuidString)"
        let archiveDefaults = UserDefaults(suiteName: archiveName)!
        archiveDefaults.removePersistentDomain(forName: archiveName)
        let archive = UsageArchive(defaults: archiveDefaults)
        let remembered = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.8)]
        )
        archive.save(["codex": (remembered, Date())])
        let store = UsageStore(providers: [Stub()], archive: archive, vault: vault)
        XCTAssertTrue(store.snapshots[0].hasReading)
        store.selectAccount(providerID: "codex", accountID: "a")
        XCTAssertFalse(store.snapshots[0].hasReading, "the previous account's % must not linger")
        XCTAssertEqual(vault.activeID(for: "codex"), "a")
    }

    func testCyclingDropsThePreviousReading() {
        let name = "RosterStoreTests.cycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "a", email: "extra@b.c", plan: nil,
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: nil, addedAt: Date()),
                     provider: "codex")
        vault.setActive(provider: "codex", id: AccountEntry.liveID)
        let archiveName = "RosterStoreTests.cycle.archive.\(UUID().uuidString)"
        let archiveDefaults = UserDefaults(suiteName: archiveName)!
        archiveDefaults.removePersistentDomain(forName: archiveName)
        let archive = UsageArchive(defaults: archiveDefaults)
        archive.save(["codex": (ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.4)]
        ), Date())])
        let stub = Stub()
        stub.live = ProviderAccount(label: "live@b.c", plan: "plus",
                                    source: "Codex", manageURL: nil)
        let store = UsageStore(providers: [stub], archive: archive, vault: vault)
        XCTAssertTrue(store.cycleAccount(providerID: "codex"))
        XCTAssertFalse(store.snapshots[0].hasReading)
        XCTAssertEqual(vault.activeID(for: "codex"), "a")
    }

    func testSelectingASavedAccountIsWhatTheVaultRemembers() {
        let name = "RosterStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "a", email: "extra@b.c", plan: nil,
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: nil, addedAt: Date()),
                     provider: "codex")
        vault.setActive(provider: "codex", id: AccountEntry.liveID)
        let archiveName = "RosterStoreTests.archive.\(UUID().uuidString)"
        let archiveDefaults = UserDefaults(suiteName: archiveName)!
        archiveDefaults.removePersistentDomain(forName: archiveName)
        let store = UsageStore(providers: [Stub()],
                               archive: UsageArchive(defaults: archiveDefaults),
                               vault: vault)
        store.selectAccount(providerID: "codex", accountID: "a")
        XCTAssertEqual(vault.activeID(for: "codex"), "a")
    }
}

final class AccountLoginCopyTests: XCTestCase {
    func testABusyPortNamesTheAppThatOwnsIt() {
        let text = AccountLogin.message(for: OAuthLoopbackError.portBusy(1455), name: "Codex")
        XCTAssertTrue(text.contains("1455"))
        XCTAssertTrue(text.contains("Codex"))
    }

    func testDisplayNamesCoverEveryProvider() {
        XCTAssertEqual(AccountLogin.displayName(for: "claude"), "Claude")
        XCTAssertEqual(AccountLogin.displayName(for: "cursor"), "Cursor")
        XCTAssertEqual(AccountLogin.displayName(for: "codex"), "Codex")
        XCTAssertEqual(AccountLogin.displayName(for: "gemini"), "Antigravity")
        XCTAssertEqual(AccountLogin.displayName(for: "grok"), "Grok")
    }
}

final class ClaudeOAuthParseTests: XCTestCase {
    func testATokenResponseBecomesASavedAccount() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "account":{"uuid":"acct-claude","email_address":"Me@X.com"}}
        """
        let account = try ClaudeOAuth.account(fromTokenJSON: Data(json.utf8),
                                              now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(account.email, "me@x.com")
        XCTAssertEqual(account.vendorAccountId, "acct-claude")
        XCTAssertEqual(account.accessToken, "at")
        XCTAssertEqual(account.refreshToken, "rt")
        XCTAssertEqual(account.expiresAt.timeIntervalSince1970, 1_000 + 3540, accuracy: 1)
    }

    func testALoginResponseWithoutARefreshTokenIsRefused() {
        let json = #"{"access_token":"at","expires_in":100}"#
        XCTAssertThrowsError(try ClaudeOAuth.account(fromTokenJSON: Data(json.utf8)))
    }
}

final class CursorOAuthParseTests: XCTestCase {
    func testPollJSONSuppliesBothTokens() throws {
        let json = #"{"accessToken":"at","refreshToken":"rt"}"#
        let tokens = try CursorOAuth.tokens(fromJSON: Data(json.utf8))
        XCTAssertEqual(tokens.access, "at")
        XCTAssertEqual(tokens.refresh, "rt")
    }

    func testIdentityComesFromTheJWT() {
        let jwt = Self.jwt(["sub": "user-9", "email": "Me@Cursor.com", "exp": 2_000])
        let account = CursorOAuth.account(fromAccess: jwt, refresh: "rt",
                                          now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(account.email, "me@cursor.com")
        XCTAssertEqual(account.vendorAccountId, "user-9")
        XCTAssertEqual(account.expiresAt.timeIntervalSince1970, 2_000 - 300, accuracy: 1)
    }

    func testTerminalPollStatusesAreNotRetried() {
        XCTAssertTrue(CursorOAuth.isTerminalPoll(400))
        XCTAssertTrue(CursorOAuth.isTerminalPoll(410))
        XCTAssertFalse(CursorOAuth.isTerminalPoll(404))
        XCTAssertFalse(CursorOAuth.isTerminalPoll(500))
    }

    private static func jwt(_ payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return "\(b64(header)).\(b64(body)).sig"
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class GrokOAuthParseTests: XCTestCase {
    func testDiscoveryAcceptsXAIHosts() throws {
        let json = """
        {"authorization_endpoint":"https://auth.x.ai/oauth/authorize",
         "token_endpoint":"https://auth.x.ai/oauth2/token"}
        """
        let endpoints = try GrokOAuth.endpoints(fromDiscoveryJSON: Data(json.utf8))
        XCTAssertEqual(endpoints.authorize.host, "auth.x.ai")
        XCTAssertEqual(endpoints.token.path, "/oauth2/token")
    }

    func testDiscoveryRejectsAForeignHost() {
        let json = """
        {"authorization_endpoint":"https://evil.example/oauth",
         "token_endpoint":"https://auth.x.ai/oauth2/token"}
        """
        XCTAssertThrowsError(try GrokOAuth.endpoints(fromDiscoveryJSON: Data(json.utf8)))
    }

    func testATokenResponseBecomesASavedAccount() throws {
        let jwt = Self.jwt(["sub": "xai-1", "email": "Me@X.AI"])
        let json = """
        {"access_token":"\(jwt)","refresh_token":"rt","expires_in":3600,"id_token":"\(jwt)"}
        """
        let account = try GrokOAuth.account(fromTokenJSON: Data(json.utf8),
                                            now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(account.email, "me@x.ai")
        XCTAssertEqual(account.vendorAccountId, "xai-1")
        XCTAssertEqual(account.refreshToken, "rt")
    }

    private static func jwt(_ payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return "\(b64(header)).\(b64(body)).sig"
    }

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class ClaudeRosterAccountTests: XCTestCase {
    func testASavedAccountIsWhatTheRingReads() {
        let name = "ClaudeRosterAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "c", email: "extra@c.com", plan: "pro",
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: "uuid", addedAt: Date()),
                     provider: "claude")
        let provider = ClaudeOAuthProvider(vault: vault)
        XCTAssertEqual(provider.account()?.label, "extra@c.com")
        XCTAssertEqual(provider.account()?.source, "Codenotch")
    }
}

final class CursorRosterAccountTests: XCTestCase {
    func testASavedAccountIsWhatTheRingReads() {
        let name = "CursorRosterAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "u", email: "extra@cursor.com", plan: nil,
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: "sub", addedAt: Date()),
                     provider: "cursor")
        let missing = URL(fileURLWithPath: "/tmp/no-cursor-\(UUID().uuidString).vscdb")
        let provider = CursorLocalProvider(storeURL: missing, vault: vault)
        XCTAssertEqual(provider.account()?.label, "extra@cursor.com")
        XCTAssertEqual(provider.account()?.source, "Codenotch")
        XCTAssertNil(provider.liveAccount())
    }
}

final class GrokRosterAccountTests: XCTestCase {
    func testASavedAccountIsWhatTheRingReads() {
        let name = "GrokRosterAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let vault = AccountVault(store: MemoryRosterStore(), defaults: defaults)
        vault.upsert(SavedAccount(id: "g", email: "extra@x.ai", plan: nil,
                                  accessToken: "at", refreshToken: "rt",
                                  expiresAt: Date().addingTimeInterval(3600),
                                  vendorAccountId: "sub", addedAt: Date()),
                     provider: "grok")
        let missing = URL(fileURLWithPath: "/tmp/no-grok-\(UUID().uuidString).json")
        let provider = GrokProvider(authURL: missing, vault: vault)
        XCTAssertEqual(provider.account()?.label, "extra@x.ai")
        XCTAssertEqual(provider.account()?.source, "Codenotch")
        XCTAssertNil(provider.liveAccount())
    }
}

@MainActor
final class ExtraAccountActivityTests: XCTestCase {
    func testActivityIsHiddenWhenTheSnapshotSaysSo() {
        let model = NotchViewModel()
        model.sessions = ["codex": [
            AgentSession(id: "s", name: "Codex", detail: "repo", state: .busy,
                         waitingFor: nil, since: Date())
        ]]
        model.snapshots = [
            ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
                             fidelity: .official, status: .ok, windows: [],
                             showsActivity: false)
        ]
        XCTAssertNil(model.activity(for: "codex"))
    }
}
