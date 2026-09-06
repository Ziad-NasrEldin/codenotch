import XCTest
@testable import Codenotch

/// Pinned to a response recorded live from `cli-chat-proxy.grok.com` on
/// 2026-09-06. `/v1/billing?format=credits` is not a documented API, so this
/// is what fails first if it changes.
final class GrokUsageTests: XCTestCase {
    /// Verbatim, from a SuperGrok Heavy account mid-week. Includes fields we
    /// do not map (`productUsage`, prepaid balance, top-up method), which
    /// exercises unknown-field tolerance on a genuine payload.
    private let recorded = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-08-30T18:22:54.007137+00:00","end":"2026-09-06T18:22:54.007137+00:00"},\
    "creditUsagePercent":67.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},\
    "productUsage":[{"product":"GrokBuild","usagePercent":67.0}],\
    "isUnifiedBillingUser":true,"prepaidBalance":{"val":0},\
    "topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-08-30T18:22:54.007137+00:00",\
    "billingPeriodEnd":"2026-09-06T18:22:54.007137+00:00"}}
    """

    /// An earlier capture (OpenUsage, 2026-07-06). The decoder has to keep
    /// reading this shape too: proto-JSON grows fields, it does not replace them.
    private let earlier = """
    {"config":{"creditUsagePercent":99.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-06-30T21:36:52.140114+00:00","end":"2026-07-07T21:36:52.140114+00:00"},\
    "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true,\
    "prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-06-30T21:36:52.140114+00:00",\
    "billingPeriodEnd":"2026-07-07T21:36:52.140114+00:00"}}
    """

    func testReadsTheLiveCapturedResponse() throws {
        let w = try GrokUsage.windows(fromJSON: recorded)
        XCTAssertEqual(w.map(\.id), ["weekly"])
        XCTAssertEqual(w[0].label, "Weekly limit")
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.67, accuracy: 0.0001)
        XCTAssertEqual(w[0].summary, "67% Used · 33% left")
    }

    func testResetComesFromThePeriodEnd() throws {
        let reset = try XCTUnwrap(GrokUsage.windows(fromJSON: recorded)[0].resetsAt)
        let expected = try XCTUnwrap(GrokCredentials.date("2026-09-06T18:22:54.007137+00:00"))
        XCTAssertEqual(reset.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testStillReadsTheEarlierCapture() throws {
        let w = try GrokUsage.windows(fromJSON: earlier)
        XCTAssertEqual(w[0].usedFraction ?? -1, 0.99, accuracy: 0.0001)
    }

    /// proto-JSON drops zero-valued fields: a fresh weekly period omits
    /// `creditUsagePercent`. That is a genuine 0%, never a schema error.
    func testAnAbsentPercentIsZero() throws {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-08-30T18:22:54.007Z","end":"2026-09-06T18:22:54.007Z"}}}
        """
        XCTAssertEqual(try GrokUsage.windows(fromJSON: json)[0].usedFraction ?? -1, 0, accuracy: 0.0001)
    }

    /// A present but non-numeric value is a schema change, not a 0.
    func testANonNumericPercentIsRejected() {
        let json = """
        {"config":{"creditUsagePercent":"high","currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-08-30T18:22:54.007Z","end":"2026-09-06T18:22:54.007Z"}}}
        """
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: json))
    }

    /// An account still on monthly billing has no weekly pool. Mislabeling
    /// its monthly percent as weekly would be worse than an honest blank.
    func testAMonthlyPeriodIsNothingMetered() {
        let json = """
        {"config":{"creditUsagePercent":40,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY",\
        "start":"2026-08-01T00:00:00Z","end":"2026-09-01T00:00:00Z"}}}
        """
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: json)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testPayAsYouGoOnlyCountsWhenACeilingIsSet() throws {
        let on = """
        {"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-08-30T18:22:54.007Z","end":"2026-09-06T18:22:54.007Z"},\
        "onDemandCap":{"val":2500},"onDemandUsed":{"val":250}}}
        """
        let w = try GrokUsage.windows(fromJSON: on)
        XCTAssertEqual(w.map(\.id), ["weekly", "on_demand"])
        XCTAssertEqual(w[1].usedFraction ?? -1, 0.10, accuracy: 0.0001)
        XCTAssertEqual(w[1].label, "Extra usage")
    }

    func testAZeroCapIsOmittedRatherThanShownAsEmpty() throws {
        XCTAssertEqual(try GrokUsage.windows(fromJSON: recorded).map(\.id), ["weekly"])
    }

    func testAPresentNonObjectCapIsRejected() {
        let json = """
        {"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-08-30T18:22:54.007Z","end":"2026-09-06T18:22:54.007Z"},\
        "onDemandCap":"lots"}}
        """
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: json))
    }

    func testRejectsRubbish() {
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: "not json"))
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: "{}"))
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: #"{"config":{}}"#))
    }

    func testAPeriodThatDoesNotMoveForwardIsRejected() {
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
        "start":"2026-09-06T18:22:54.007Z","end":"2026-08-30T18:22:54.007Z"}}}
        """
        XCTAssertThrowsError(try GrokUsage.windows(fromJSON: json))
    }

    func testPlanNameComesFromSettings() {
        let data = Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8)
        XCTAssertEqual(GrokUsage.planName(from: data), "SuperGrok Heavy")
        XCTAssertNil(GrokUsage.planName(from: Data("{}".utf8)))
        XCTAssertNil(GrokUsage.planName(from: Data("not json".utf8)))
    }
}

/// Apple's ISO8601DateFormatter rejects more than three fractional digits,
/// and Grok writes six. Truncating them is what stops a live period from
/// looking like a schema change.
final class GrokTimeTests: XCTestCase {
    func testSixFractionalDigitsParse() throws {
        let date = try XCTUnwrap(GrokCredentials.date("2026-08-30T18:22:54.007137+00:00"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_788_114_174.007, accuracy: 0.001)
    }

    func testZuluWithMillisecondsParses() throws {
        let date = try XCTUnwrap(GrokCredentials.date("2026-09-06T04:48:03.648Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_788_670_083.648, accuracy: 0.001)
    }

    func testWholeSecondsParse() throws {
        XCTAssertNotNil(GrokCredentials.date("2026-09-06T04:48:03Z"))
    }
}

final class GrokCredentialsTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    func testReadsAKeyedEntry() throws {
        try write("""
        {"https://auth.x.ai::client":{"key":"tok","refresh_token":"ref","email":"a@b.c","oidc_client_id":"client-id","expires_at":"2099-01-01T00:00:00.000Z"}}
        """)
        let credentials = try GrokCredentials.load(from: url)
        XCTAssertEqual(credentials.accessToken, "tok")
        XCTAssertEqual(credentials.refreshToken, "ref")
        XCTAssertEqual(credentials.email, "a@b.c")
        XCTAssertEqual(credentials.clientID, "client-id")
        XCTAssertFalse(credentials.isExpired)
    }

    func testAccountShowsTheEmailFromTheFile() throws {
        try write(#"""
        {"https://auth.x.ai::client":{"key":"tok","email":"a@b.c"}}
        """#)
        let account = try XCTUnwrap(GrokCredentials.account(from: url))
        XCTAssertEqual(account.label, "a@b.c")
        XCTAssertEqual(account.source, "Grok Build")
        XCTAssertEqual(account.manageURL?.host, "grok.com")
    }

    func testAMissingFileMeansSignedOutRatherThanAnError() {
        XCTAssertThrowsError(try GrokCredentials.load(from: url)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
        XCTAssertNil(GrokCredentials.account(from: url))
    }

    func testAnEntryWithoutAKeyIsIgnored() {
        try? write(#"""
        {"https://auth.x.ai::client":{"refresh_token":"ref"}}
        """#)
        XCTAssertThrowsError(try GrokCredentials.load(from: url))
    }

    func testClientIDFallsBackToTheEntryKeyThenTheDefault() throws {
        try write(#"""
        {"https://auth.x.ai::from-key":{"key":"tok"}}
        """#)
        XCTAssertEqual(try GrokCredentials.load(from: url).clientID, "from-key")
    }

    func testAnUnexpiredEntryIsPreferredOverAnExpiredNeighbour() throws {
        try write(#"""
        {
          "old":{"key":"stale","expires_at":"2020-01-01T00:00:00Z"},
          "live":{"key":"fresh","expires_at":"2099-01-01T00:00:00Z"}
        }
        """#)
        XCTAssertEqual(try GrokCredentials.load(from: url).accessToken, "fresh")
    }

    /// `urlQueryAllowed` treats `+` as safe, and in a form body `+` is a space.
    func testFormBodyEncodesReservedCharacters() {
        let body = GrokCredentials.formBody([
            "client_id": "client id&=+/?%",
            "refresh_token": "refresh token&=+/?%",
            "grant_type": "refresh_token"
        ])
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("grant_type=refresh_token"))
        XCTAssertTrue(text.contains("client_id=client%20id%26%3D%2B%2F%3F%25"))
        XCTAssertTrue(text.contains("refresh_token=refresh%20token%26%3D%2B%2F%3F%25"))
        XCTAssertFalse(text.contains("&=+"), "reserved characters must be percent-encoded")
    }

    private func write(_ json: String) throws {
        try json.data(using: .utf8)!.write(to: url)
    }
}

/// The activity signal is a heuristic — an updates log written moments ago —
/// so what it will and will not claim is worth pinning down.
@MainActor
final class GrokActivityTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grok-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAJustWrittenSessionReadsAsWorking() throws {
        try writeSession(workspace: "codenotch", id: "abc", modified: now)
        let sessions = GrokActivityMonitor.read(root: root, staleAfter: 45, now: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.id, "grok.abc")
        XCTAssertEqual(sessions.first?.name, "codenotch")
        XCTAssertEqual(sessions.first?.detail, "Working")
    }

    func testAnOldSessionIsNotWorking() throws {
        try writeSession(workspace: "codenotch", id: "abc",
                         modified: now.addingTimeInterval(-600))
        XCTAssertTrue(GrokActivityMonitor.read(root: root, staleAfter: 45, now: now).isEmpty)
    }

    func testTheNewestSessionWins() throws {
        try writeSession(workspace: "old", id: "one",
                         modified: now.addingTimeInterval(-600))
        try writeSession(workspace: "live", id: "two", modified: now)
        let sessions = GrokActivityMonitor.read(root: root, staleAfter: 45, now: now)
        XCTAssertEqual(sessions.first?.id, "grok.two")
        XCTAssertEqual(sessions.first?.name, "live")
    }

    func testAPercentEncodedWorkspaceIsDecodedToItsFolderName() {
        let encoded = "%2FUsers%2Fziad%2FWork%2FGitHub%2Fcodenotch"
        let url = URL(fileURLWithPath: "/tmp/\(encoded)")
        XCTAssertEqual(GrokActivityMonitor.workspaceName(url), "codenotch")
    }

    func testASubagentWorktreeKeepsTheGenericName() {
        let url = URL(fileURLWithPath: "/tmp/subagent-01a0749e-0ba3-7413-8b87-cc80663bd287")
        XCTAssertEqual(GrokActivityMonitor.workspaceName(url), "Grok")
    }

    func testNoSessionsIsQuietRatherThanAnError() {
        let absent = root.appendingPathComponent("nowhere")
        XCTAssertTrue(GrokActivityMonitor.read(root: absent, staleAfter: 45, now: now).isEmpty)
    }

    func testTheBoundaryIsInclusive() throws {
        try writeSession(workspace: "w", id: "a", modified: now.addingTimeInterval(-45))
        XCTAssertNotNil(GrokActivityMonitor.read(root: root, staleAfter: 45, now: now).first)
    }

    @discardableResult
    private func writeSession(workspace: String, id: String, modified: Date) throws -> URL {
        let dir = root.appendingPathComponent(workspace).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("updates.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }
}
