import XCTest
@testable import CodexSwoopCore

@MainActor
final class AccountUsageTests: XCTestCase {
    func testFractionalRemainingAndActualWindow() throws {
        let data = Data(#"{"accountId":"fictional-scope","rateLimits":{"secondary":{"usedPercent":28.125,"windowDurationMins":10080}}}"#.utf8)
        let parsed = try UsageDecoder.initial(data, at: Date())
        XCTAssertEqual(parsed.buckets[0].windows.count, 1)
        let originalLanguage = L10n.language
        L10n.setSessionLanguage(.english)
        defer { L10n.setSessionLanguage(originalLanguage) }
        XCTAssertEqual(parsed.buckets[0].windows[0].remainingText, "71.875% left")
        XCTAssertEqual(parsed.buckets[0].windows[0].title, "Weekly")
        XCTAssertNil(parsed.buckets[0].windows[0].resetsAt)
    }
    func testMissingDataNeverInventsFullQuotaOrIdentity() throws {
        let parsed = try UsageDecoder.initial(Data(#"{"rateLimits":{"primary":null,"planType":"fictional-future"}}"#.utf8), at: Date())
        XCTAssertNil(parsed.accountScope)
        XCTAssertNil(parsed.buckets[0].plan)
        XCTAssertTrue(parsed.buckets[0].windows.isEmpty)
    }
    func testNonFiniteAndBooleanPercentRejected() {
        XCTAssertThrowsError(try UsageWindow(usedPercent: .infinity, durationMinutes: nil, resetsAt: nil, observedAt: Date()))
        XCTAssertThrowsError(try UsageDecoder.initial(Data(#"{"rateLimits":{"primary":{"usedPercent":true}}}"#.utf8), at: Date()))
    }
    func testLiveGateRemainsClosed() {
        XCTAssertFalse(UsageIntegrationPolicy.liveEnabled)
        XCTAssertFalse(BlockedAccountUsageProvider().permitsSyntheticRequests)
    }
}

extension AccountUsageTests {
    func testCacheIsolatedByProfileGenerationIdentityAndTransport() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/codexswoop-xctest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await ReleaseFixture.make(root: root)
        let identity = try AccountIdentityKey(namespace: "fictional", subject: "one")
        let account = try AccountIdentityKey(namespace: UsageIntegrationPolicy.accountScopeNamespace, subject: "fictional-scope")
        let instance = ReleaseDesktopSystem.instance(1), transport = UUID()
        let context = UsageContext(association: f.associations[0], instance: instance, accountIdentity: identity, accountScope: account, transportID: transport)
        let data = try UsageDecoder.initial(Data(#"{"accountId":"fictional-scope","rateLimits":{"primary":{"usedPercent":28,"windowDurationMins":300}}}"#.utf8), at: Date())
        var cache = UsageCache()
        cache.store(AccountUsageSnapshot(context: context, data: data, updatedAt: Date()))
        XCTAssertNotNil(cache.snapshot(for: context))
        let otherIdentity = try AccountIdentityKey(namespace: "fictional", subject: "two")
        let variants = [
            UsageContext(association: f.associations[1], instance: instance, accountIdentity: identity, accountScope: account, transportID: transport),
            UsageContext(association: f.associations[0], instance: ReleaseDesktopSystem.instance(2), accountIdentity: identity, accountScope: account, transportID: transport),
            UsageContext(association: f.associations[0], instance: instance, accountIdentity: otherIdentity, accountScope: account, transportID: transport),
            UsageContext(association: f.associations[0], instance: instance, accountIdentity: identity, accountScope: account, transportID: UUID())
        ]
        for changed in variants { XCTAssertNil(cache.snapshot(for: changed)) }
        cache.clear(context.profileID)
        XCTAssertNil(cache.snapshot(for: context))
    }
    func testRollingUpdatePreservesAbsentWindowAndRejectsInvalidPercent() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = try UsageDecoder.initial(Data(#"{"accountId":"fictional-scope","rateLimits":{"primary":{"usedPercent":28,"windowDurationMins":300},"secondary":{"usedPercent":59,"windowDurationMins":10080}}}"#.utf8), at: date)
        let unscoped = Data(#"{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":300}}}"#.utf8)
        XCTAssertThrowsError(try UsageDecoder.rolling(unscoped, previous: initial, at: date)) {
            XCTAssertEqual($0 as? UsageFailure, .invalidData)
        }
        let update = try UsageDecoder.rolling(Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":300}}}"#.utf8), previous: initial, at: date)
        XCTAssertEqual(update.buckets[0].secondary, initial.buckets[0].secondary)
        XCTAssertEqual(update.buckets[0].primary?.usedPercent, 30)
        XCTAssertThrowsError(try UsageDecoder.initial(Data(#"{"rateLimits":{"primary":{"usedPercent":"NaN"}}}"#.utf8), at: date))
    }
}
